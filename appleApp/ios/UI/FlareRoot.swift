import SwiftUI
import Combine
import FlareAppleUI
import KotlinSharedUI
import FlareAppleCore
import SwiftUIIntrospect
import UIKit
import NavigationBackport

extension Notification.Name {
    static let tabDoubleTapped = Notification.Name("tabDoubleTapped")
}

@available(iOS 18.0, *)
struct FlareRoot: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.globalAppearance) private var globalAppearance
    @StateObject private var homeTabsPresenter = KotlinPresenter(presenter: HomeTabsPresenter())
    @StateObject private var notificationBadgePresenter = KotlinPresenter(presenter: AllNotificationBadgePresenter())
    @StateObject private var secondaryTabsPresenter = KotlinPresenter(presenter: SecondaryTabsPresenter())
    @StateObject private var aiAgentEnabledPresenter = KotlinPresenter(presenter: AiAgentEnabledPresenter())
    @State private var inAppNotification = SwiftInAppNotification.shared
    @State var selectedTab: String?
    @State private var reloginRoute: Route?
    
    var body: some View {
        StateView(state: homeTabsPresenter.state.tabs) { tabs in
            let items = tabs.cast(HomeTabsPresenterStateHomeTabs.self)
            TabView(selection: $selectedTab) {
                ForEach(items, id: \.name) { tab in
                    Tab(value: homeTabKey(tab), role: homeTabRoute(tab) == .discover ? .some(.search) : .none) {
                        Router { onNavigate in
                            homeTabRoute(tab).view(onNavigate: onNavigate, goBack: {})
                        }
                    } label: {
                        Label {
                            Text(homeTabTitle(tab))
                        } icon: {
                            Image(fontAwesome: homeTabIcon(tab))
                        }
                        .adaptiveLabelStyle(globalAppearance.showBottomBarLabels || horizontalSizeClass == .regular)
                    }
                    .badge(homeTabRoute(tab) == .notification ? Int(notificationBadgePresenter.state.count) : 0)
                }
                // iPhone Duo also has a regular width when unfolded; these shortcuts are iPad-only.
                if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                    if case .success(let data) = onEnum(of: secondaryTabsPresenter.state.items) {
                        let items = data.data.cast(SecondaryTabsPresenter.Item.self)
                        ForEach(items, id: \.accountKey) { item in
                            let tabs = item.tabs.compactMap { tab in
                                route(for: tab).map { (tab: tab, route: $0) }
                            }
                            TabSection {
                                ForEach(tabs, id: \.tab) { destination in
                                    secondarySidebarShortcut(destination.tab, route: destination.route)
                                }
                            } header: {
                                StateView(state: item.user) { user in
                                    UserOnelineView(data: user)
                                } errorContent: { _ in
                                    Text("account_management_title")
                                } loadingContent: {
                                    Text("account_management_title")
                                }
                            }
                            .tabPlacement(.sidebarOnly)
                        }
                    }
                    ForEach(SecondarySidebarStaticRoute.allCases.filter { route in
                        route != .agentHistory || aiAgentEnabledPresenter.state.enabled
                    }, id: \.self) { route in
                        secondarySidebarStaticRoute(route)
                    }
                }
            }
            .modifier(IPadCompactTabBarModifier(primaryTabIDs: items.map(\.name)))
            .modifier(TabBarDoubleTapModifier {
                NotificationCenter.default.post(name: .tabDoubleTapped, object: selectedTab)
            })
            .tabViewStyle(.sidebarAdaptable)
            .background(Color(.systemGroupedBackground))
            .sheet(item: $reloginRoute) { route in
                NBNavigationStack {
                    route.view(
                        onNavigate: { reloginRoute = $0 },
                        goBack: { reloginRoute = nil }
                    )
                }
            }
            .onAppear {
                inAppNotification.onRelogin = { toast in
                    reloginRoute = .relogin(toast.accountKey, toast.platformId)
                }
            }
        } loadingContent: {
            SplashScreen()
        }
    }

    @TabContentBuilder<String?>
    private func secondarySidebarShortcut(_ tab: SecondaryTabsPresenter.Tab, route: Route) -> some TabContent<String?> {
        Tab(value: "secondary:\(tab.hashValue)") {
            SidebarRouteScreen(route: route)
        } label: {
            Label {
                Text(tab.title.text)
            } icon: {
                Image(fontAwesome: tab.icon.fontAwesomeIcon)
            }
        }
        .tabPlacement(.sidebarOnly)
    }

    @TabContentBuilder<String?>
    private func secondarySidebarStaticRoute(_ route: SecondarySidebarStaticRoute) -> some TabContent<String?> {
        Tab(value: route.selectionValue) {
            SidebarRouteScreen(route: route.route)
        } label: {
            Label {
                Text(route.title)
            } icon: {
                Image(fontAwesome: route.icon)
            }
        }
        .tabPlacement(.sidebarOnly)
    }
}
private extension View {
    @ViewBuilder
    func adaptiveLabelStyle(_ showLabel: Bool) -> some View {
        if showLabel {
            self.labelStyle(.automatic)
        } else {
            self.labelStyle(.iconOnly)
        }
    }
}
struct BackportFlareRoot: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.globalAppearance) private var globalAppearance
    @StateObject private var homeTabsPresenter = KotlinPresenter(presenter: HomeTabsPresenter())
    @StateObject private var notificationBadgePresenter = KotlinPresenter(presenter: AllNotificationBadgePresenter())
    @State private var inAppNotification = SwiftInAppNotification.shared
    @State var selectedTab: String?
    @State private var reloginRoute: Route?
    
    var body: some View {
        StateView(state: homeTabsPresenter.state.tabs) { tabs in
            let items = tabs.cast(HomeTabsPresenterStateHomeTabs.self)
            TabView(selection: $selectedTab) {
                ForEach(items, id: \.name) { tab in
                    Router { onNavigate in
                        homeTabRoute(tab).view(onNavigate: onNavigate, goBack: {})
                    }
                    .tabItem {
                        Label {
                            Text(homeTabTitle(tab))
                        } icon: {
                            // iOS 15 回退：FontAwesome 资源是同为 3300×2200 画布的
                            // symbolset，但各字形留白不一致，tabItem 直接吃固有尺寸
                            // → 大小不一、高低不齐；给个别图标补 .resizable() 后
                            // 甚至整幅渲染失败（通知 tab 的铃铛直接消失，用户看不到
                            // 消息入口）。改用 iOS 13 起就有的 SF Symbols：tabItem
                            // 会自动统一尺寸与基线，与系统 tab bar 完全一致。
                            Image(systemName: homeTabSystemIcon(tab))
                        }
                        .adaptiveLabelStyle(globalAppearance.showBottomBarLabels)
                    }
                    .badge(homeTabRoute(tab) == .notification ? Int(notificationBadgePresenter.state.count) : 0)
                    .tag(homeTabKey(tab))
                }
            }
            .modifier(TabBarDoubleTapModifier {
                NotificationCenter.default.post(name: .tabDoubleTapped, object: selectedTab)
            })
            .background(Color(.systemGroupedBackground))
            .sheet(item: $reloginRoute) { route in
                NBNavigationStack {
                    route.view(
                        onNavigate: { reloginRoute = $0 },
                        goBack: { reloginRoute = nil }
                    )
                }
            }
            .onAppear {
                inAppNotification.onRelogin = { toast in
                    reloginRoute = .relogin(toast.accountKey, toast.platformId)
                }
            }
        } loadingContent: {
            SplashScreen()
        }
    }
}

@MainActor
private final class TabBarDoubleTapTarget: NSObject, UIGestureRecognizerDelegate {
    private var action: () -> Void = {}

    private lazy var recognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    func install(on tabBar: UITabBar, action: @escaping () -> Void) {
        self.action = action
        guard recognizer.view !== tabBar else { return }
        tabBar.addGestureRecognizer(recognizer)
    }

    @objc private func handleDoubleTap() {
        DispatchQueue.main.async { [weak self] in
            self?.action()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct TabBarDoubleTapModifier: ViewModifier {
    @State private var target = TabBarDoubleTapTarget()
    let action: () -> Void

    func body(content: Content) -> some View {
        // iOS 15 回退：原本只 introspect iOS 17，导致 6S(iOS15.8.8) 上
        // 双击 tab 手势永不安装 → 首页 tab 双击刷新/回顶全部失效。
        // 放宽到 iOS 15~18（SwiftUIIntrospect 在这些版本都能拿到 UITabBarController）。
        content.introspect(.tabView, on: .iOS(.v15, .v16, .v17, .v18)) { tabBarController in
            target.install(on: tabBarController.tabBar, action: action)
        }
    }
}

private func homeTabKey(_ tab: HomeTabsPresenterStateHomeTabs) -> String {
    tab.name.lowercased()
}

private func homeTabRoute(_ tab: HomeTabsPresenterStateHomeTabs) -> Route {
    switch tab {
    case .notifications:
        return .notification
    case .discover:
        return .discover
    case .home:
        return .home
    }
}

private func homeTabTitle(_ tab: HomeTabsPresenterStateHomeTabs) -> LocalizedStringKey {
    switch tab {
    case .notifications:
        return "home_tab_notifications_title"
    case .discover:
        return "discover_title"
    case .home:
        return "home_tab_home_title"
    }
}

private func homeTabIcon(_ tab: HomeTabsPresenterStateHomeTabs) -> FontAwesomeIcon {
    switch tab {
    case .notifications:
        return .bell
    case .discover:
        return .magnifyingGlass
    case .home:
        return .house
    }
}

/// iOS 15 回退：底部 tab 栏专用图标（SF Symbols）。
/// FontAwesome symbolset 在 iOS 15 的 tabItem 里按固有尺寸渲染，各字形留白不一致
/// 会大小不一、高低不齐；个别图标补 .resizable() 后甚至整幅渲染失败
/// （通知 tab 的铃铛直接消失）。SF Symbols 由 tabItem 自动统一尺寸与基线。
/// 这三个符号 iOS 13 起就有，iPhone 6S（iOS 15）原生支持。
private func homeTabSystemIcon(_ tab: HomeTabsPresenterStateHomeTabs) -> String {
    switch tab {
    case .notifications:
        return "bell.fill"
    case .discover:
        return "magnifyingglass"
    case .home:
        return "house.fill"
    }
}

private struct SidebarRouteScreen: View {
    let route: Route

    var body: some View {
        Router { onNavigate in
            route.view(
                onNavigate: onNavigate,
                goBack: {}
            )
        }
    }
}

private enum SecondarySidebarStaticRoute: CaseIterable {
    case drafts
    case rssManagement
    case weread
    case localHistory
    case agentHistory
    case settings

    var selectionValue: String {
        switch self {
        case .drafts:
            return "route:drafts"
        case .rssManagement:
            return "route:rssManagement"
        case .weread:
            return "route:weread"
        case .localHistory:
            return "route:localHistory"
        case .agentHistory:
            return "route:agentHistory"
        case .settings:
            return "route:settings"
        }
    }

    var route: Route {
        switch self {
        case .drafts:
            return .draftBox
        case .rssManagement:
            return .rssManagement
        case .weread:
            return .weread
        case .localHistory:
            return .localHostory
        case .agentHistory:
            return .agentHistory
        case .settings:
            return .settings
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .drafts:
            return "Drafts"
        case .rssManagement:
            return "settings_rss_management_title"
        case .weread:
            return "微信读书"
        case .localHistory:
            return "local_history_title"
        case .agentHistory:
            return "agent_history_title"
        case .settings:
            return "settings_title"
        }
    }

    var icon: FontAwesomeIcon {
        switch self {
        case .drafts:
            return .penToSquare
        case .rssManagement:
            return .squareRss
        case .weread:
            return .bookmark
        case .localHistory:
            return .clockRotateLeft
        case .agentHistory:
            return .robot
        case .settings:
            return .gear
        }
    }
}

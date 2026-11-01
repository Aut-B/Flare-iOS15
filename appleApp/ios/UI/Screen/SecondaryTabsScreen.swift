import SwiftUI
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import NavigationBackport

struct SecondaryTabsScreen: View {
    @Environment(\.dismiss) private var dismiss
    let onTabSelected: (Route) -> Void
    @StateObject private var presenter = KotlinPresenter(presenter: SecondaryTabsPresenter())
    @StateObject private var aiAgentEnabledPresenter = KotlinPresenter(presenter: AiAgentEnabledPresenter())
    var body: some View {
        // 这一页里所有跳转都改成 onTabSelected（关 sheet + 主导航栈 push），
        // 不再需要 iOS 18 那层嵌套 Router/NavigationStack。
        content
            .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    dismiss()
                } label: {
                    Image(fontAwesome: .xmark)
                }
                .accessibilityLabel(Text("Close"))
            }
        }
    }

    private var content: some View {
        List {
            StateView(state: presenter.state.items) { data in
                let items = data.cast(SecondaryTabsPresenter.Item.self)
                if !items.isEmpty {
                    Section {
                        ForEach(items, id: \.accountKey) { item in
                            let tabs = item.tabs.compactMap { tab in
                                route(for: tab, accountKey: item.accountKey).map { (tab: tab, route: $0) }
                            }
                            DisclosureGroup {
                                ForEach(tabs, id: \.tab) { destination in
                                    Button {
                                        onTabSelected(destination.route)
                                    } label: {
                                        Label {
                                            Text(destination.tab.title.text)
                                        } icon: {
                                            Image(fontAwesome: destination.tab.icon.fontAwesomeIcon)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } label: {
                                StateView(state: item.user) { user in
                                    UserCompatView(data: user)
                                }
                            }
                        }
                    } header: {
                        Text("account_management_title")
                    }
                }
            }

            Section {
                // iOS 18+ 回退：这里原来用 NBNavigationLink，会落到 SecondaryTabsScreen
                // 里那层嵌套的 Router/NavigationStack 上；而 iOS 15 走的是 sheet 自己的
                // 导航栈。iOS 26/27 上嵌套栈里的目标页面会渲染成「只有一个图标、没有文字」。
                // 改成走 onTabSelected（和上面账号 tab 完全相同的路径）：关掉 sheet、
                // 在主导航栈上 push，全系统版本行为一致，也不再有任何嵌套导航栈。
                secondaryRouteButton("Drafts", icon: .penToSquare, route: .draftBox)
                secondaryRouteButton("settings_rss_management_title", icon: .squareRss, route: .rssManagement)
                secondaryRouteButton("微信读书", icon: .bookmark, route: .weread)
                secondaryRouteButton("Instagram", icon: .photoFilm, route: .instagram)
                secondaryRouteButton("小红书", icon: .image, route: .xiaohongshu)
                secondaryRouteButton("local_history_title", icon: .clockRotateLeft, route: .localHostory)
                if aiAgentEnabledPresenter.state.enabled {
                    secondaryRouteButton("agent_history_title", icon: .robot, route: .agentHistory)
                }
                secondaryRouteButton("settings_title", icon: .gear, route: .settings)
            }
        }
    }

    private func secondaryRouteButton(
        _ title: LocalizedStringKey,
        icon: FontAwesomeIcon,
        route: Route
    ) -> some View {
        Button {
            onTabSelected(route)
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    Image(fontAwesome: icon)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func route(for tab: SecondaryTabsPresenter.Tab, accountKey: MicroBlogKey) -> Route? {
    // Instagram / 小红书 / 微信读书的账号标签页都走原生页面：
    // - Instagram / 小红书：Kotlin 时间线要重新发一套网页请求，cookie 失效时
    //   会直接报「登录已失效」，而且小红书还要等签名页；原生页有独立的
    //   登录态和更完整的错误提示。
    // - 微信读书：本来就没有时间线，只有原生书架。
    // 「我」这个快捷入口也一起指过去，避免落到 Kotlin 个人主页后空白。
    switch accountKey.host {
    case "instagram.com":
        return .instagram
    case "xiaohongshu.com":
        return .xiaohongshu
    case "weread.qq.com":
        return .weread
    default:
        break
    }
    switch onEnum(of: tab.destination) {
    case .route(let destination):
        return Route.fromDeepLinkRoute(deeplinkRoute: destination.route)
    case .timeline(let destination):
        return .timeline(destination.tabItem)
    }
}

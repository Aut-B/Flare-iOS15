import SwiftUI
import FlareAppleUI
@preconcurrency import KotlinSharedUI
import FlareAppleCore
import UIKit
import Combine

/// 这几个平台的「时间线」实际由原生页面渲染：
/// - 微信读书只有书架，Kotlin 侧没有时间线；
/// - Instagram / 小红书要独立的网页 cookie / 签名，Kotlin 那套在真机上容易被风控。
private enum NativeSocialTab: Equatable {
    case instagram
    case xiaohongshu
    case weread
}

private func detectedNativeSocialTab(for tab: UiTimelineTabItem) -> NativeSocialTab? {
    // `tab.id` 是 `home:<accountKey>`，accountKey 里带 host；比标题可靠，
    // 用户改过标签名也认得出来。老版本标签页再用标题兜底。
    let key = tab.id.lowercased()
    if key.contains("instagram.com") { return .instagram }
    if key.contains("xiaohongshu.com") { return .xiaohongshu }
    if key.contains("weread.qq.com") { return .weread }
    switch tab.title.text {
    case "Instagram":
        return .instagram
    case "小红书":
        return .xiaohongshu
    case "微信读书":
        return .weread
    default:
        return nil
    }
}

private func nativeSocialTab(for tab: UiTimelineTabItem) -> NativeSocialTab? {
    guard let detected = detectedNativeSocialTab(for: tab) else { return nil }
    guard FlareBuildVariant.isPhoneLite else { return detected }
    switch detected {
    case .xiaohongshu, .weread:
        return nil
    case .instagram:
        return .instagram
    }
}

private func isHiddenHomeTab(_ tab: UiTimelineTabItem) -> Bool {
    switch detectedNativeSocialTab(for: tab) {
    case .weread:
        // 微信读书从底栏书本入口进，不再占顶部时间线菜单。
        return true
    case .xiaohongshu:
        // Phone Lite 仍按原策略隐藏小红书；普通包保留顶部菜单和小红书页。
        return FlareBuildVariant.isPhoneLite
    default:
        return false
    }
}

private let homeTimelineInstagramTabId = "flare:home-timeline-instagram"

/// 顶部时间线分组菜单的一项。微读的菜单槽位由 Instagram 接管，
/// 但 Instagram 在 Kotlin 侧没有 tab 对象，所以只在 SwiftUI 展示层存在。
private enum HomeTimelineMenuEntry: Identifiable {
    case tab(UiTimelineTabItem)
    case instagram

    var id: String {
        switch self {
        case .tab(let tab):
            return tab.id
        case .instagram:
            return homeTimelineInstagramTabId
        }
    }
}

private func homeTimelineMenuEntries(allTabs: [UiTimelineTabItem]) -> [HomeTimelineMenuEntry] {
    // Instagram 在 Kotlin 的 TimelineSlot 里没有数据源，不能伪造一个会打开空时间线的
    // 真实 tab；但顶部菜单必须始终保留 Swift 侧入口，连 allTabs 为空时也要能进 Instagram。
    let hasRealInstagramTab = allTabs.contains {
        !isHiddenHomeTab($0) && detectedNativeSocialTab(for: $0) == .instagram
    }
    if hasRealInstagramTab {
        return allTabs.filter { !isHiddenHomeTab($0) }.map { .tab($0) }
    }

    var entries: [HomeTimelineMenuEntry] = []
    var insertedInstagram = false
    for tab in allTabs {
        if detectedNativeSocialTab(for: tab) == .weread {
            // 在原微读槽位放 Instagram；多个微读分组也只保留一个 IG 入口。
            if !insertedInstagram {
                entries.append(.instagram)
                insertedInstagram = true
            }
            continue
        }
        if isHiddenHomeTab(tab) { continue }
        entries.append(.tab(tab))
    }
    if !insertedInstagram {
        entries.append(.instagram)
    }
    return entries
}

@ViewBuilder
private func nativeSocialView(for tab: NativeSocialTab) -> some View {
    switch tab {
    case .instagram:
        InstagramFeedView()
    case .xiaohongshu:
        // 默认进原生瀑布流；只有用户在页面内主动切换时才走网页版。
        XhsTabView()
    case .weread:
        // 默认进原生书架；只有用户在页面内主动切换时才走网页版。
        WereadTabView()
    }
}

struct HomeTimelineScreen: View {
    let toServiceSelect: () -> Void
    let toCompose: () -> Void
    let toTabSetting: () -> Void
    let toSecondaryMenu: () -> Void
    let onNavigate: (Route) -> Void
    @Environment(\.globalAppearance) private var globalAppearance
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.timelineAppearance) private var timelineAppearance
    @Environment(\.openURL) private var openURL
    @State private var selectedTabId: String?
    @State private var isInstagramSelected = false
    @Namespace private var selectedTabIndicatorNamespace
    @StateObject private var presenter: KotlinPresenter<HomeTimelineWithTabsPresenterState>
    @StateObject private var activeAccountPresenter = KotlinPresenter(presenter: ActiveAccountPresenter())
    @StateObject private var loggedInPresenter = KotlinPresenter(presenter: LoggedInPresenter())
    @StateObject private var canComposePresenter = KotlinPresenter(presenter: CanComposePresenter())
    @StateObject private var changeLogPresenter: KotlinPresenter<ChangeLogPresenterState>
    @State private var changeLogAccessoryHost = ChangeLogAccessoryHost()
    private let currentVersion: String

    init(
        toServiceSelect: @escaping () -> Void,
        toCompose: @escaping () -> Void,
        toTabSetting: @escaping () -> Void,
        toSecondaryMenu: @escaping () -> Void,
        onNavigate: @escaping (Route) -> Void
    ) {
        self.toCompose = toCompose
        self.toServiceSelect = toServiceSelect
        self.toTabSetting = toTabSetting
        self.toSecondaryMenu = toSecondaryMenu
        self.onNavigate = onNavigate
        self._presenter = .init(wrappedValue: .init(presenter: HomeTimelineWithTabsPresenter()))
        let currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        self.currentVersion = currentVersion
        let changeLogPresenter = KotlinPresenter<ChangeLogPresenterState>(
            presenter: ChangeLogPresenter(currentVersion: currentVersion)
        )
        self._changeLogPresenter = .init(
            wrappedValue: changeLogPresenter
        )
    }

    var body: some View {
        GeometryReader { proxy in
            StateView(state: presenter.state.tabState) { state in
                let allTabs: [UiTimelineTabItem] = state.cast(UiTimelineTabItem.self)
                let tabs: [UiTimelineTabItem] = allTabs.filter { !isHiddenHomeTab($0) }
                let menuEntries = homeTimelineMenuEntries(allTabs: allTabs)
                // menuEntries 至少包含 Instagram，只有菜单构造异常时才回退到空状态；
                // 不能再因为 allTabs 为空就把 Instagram 入口一起挡掉。
                if menuEntries.isEmpty {
                    BackportContentUnavailableView("tab_settings_title", systemImage: "square.grid.2x2")
                        .toolbar {
                            leadingToolbarContent
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    toTabSetting()
                                } label: {
                                    Image(fontAwesome: .plus)
                                }
                                .accessibilityLabel(Text("tab_settings_add_tab"))
                            }
                        }
                } else {
                    if globalAppearance.deckMode && horizontalSizeClass == .regular && !tabs.isEmpty {
                        DeckTimelineLayout(
                            tabs: tabs,
                            baseTimelineAppearance: timelineAppearance,
                            columnWidth: min(max(proxy.size.width * 0.42, 320), 420),
                            toTabSetting: toTabSetting,
                            onGlobalRoute: onNavigate
                        )
                        .toolbar {
                            leadingToolbarContent
                            ToolbarItemGroup(placement: .navigationBarTrailing) {
                                Button {
                                    toTabSetting()
                                } label: {
                                    Image(fontAwesome: .sliders)
                                }
                                .accessibilityLabel(Text("tab_settings_customize"))
                                composeToolbarButton
                            }
                        }
                    } else {
                        let selectedId = selectedTabId ?? presenter.state.initialSelectedTabId
                        let resolvedTab = selectedId.flatMap { id in
                            tabs.first { $0.id == id }
                        } ?? tabs.first
                        // Instagram 使用独立选中态，不依赖 tabs[0] 这类真实 tab 兜底。
                        let showsInstagram = isInstagramSelected || resolvedTab == nil
                        let resolvedTimelineAppearance = resolvedTab.map {
                            showsInstagram ? timelineAppearance : $0.resolveTimelineAppearance(base: timelineAppearance)
                        } ?? timelineAppearance
                        ZStack {
                            // Instagram 菜单槽位 / 小红书 / 微信读书的标签直接渲染原生页，
                            // 数据源和登录态都由 WebSocial / Weread 那套自己管。
                            Group {
                                if showsInstagram {
                                    InstagramFeedView()
                                } else if let tab = resolvedTab, let nativeTab = nativeSocialTab(for: tab) {
                                    nativeSocialView(for: nativeTab)
                                } else if let tab = resolvedTab {
                                    TimelineScreen(
                                        tabItem: tab,
                                        allowGalleryMode: true,
                                        isHomeTimeline: true,
                                        accessoryItems: resolvedTimelineAppearance.timelineDisplayMode == .gallery
                                            ? []
                                            : changeLogAccessoryItems
                                    )
                                }
                            }
                                .id(
                                    showsInstagram
                                        ? homeTimelineInstagramTabId
                                        : resolvedTab.map { "\($0.id):\($0.contentSourceKey)" } ?? homeTimelineInstagramTabId
                                )
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if !showsInstagram,
                               resolvedTimelineAppearance.timelineDisplayMode == .gallery,
                               shouldShowChangeLog {
                                ChangeLogNotice(version: currentVersion) {
                                    changeLogPresenter.state.dismissChangeLog()
                                }
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .backportOnChange(of: tabs.map { $0.id }, initial: true) { _, tabIds in
                            if let selectedTabId, tabIds.contains(selectedTabId) {
                                return
                            }
                            let fallback = tabIds.first(where: { $0 == presenter.state.initialSelectedTabId }) ?? tabIds.first
                            selectedTabId = fallback
                            // Instagram 分支下仍保留一个真实 tab id，列表变化时同步给 Kotlin。
                            if isInstagramSelected, let fallback {
                                presenter.state.selectTab(tabId: fallback)
                            }
                        }
                        .backportOnChange(of: selectedTabId) { _, id in // iOS 15 回退：上游 iOS17 目标的 onChange 闭包会解析到 iOS17 重载
                            if let id { presenter.state.selectTab(tabId: id) }
                        }
                        .toolbar {
                        // iOS 15 的 ToolbarContentBuilder 没有 buildIf：条件统一搬进 ToolbarItem 内部。
                        // ToolbarTitleMenu 是 iOS 17 的 API，这里用等价的 Menu 包装在 title 位置实现。
                            leadingToolbarContent
                            ToolbarItem(placement: .title) {
                                if horizontalSizeClass == .compact {
                                    Menu {
                                        ForEach(menuEntries) { entry in
                                            switch entry {
                                            case .tab(let item):
                                                Toggle(isOn: Binding(get: {
                                                    !showsInstagram && resolvedTab?.id == item.id
                                                }, set: { value in
                                                    if value {
                                                        selectRealTab(item.id)
                                                    }
                                                })) {
                                                    Label {
                                                        TimelineTabTitle(title: item.title)
                                                    } icon: {
                                                        TabIcon(tabItem: item)
                                                            .frame(width: 24)
                                                            .scaledToFit()
                                                    }
                                                    .labelStyle(.titleAndIcon)
                                                }
                                            case .instagram:
                                                Toggle(isOn: Binding(get: {
                                                    showsInstagram
                                                }, set: { value in
                                                    if value {
                                                        selectInstagram(currentRealTabId: resolvedTab?.id)
                                                    }
                                                })) {
                                                    Label {
                                                        Text("Instagram")
                                                    } icon: {
                                                        Image(fontAwesome: .photoFilm)
                                                            .frame(width: 24)
                                                            .scaledToFit()
                                                    }
                                                    .labelStyle(.titleAndIcon)
                                                    .accessibilityIdentifier("home-timeline-instagram-entry")
                                                }
                                            }
                                        }
                                        Divider()
                                        Button {
                                            toTabSetting()
                                        } label: {
                                            Label {
                                                Text("tab_settings_add_tab")
                                            } icon: {
                                                Image(fontAwesome: .plus)
                                            }
                                        }
                                    } label: {
                                        if showsInstagram || resolvedTab == nil {
                                            Label {
                                                Text("Instagram")
                                            } icon: {
                                                Image(fontAwesome: .photoFilm)
                                            }
                                            .labelStyle(.titleAndIcon)
                                            .accessibilityIdentifier("home-timeline-title")
                                            .id(homeTimelineInstagramTabId)
                                        } else if let resolvedTab {
                                            Label {
                                                TimelineTabTitle(title: resolvedTab.title)
                                            } icon: {
                                                TabIcon(tabItem: resolvedTab)
                                            }
                                            .labelStyle(.titleAndIcon)
                                            .accessibilityIdentifier("home-timeline-title")
                                            .id("\(resolvedTab.id):\(resolvedTab.contentSourceKey)")
                                        }
                                    }
                                }
                            }
                            ToolbarItem(placement: .automatic) {
                                if horizontalSizeClass != .compact {
                                    ScrollView(.horizontal) {
                                        HStack {
                                            ForEach(menuEntries) { entry in
                                                switch entry {
                                                case .tab(let item):
                                                    Button {
                                                        selectRealTab(item.id)
                                                    } label: {
                                                        Label {
                                                            TimelineTabTitle(title: item.title)
                                                        } icon: {
                                                            TabIcon(tabItem: item)
                                                                .frame(width: 24)
                                                                .scaledToFit()
                                                        }
                                                        .labelStyle(.titleAndIcon)
                                                    }
                                                    .safeAreaInset(edge: .bottom, spacing: 3) {
                                                        if !showsInstagram, resolvedTab?.id == item.id {
                                                            Capsule()
                                                                .fill(Color.accentColor)
                                                                .frame(width: 18, height: 3)
                                                                .matchedGeometryEffect(id: "selectedTabIndicator", in: selectedTabIndicatorNamespace)
                                                        } else {
                                                            Capsule()
                                                                .frame(width: 0, height: 3)
                                                        }
                                                    }
                                                case .instagram:
                                                    Button {
                                                        selectInstagram(currentRealTabId: resolvedTab?.id)
                                                    } label: {
                                                        Label {
                                                            Text("Instagram")
                                                        } icon: {
                                                            Image(fontAwesome: .photoFilm)
                                                                .frame(width: 24)
                                                                .scaledToFit()
                                                        }
                                                        .labelStyle(.titleAndIcon)
                                                        .accessibilityIdentifier("home-timeline-instagram-entry")
                                                    }
                                                    .safeAreaInset(edge: .bottom, spacing: 3) {
                                                        if showsInstagram {
                                                            Capsule()
                                                                .fill(Color.accentColor)
                                                                .frame(width: 18, height: 3)
                                                                .matchedGeometryEffect(id: "selectedTabIndicator", in: selectedTabIndicatorNamespace)
                                                        } else {
                                                            Capsule()
                                                                .frame(width: 0, height: 3)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.top, 6)
                                        .padding(.horizontal)
                                        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: selectedTabId)
                                        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: isInstagramSelected)
                                    }
                                }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                if horizontalSizeClass != .compact {
                                    Button {
                                        toTabSetting()
                                    } label: {
                                        Image(fontAwesome: .sliders)
                                    }
                                    .accessibilityLabel(Text("tab_settings_customize"))
                                }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                composeToolbarButton
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .modifier(ScrollMinimizingNavigationBar())
                    }
                }
            }
        }
    }

    private var shouldShowChangeLog: Bool {
        guard case .success(let state) = onEnum(
            of: changeLogPresenter.state.shouldShowChangeLog
        ) else {
            return false
        }
        return state.data.boolValue
    }

    private func selectRealTab(_ id: String) {
        if selectedTabId == id {
            presenter.state.selectTab(tabId: id)
        }
        selectedTabId = id
        isInstagramSelected = false
    }

    private func selectInstagram(currentRealTabId: String?) {
        if let currentRealTabId {
            selectedTabId = currentRealTabId
            // 进入 Instagram 前显式记录真实 tab id，Kotlin 侧不会收到哨兵值。
            presenter.state.selectTab(tabId: currentRealTabId)
        }
        isInstagramSelected = true
    }

    private var changeLogAccessoryItems: [UITimelineCollectionViewAccessoryItem] {
        guard shouldShowChangeLog else { return [] }
        return [
            UITimelineCollectionViewAccessoryItem(
                id: "change_log_\(currentVersion)",
                view: changeLogAccessoryHost.view(version: currentVersion) { [changeLogPresenter] in
                    changeLogPresenter.state.dismissChangeLog()
                }
            ),
        ]
    }

    @ToolbarContentBuilder
    private var leadingToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            // 以前这里用 `onTapGesture` 挂在 `StateView` 上：头像一旦加载出来，
            // `AvatarView` 内部的图片会把点击吃掉，工具栏就再也点不动了。
            // 现在换成 `Button`，只让头像/齿轮这层视觉内容不参与命中测试。
            // 不能对 Button 的整个 label 关掉命中测试：那样按钮没有任何可点区域，
            // 6S(iOS 15) 上就表现为左上角点了没反应，进不去设置。
            Button {
                toSecondaryMenu()
            } label: {
                ZStack {
                    // 透明底负责撑出整个可点区域，视觉内容浮在它上面。
                    Color.clear
                        .frame(width: 30, height: 30)
                    StateView(state: activeAccountPresenter.state.user) { user in
                        if user.avatar == nil {
                            Image(fontAwesome: .gear)
                        } else {
                            if #available(iOS 26.0, *) {
                                AvatarView(data: user.avatar?.url, customHeader: user.avatar?.customHeaders)
                            } else {
                                AvatarView(data: user.avatar?.url, customHeader: user.avatar?.customHeaders)
                                    .frame(width: 24, height: 24)
                            }
                        }
                    } errorContent: { _ in
                        Image(fontAwesome: .gear)
                    } loadingContent: {
                        Image(fontAwesome: .gear)
                    }
                    // 只让头像/齿轮本身不接收触摸，外层的透明底仍然可点。
                    .allowsHitTesting(false)
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("open_navigation_menu"))
        }
    }

    @ViewBuilder
    private var composeToolbarButton: some View {
        if case .success(let isLoggedIn) = onEnum(of: loggedInPresenter.state.isLoggedIn), !isLoggedIn.data.boolValue {
            Button {
                toServiceSelect()
            } label: {
                Text("Login")
            }
        } else if case .success(let canCompose) = onEnum(of: canComposePresenter.state.canCompose), canCompose.data.boolValue {
            Button {
                toCompose()
            } label: {
                Image(fontAwesome: .penToSquare)
                    .font(.title2)
            }
            .accessibilityLabel(Text("compose_title_new"))
        }
    }
}

private struct ChangeLogNotice: View {
    let version: String
    let onDismiss: () -> Void

    private var message: String {
        let format = String(
            localized: "changelog_current",
            defaultValue: "Version %@:\n• Bug fixes and performance improvements."
        )
        return String(format: format, locale: .current, version)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("changelog_title")
                .font(.headline)
            Text("changelog_message")
                .font(.subheadline)
                .flareSecondaryText()
            Text(message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ok", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .flareTextBackground(nil)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private final class ChangeLogAccessoryHost {
    private var hostedView: ChangeLogHostedAccessoryView?

    func view(version: String, onDismiss: @escaping () -> Void) -> ChangeLogHostedAccessoryView {
        if let hostedView { return hostedView }
        let view = ChangeLogHostedAccessoryView()
        view.update(
            AnyView(
                ChangeLogNotice(
                    version: version,
                    onDismiss: onDismiss
                )
            )
        )
        hostedView = view
        return view
    }
}

private final class ChangeLogHostedAccessoryView: UIView {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    func update(_ rootView: AnyView) {
        host.rootView = rootView
        host.view.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        } else if let parent = findParentViewController(), host.parent !== parent {
            host.willMove(toParent: nil)
            host.removeFromParent()
            parent.addChild(host)
            host.didMove(toParent: parent)
        }
    }

    private func commonInit() {
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 16.0, *) {
            host.sizingOptions = [.intrinsicContentSize]
        }
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func findParentViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }
}

private struct DeckTimelineLayout: View {
    let tabs: [UiTimelineTabItem]
    let baseTimelineAppearance: TimelineAppearance
    let columnWidth: CGFloat
    let toTabSetting: () -> Void
    let onGlobalRoute: (Route) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 0) {
                ForEach(tabs, id: \.id) { tab in
                    DeckTimelineColumnRoot(
                        tabItem: tab,
                        baseTimelineAppearance: baseTimelineAppearance,
                        toTabSetting: toTabSetting
                    )
                    .environment(\.horizontalSizeClass, .compact)
                    .ignoresSafeArea()
                    .frame(width: columnWidth)
                    .frame(maxHeight: .infinity)
                    if tab.id != tabs.last?.id {
                        Divider()
                            .ignoresSafeArea()
                    }
                }
            }
        }
    }
}

private struct DeckTimelineColumnRoot: View {
    let tabItem: UiTimelineTabItem
    let baseTimelineAppearance: TimelineAppearance
    let toTabSetting: () -> Void

    var body: some View {
        Group {
            if let nativeTab = nativeSocialTab(for: tabItem) {
                nativeSocialView(for: nativeTab)
            } else {
                TimelineScreen(tabItem: tabItem, allowGalleryMode: true, isHomeTimeline: true)
            }
        }
            .safeAreaInset(edge: .bottom) {
                Label {
                    TimelineTabTitle(title: tabItem.title)
                } icon: {
                    TabIcon(tabItem: tabItem)
                }
                .padding()
            }
            .environment(\.timelineAppearance, baseTimelineAppearance)
            .id("\(tabItem.id):\(tabItem.contentSourceKey)")
    }
}

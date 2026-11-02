import SwiftUI
import Perception
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import UIKit

@main
struct FlareApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// 上次启动连续失败时先停在安全模式界面，保证 App 至少能打开。
    /// 注意：必须在 `LaunchGuard.begin()` 之后再取初值，否则拿到的是上一次运行的值，
    /// 第一次该进安全界面时会被跳过。
    @State private var showRecovery: Bool

    init() {
        // 上次启动如果没走完看门狗，这一次先停掉隐藏网页，至少保证 App 能打开。
        LaunchGuard.begin()
        let recovering = LaunchGuard.recoveryMode
        _showRecovery = State(initialValue: recovering)
        // 崩溃兜底界面**不碰 Kotlin**。
        //
        // 15 Pro Max 上是「登录 Instagram 成功那一刻开始，每次冷启动都闪退」。
        // 崩溃可能就发生在 Koin 建容器 / 恢复账号与标签栏这一段，而那段代码在
        // App.init 里同步跑：只要它崩，SwiftUI 根本没机会画安全模式界面，
        // 用户看到的就是「点了图标闪一下就没了」，装新版也救不回来。
        // 所以进兜底时把整段初始化跳过去，先把界面画出来，让用户能做出选择。
        if !recovering {
            bootstrap()
        }
    }

    /// Kotlin / Firebase / 桥接的初始化。只在**不进兜底界面**时调用。
    private func bootstrap() {
        MediaCacheMaintenance.configure()
        configureAudioSessionForMixing()
        configureBarAppearances()
        let firebaseEnabled = FirebaseBootstrap.configureIfAvailable()
        if firebaseEnabled {
            AppleSharedHelper.shared.setupCrashlytics()
        }
        AppleSharedHelper.shared.initialize(
            inAppNotification: SwiftInAppNotification.shared,
            swiftFormatter: Formatter.shared,
            swiftPlatformTextRenderer: PlatformTextRenderer.shared,
            swiftOnDeviceAI: FoundationModelOnDeviceAI.shared
        )
        // 三个 Bridge 只是把网页登录拿到的 cookie 转交给原生 Store，本身不建页面。
        // 但仍然放到首帧之后：冷启动那一秒里少做一点事，少一个崩的机会。
        DispatchQueue.main.async {
            // 小红书的接口要 X-S / X-T，这两个值只能在网页里算。Kotlin 侧只定义了
            // 协议，真正的请求还是走这边已经跑通的 XhsService（隐藏 WKWebView 签名）。
            XhsBridgeHolder.shared.bridge = XhsSwiftBridge()
            // Instagram 登录成功后把 cookie 同步给原生 InstagramStore，
            // 侧边栏的原生页就不用再登录一次。
            InstagramBridgeHolder.shared.bridge = InstagramSwiftBridge()
            // 微信读书在「添加账号」里登录成功后，cookie 要交给原生的 WereadStore，
            // 书架页才会立刻变成已登录状态。
            WeReadBridgeHolder.shared.bridge = WereadSwiftBridge()
        }
    }
    var body: some Scene {
        WindowGroup {
            // iOS 15 没有 Observation 框架，必须在根部建立 perception 追踪作用域。
            WithPerceptionTracking {
                if showRecovery {
                    // 兜底界面必须在 FlareTheme **外面**：FlareTheme 里会
                    // new KotlinPresenter(EnvironmentSettingsPresenter())，而兜底路径
                    // 压根没初始化 Kotlin，包在里面等于白兜底。
                    recoveryScreen
                } else {
                    FlareTheme {
                        root
                    }
                    .modifier(IOSTimelineListEnvironment())
                    .ugoiraExportStatus()
                    .backportOnChange(of: scenePhase) { _, phase in
                        MediaCacheMaintenance.handleScenePhase(phase)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--media-viewer-test") {
            MediaViewerTestFixture()
        } else {
            appRoot
        }
        #else
        appRoot
        #endif
    }

    /// 兜底界面：纯 SwiftUI，不碰 Kotlin / Store / WebView。
    private var recoveryScreen: some View {
        LaunchRecoveryView(
            onRetry: {
                // 兜底界面没初始化 Kotlin，没法在原地接着跑主界面：
                // 记下「下次正常启动」的标记后退出，用户再点一次图标即可。
                // 注意：这里**不能**把 showRecovery 置 false —— 那会让 SwiftUI
                // 立刻去渲染 FlareRoot()，而 Kotlin 容器压根没建，0.8 秒内又崩一次。
                LaunchGuard.prepareRelaunch()
                LaunchGuard.relaunch()
            },
            onPurgeInstagram: {
                LaunchGuard.purgeInstagramAndExitRecovery()
                LaunchGuard.prepareRelaunch()
                LaunchGuard.relaunch()
            }
        )
    }

    @ViewBuilder
    private var appRoot: some View {
        if #available(iOS 18.0, *) {
            FlareRoot()
                .onAppear { LaunchGuard.markFullUIShown() }
        } else {
            BackportFlareRoot()
                .onAppear { LaunchGuard.markFullUIShown() }
        }
    }
    
    func configureAudioSessionForMixing() {
        AudioSessionManager.shared.activateAmbient()
    }

    /// iOS 15 回退：Apple 在 iOS 15 把 UINavigationBar / UITabBar 的默认背景改成了透明
    /// （此前只有大标题/滚动到顶部时才透明）。Flare 在任意平台都没有显式配置 bar 外观，
    /// 于是 iOS 15 上「退出贴文详情」或「关闭媒体全屏」后，底层导航栏与标签栏会落回系统
    /// 透明默认态——图标还在、背景没了、能透出时间线内容，需手动多点几下才恢复。
    /// 这里用 configureWithDefaultBackground() 把「标准、不透明、随浅/深色自适应」的外观
    /// 设成全局默认，恢复 iOS 15 之前「栏有底色」的预期观感；该外观在 iOS 16+ 即系统默认，
    /// 跨版本安全。
    private func configureBarAppearances() {
        guard #available(iOS 15.0, *) else { return }
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = nav
        navBar.scrollEdgeAppearance = nav
        navBar.compactAppearance = nav
        navBar.compactScrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = tab
        }
    }
}

/// 启动连续失败时的最后一道防线。
///
/// 这里不碰任何 Store / WebView / Kotlin 状态，只放两个按钮：
/// 重新画主界面，或者清掉最可能出问题的 Instagram 登录后再画。
/// 只要这个界面能出来，用户就不用重装（也就不会丢账号）。
private struct LaunchRecoveryView: View {
    let onRetry: () -> Void
    let onPurgeInstagram: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("上次启动没有正常结束")
                .font(.headline)
            Text("为了不让 App 一直闪退，这次先停在安全模式：后台网页和自动刷新都关掉了，账号数据都还在，不用重装。\n点下面的按钮后 App 会自动关闭，请再点一次图标打开。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onRetry()
            } label: {
                Text("重新加载界面")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button {
                onPurgeInstagram()
            } label: {
                Text("清掉 Instagram 登录后重试")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            Text("如果重新加载又闪退，回来点第二个按钮。小红书、微信读书的登录不受影响。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

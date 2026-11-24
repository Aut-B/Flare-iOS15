import SwiftUI
import Perception
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import AVFAudio
import UIKit
import Foundation
import os

@main
struct FlareApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootPhase: BootPhase = .loading
    /// 上次崩过就在主界面顶上挂一条横幅。崩一次（安全模式）时用户根本进不到
    /// 恢复页，如果只在恢复页显示现场，第一次崩溃的记录就白存了。
    @State private var showCrashBanner = false
    /// 覆盖安装后进程没被结束（TrollStore 更新时不会杀正在运行的 App），
    /// 磁盘上已经是新版本、当前进程还跑着旧二进制。此时底栏等 UI 改动
    /// 全部不生效，用户会以为「升级了但没修」。检测到就在顶部提示重启。
    @State private var staleBuild: LaunchBuildIdentity.StaleInfo?

    private enum BootPhase {
        case loading
        case recovery
        case ready
    }

    init() {
        // 必须在启动瞬间固化「内存里的版本」：static let 是懒加载，等更新后
        // 再读 Bundle 里的 Info.plist 可能已经读到新文件，就检测不出僵尸进程了。
        LaunchBuildIdentity.captureAtLaunch()
        // 必须在任何 SwiftUI 视图 / Kotlin 初始化之前落盘启动标记：
        // 若首屏渲染阶段就崩，onAppear 永远不会执行，崩溃计数也就永远不会累加，
        // 15 Pro Max 上就会表现为「每次冷启动都闪退、兜底界面永远不出现」。
        LaunchGuard.begin()
        // 紧接着装崩溃现场记录：LaunchGuard 只知道「上次没走完」，不知道崩在哪。
        LaunchCrashTrace.install()
    }

    var body: some Scene {
        WindowGroup {
            WithPerceptionTracking {
                switch bootPhase {
                case .loading:
                    LaunchLoadingView()
                        .onAppear { startLaunch() }
                case .recovery:
                    recoveryScreen
                case .ready:
                    FlareTheme {
                        // 上次崩过（掉进安全模式）就在主界面顶上挂一条横幅：
                        // 崩 1 次时不进恢复页，用户看不到任何现场，等到崩第 2 次
                        // 才出现恢复页就已经太晚了。
                        //
                        // 用 safeAreaInset 而不是 VStack 包一层：TabView 被塞进
                        // VStack 会改变它的安全区与 tab bar 布局，风险远大于收益。
                        root
                            .safeAreaInset(edge: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    // 只依赖 @State：静态变量不参与 SwiftUI 的依赖追踪。
                                    if showCrashBanner {
                                        LaunchCrashBanner(
                                            record: LaunchCrashTrace.lastCrash,
                                            onDismiss: { showCrashBanner = false }
                                        )
                                    }
                                    if let staleBuild {
                                        LaunchUpdateBanner(
                                            info: staleBuild,
                                            onRestart: {
                                                // 这次退出不是崩溃：先清掉启动看门狗，
                                                // 否则下次启动会按「上次没走完」进安全模式。
                                                LaunchGuard.markStable()
                                                LaunchGuard.relaunch()
                                            }
                                        )
                                    }
                                }
                            }
                    }
                    .modifier(IOSTimelineListEnvironment())
                    .ugoiraExportStatus()
                    .backportOnChange(of: scenePhase) { _, phase in
                        MediaCacheMaintenance.handleScenePhase(phase)
                        if phase == .active {
                            checkForStaleBuild()
                        }
                        if phase == .background {
                            LaunchGuard.markStable()
                            // 进后台即视为本次启动成功，崩溃计数清零，
                            // 横幅没有意义了；否则用户切回来还看到「上次没完成」。
                            showCrashBanner = false
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                        Task.detached {
                            try? await PluginRuntimeLifecycleFacadeV1().onMemoryPressure()
                        }
                    }
                }
            }
        }
    }

    private func startLaunch() {
        guard case .loading = bootPhase else { return }
        LaunchCrashTrace.stage(.startLaunch)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-corrupt-instagram") {
            InstagramStateIsolator.seedCorruptStateForTesting()
        }
        #endif
        // 只要上次崩过一次（`begin()` 里已把计数 +1），就把现场摆到主界面顶上。
        // 以前只在恢复页（crashes>=2）显示，第一次崩溃的记录等于白存。
        // 有记录才显示，没记录不占版面。
        showCrashBanner = LaunchGuard.lastCrashCount >= 1 && !LaunchCrashTrace.lastCrash.isEmpty
        if LaunchGuard.recoveryMode {
            bootPhase = .recovery
            return
        }
        LaunchCrashTrace.stage(.stateIsolation)
        let quarantined = InstagramStateIsolator.quarantineIfNeeded()
        bootstrap()
        bootPhase = .ready
        if quarantined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                InstagramStateIsolator.allowAdoptionThisLaunch()
            }
        }
    }

    /// 从后台回到前台时检查：磁盘 Info.plist 的版本和本进程启动时读到的是否一致。
    /// 不一致说明安装包已经被替换、进程还是旧的；此时任何 Swift 代码修复都不会
    /// 出现在界面上，只能让用户重启一次。
    private func checkForStaleBuild() {
        guard staleBuild == nil else { return }
        staleBuild = LaunchBuildIdentity.detectStaleProcess()
    }

    private func bootstrap() {
        LaunchCrashTrace.stage(.bootstrapConfig)
        MediaCacheMaintenance.configure()
        configureAudioSessionForMixing()
        configureBarAppearances()
        let firebaseEnabled = FirebaseBootstrap.configureIfAvailable()
        if firebaseEnabled {
            AppleSharedHelper.shared.setupCrashlytics()
        }
        ProxySessionConfigurator.install()
        // Kotlin 侧初始化是启动链路上最容易整段挂掉的一步（协程里抛异常就是进程
        // abort），这里前后各打一个阶段点，崩了能一眼看出是不是它。
        LaunchCrashTrace.stage(.kotlinInitialize)
        AppleSharedHelper.shared.initialize(
            inAppNotification: SwiftInAppNotification.shared,
            swiftFormatter: Formatter.shared,
            swiftPlatformTextRenderer: PlatformTextRenderer.shared,
            swiftOnDeviceAI: FoundationModelOnDeviceAI.shared
        )
        LaunchCrashTrace.stage(.rootRendering)
        DispatchQueue.main.async {
            XhsBridgeHolder.shared.bridge = XhsSwiftBridge()
            InstagramBridgeHolder.shared.bridge = InstagramSwiftBridge()
            WeReadBridgeHolder.shared.bridge = WereadSwiftBridge()
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--media-viewer-test") {
            MediaViewerTestFixture()
        } else if ProcessInfo.processInfo.arguments.contains("--timeline-media-scroll-test") {
            TimelineMediaScrollTestFixture()
        } else {
            appRoot
        }
        #else
        appRoot
        #endif
    }

    private var recoveryScreen: some View {
        LaunchRecoveryView(
            onRetry: {
                LaunchGuard.prepareRelaunch()
                LaunchGuard.relaunch()
            },
            onPurgeInstagram: {
                InstagramStateIsolator.requestQuarantineOnNextLaunch()
                LaunchGuard.purgeInstagramAndExitRecovery()
                LaunchGuard.prepareRelaunch()
                LaunchGuard.relaunch()
            },
            onPurgeWeread: {
                LaunchGuard.purgeWereadAndExitRecovery()
                LaunchGuard.prepareRelaunch()
                LaunchGuard.relaunch()
            }
        )
    }

    @ViewBuilder
    private var appRoot: some View {
        // 15PM(iPhone, iOS18+) 走 FlareRoot 的 iOS18 新 Tab API（.sidebarAdaptable / Tab(value:role:)）
        // 会在根视图渲染阶段 SIGTRAP 闪退；而 6S 走的 BackportFlareRoot 一直稳定。
        // 这里让 iPhone 也走稳定的 BackportFlareRoot，仅在 iPad 上保留 FlareRoot（侧边栏 tab 只有 iPad 用得到）。
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            FlareRoot()
                .onAppear {
                    LaunchGuard.markFullUIShown()
                    LaunchCrashTrace.stage(.rootShown)
                }
        } else {
            BackportFlareRoot()
                .onAppear {
                    LaunchGuard.markFullUIShown()
                    LaunchCrashTrace.stage(.rootShown)
                }
        }
    }

    func configureAudioSessionForMixing() {
        AudioSessionManager.shared.activateAmbient()
    }

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

/// 「安装包已更新、当前进程还是旧的」提示条。
///
/// 只在从后台回到前台、且磁盘 Info.plist 与启动时缓存的版本不一致时出现；
/// 正常启动/切前后台永远不会触发。
private struct LaunchUpdateBanner: View {
    let info: LaunchBuildIdentity.StaleInfo
    let onRestart: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flare 已更新，当前仍是旧界面")
                    .font(.caption)
                Text("正在运行 \(info.launched.label)，已安装 \(info.installed.label)。重启后新功能才会生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                onRestart()
            } label: {
                Text("重启")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

/// 识别「覆盖安装后旧进程继续运行」。
///
/// 6S 上 TrollStore 覆盖安装不会结束正在运行的 Flare：设置里已经显示 1.8.0(120)，
/// 但进程还是几小时前启动的旧二进制（实测 pid 35588 启动于 11:36Z，build120 在
/// 12:55Z 之后才构建），所以底栏仍是旧的 Instagram 图标。两边的 bundle 路径相同
/// （都是 590F7AAC-…/Flare.app），旧进程可以直接读到被替换后的 Info.plist。
/// 这不是 SwiftUI 条件判断的问题，任何「改代码」在旧进程里都不会出现。
private enum LaunchBuildIdentity {
    struct BuildInfo {
        let version: String
        let build: String
        var label: String { "\(version) (\(build))" }
    }

    struct StaleInfo {
        let launched: BuildInfo
        let installed: BuildInfo
    }

    private static let log = Logger(subsystem: "dev.dimension.flare", category: "launch")
    private(set) static var launched: BuildInfo?

    /// 纯读文件，不经过 Bundle 的缓存，这样拿到的才是磁盘上「已安装」的版本。
    static func captureAtLaunch() {
        guard launched == nil else { return }
        launched = readInfoPlist()
    }

    static func detectStaleProcess() -> StaleInfo? {
        guard let launched = launched, let installed = readInfoPlist() else { return nil }
        guard launched.build != installed.build || launched.version != installed.version else {
            return nil
        }
        log.notice("stale process: launched \(launched.build, privacy: .public), installed \(installed.build, privacy: .public)")
        return StaleInfo(launched: launched, installed: installed)
    }

    private static func readInfoPlist() -> BuildInfo? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let build = plist["CFBundleVersion"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return BuildInfo(version: version, build: build)
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Opening Flare")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct LaunchRecoveryView: View {
    let onRetry: () -> Void
    let onPurgeInstagram: () -> Void
    let onPurgeWeread: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("上次启动没有完成")
                .font(.headline)
            Text("Flare 已停在安全模式。账号还在，不用重装。若最近登录过 Instagram，优先清掉 Instagram 登录再试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onPurgeInstagram()
            } label: {
                Text("清掉 Instagram 登录并重试")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button {
                onPurgeWeread()
            } label: {
                Text("清掉微信读书登录并重试")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            Button {
                onRetry()
            } label: {
                Text("只重新加载主界面")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            Text("小红书、微博等其它账号不受影响；微信读书若最近登录过，可单独清掉它的登录。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // 真机排查用：上一次崩在哪个阶段、异常名。没有记录时不占位置。
            // 这一块必须可滚动 + 可复制：用户直接把这段贴回来，比等 .ips 快得多。
            if !LaunchCrashTrace.lastCrash.isEmpty {
                LaunchCrashRecordView(record: LaunchCrashTrace.lastCrash)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct LaunchCrashRecordView: View {
    let record: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("上次崩溃现场")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = record
                    copied = true
                } label: {
                    Text(copied ? "已复制" : "复制")
                        .font(.caption2)
                }
            }
            ScrollView {
                Text(record)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 主界面顶部的崩溃提示条。
///
/// 只在「上次崩过、这次已经成功进到主界面」时出现：安全模式下功能是受限的
/// （隐藏网页被阻断），用户本来就会觉得「怎么写不了」，顺便把现场摆出来并
/// 让他一键复制，比只显示「上次启动没有完成」有用得多。
private struct LaunchCrashBanner: View {
    let record: String
    let onDismiss: () -> Void
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("上次启动没有完成，已进安全模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = record
                    copied = true
                } label: {
                    Text(copied ? "已复制" : "复制现场")
                        .font(.caption2)
                }
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "收起" : "展开")
                        .font(.caption2)
                }
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
            }
            // 默认收起：不挡主界面，用户想看/想复制再展开。
            if expanded {
                ScrollView {
                    Text(record)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

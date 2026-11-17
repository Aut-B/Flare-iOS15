import SwiftUI
import Perception
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import AVFAudio
import UIKit

@main
struct FlareApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootPhase: BootPhase = .loading

    private enum BootPhase {
        case loading
        case recovery
        case ready
    }

    init() {
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
                        root
                    }
                    .modifier(IOSTimelineListEnvironment())
                    .ugoiraExportStatus()
                    .backportOnChange(of: scenePhase) { _, phase in
                        MediaCacheMaintenance.handleScenePhase(phase)
                        if phase == .background {
                            LaunchGuard.markStable()
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
            }
        )
    }

    @ViewBuilder
    private var appRoot: some View {
        if #available(iOS 18.0, *) {
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
                onRetry()
            } label: {
                Text("只重新加载主界面")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            Text("小红书、微信读书等其它账号不受影响。")
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

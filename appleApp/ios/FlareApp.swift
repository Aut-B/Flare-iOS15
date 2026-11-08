import SwiftUI
import Perception
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
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

    init() {}

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
                    }
                }
            }
        }
    }

    private func startLaunch() {
        guard case .loading = bootPhase else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-corrupt-instagram") {
            InstagramStateIsolator.seedCorruptStateForTesting()
        }
        #endif
        LaunchGuard.begin()
        if LaunchGuard.recoveryMode {
            bootPhase = .recovery
            return
        }
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
                .onAppear { LaunchGuard.markFullUIShown() }
        } else {
            BackportFlareRoot()
                .onAppear { LaunchGuard.markFullUIShown() }
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
            Text("Last launch did not finish")
                .font(.headline)
            Text("Flare has paused in safe mode. Your accounts are still here; no reinstall is needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onRetry()
            } label: {
                Text("Reload main screen")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button {
                onPurgeInstagram()
            } label: {
                Text("Clear Instagram login and retry")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: 240)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            Text("Xiaohongshu, WeRead and other accounts are not affected.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

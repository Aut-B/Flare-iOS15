import SwiftUI
import Perception
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import UIKit

@main
struct FlareApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
    }
    var body: some Scene {
        WindowGroup {
            // iOS 15 没有 Observation 框架，必须在根部建立 perception 追踪作用域。
            WithPerceptionTracking {
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

    @ViewBuilder
    private var appRoot: some View {
        if #available(iOS 18.0, *) {
            FlareRoot()
        } else {
            BackportFlareRoot()
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

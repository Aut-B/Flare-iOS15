import Foundation

/// 启动崩溃兜底。
///
/// 之前 15 Pro Max 上冷启动会直接闪退：隐藏的 WKWebView 在 App 还没进前台时
/// 就被创建，窗口/场景还没就绪，偶尔还会撞上内存压力。用户看到的就是「点开
/// 图标就没了」，而且下次启动依旧，因为每次都在同一个地方崩。
///
/// 这里用一个很土的「看门狗」：启动时先落一个 active 标记，8 秒后还活着就清掉。
/// 如果下次启动发现标记还在，说明上次没走到清标记就死了，这一次就进安全模式，
/// 先不创建任何隐藏 WebView，保证 App 至少能打开；用户再重启一次即恢复。
enum LaunchGuard {
    private static let activeKey = "flare.launch.active"
    private static let safeKey = "flare.launch.safeMode"
    private static let cleanKey = "flare.launch.cleanRuns"
    /// 连续「启动后没活到清标记」的次数。
    private static let crashKey = "flare.launch.crashes"

    private(set) static var safeMode = UserDefaults.standard.bool(forKey: safeKey)

    /// 安全模式下用户仍然想试一次时置 true（只在本次运行有效）。
    private static var overrideOnce = false

    /// 现在到底要不要跑隐藏网页。
    static var webViewsBlocked: Bool { safeMode && !overrideOnce }

    /// 必须在 `FlareApp.init()` 的最前面调用。
    static func begin() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: activeKey) {
            // 上次没走到清标记就死了，进安全模式。
            let crashes = defaults.integer(forKey: crashKey) + 1
            defaults.set(crashes, forKey: crashKey)
            if crashes >= 3 {
                // 连着三次都死在启动阶段：把最可能把启动路径带崩的 Instagram
                // 凭证丢掉（用户顶多重登一次），保证 App 还能打开。
                InstagramStore.purgeStoredCookie()
                defaults.set(0, forKey: crashKey)
            }
            defaults.set(true, forKey: safeKey)
            defaults.set(0, forKey: cleanKey)
        } else {
            defaults.set(0, forKey: crashKey)
        }
        safeMode = defaults.bool(forKey: safeKey)
        overrideOnce = false
        defaults.set(safeMode, forKey: safeKey)
        defaults.set(true, forKey: activeKey)

        // 12 秒足够走完首屏；还活着就认为这次启动没问题。
        //
        // 安全模式不能一次就解除：用户装完新版常常连开好几次，如果每次
        // 都是「安全模式打开 → 清标记 → 下次又崩」，就会变成一开一崩的
        // 死循环。这里要求连续 2 次干净启动才恢复。
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            defaults.set(false, forKey: activeKey)
            guard defaults.bool(forKey: safeKey) else { return }
            let clean = defaults.integer(forKey: cleanKey) + 1
            if clean >= 2 {
                defaults.set(false, forKey: safeKey)
                defaults.set(0, forKey: cleanKey)
            } else {
                defaults.set(clean, forKey: cleanKey)
            }
        }
    }

    /// 用户在界面上点「仍然尝试」时调用：本次运行放行隐藏网页。
    static func allowThisRun() {
        overrideOnce = true
    }
}

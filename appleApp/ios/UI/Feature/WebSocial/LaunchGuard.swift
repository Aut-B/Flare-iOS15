import Foundation

/// 启动崩溃兜底。
///
/// 15 Pro Max 上出现过「登录 Instagram 成功后，每次冷启动都闪退」：
/// 崩溃发生在主界面构建阶段，重装能好但用户不愿丢账号。
///
/// 这里做两级兜底：
/// 1. 上次没走完看门狗 → 本次进入安全模式（不创建隐藏网页）；
/// 2. 连续两次都没走完 → 直接停在「安全模式界面」，先保证 App 能打开，
///    再由用户手动选择「重新加载界面」或「清掉 Instagram 登录后重试」。
enum LaunchGuard {
    private static let activeKey = "flare.launch.active"
    private static let safeKey = "flare.launch.safeMode"
    private static let crashKey = "flare.launch.crashes"
    /// 连续崩溃到这一步就不再尝试画主界面。
    private static let recoveryKey = "flare.launch.recovery"

    private(set) static var safeMode = UserDefaults.standard.bool(forKey: safeKey)
    private(set) static var recoveryMode = UserDefaults.standard.bool(forKey: recoveryKey)

    /// 安全模式下用户仍然想试一次时置 true（只在本次运行有效）。
    private static var overrideOnce = false
    /// 本次运行有没有真正把主界面画出来过。
    private static var fullUIShown = false

    /// 现在到底要不要跑隐藏网页。
    static var webViewsBlocked: Bool { safeMode && !overrideOnce }

    /// 必须在 `FlareApp.init()` 的最前面调用。
    static func begin() {
        let defaults = UserDefaults.standard
        let dirty = defaults.bool(forKey: activeKey)
        if dirty {
            // 上次没走到清标记就死了。
            let crashes = defaults.integer(forKey: crashKey) + 1
            defaults.set(crashes, forKey: crashKey)
            defaults.set(true, forKey: safeKey)
            if crashes >= 2 {
                // 连着两次：连主界面都别画了，先停到安全模式界面。
                defaults.set(true, forKey: recoveryKey)
            }
        } else {
            defaults.set(0, forKey: crashKey)
        }
        safeMode = defaults.bool(forKey: safeKey)
        recoveryMode = defaults.bool(forKey: recoveryKey)
        overrideOnce = false
        fullUIShown = false
        defaults.set(safeMode, forKey: safeKey)
        defaults.set(true, forKey: activeKey)

        // 12 秒足够走完首屏；还活着就认为这次启动没问题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            defaults.set(false, forKey: activeKey)
            guard fullUIShown else {
                // 停在安全模式界面本身不算「修好了」，下次继续停在这里。
                defaults.set(0, forKey: crashKey)
                return
            }
            defaults.set(0, forKey: crashKey)
            defaults.set(false, forKey: safeKey)
            defaults.set(false, forKey: recoveryKey)
            safeMode = false
            recoveryMode = false
        }
    }

    /// 主界面真正出现后调用。只有活过 12 秒才会清掉安全模式标记。
    static func markFullUIShown() {
        guard !fullUIShown else { return }
        fullUIShown = true
        let defaults = UserDefaults.standard
        InstagramStateIsolator.clearQuarantinePendingOnFullUI()
        // 用户可能是从安全模式界面点进来的，重新开始计时。
        defaults.set(true, forKey: activeKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard fullUIShown else { return }
            defaults.set(false, forKey: activeKey)
            defaults.set(0, forKey: crashKey)
            defaults.set(false, forKey: safeKey)
            defaults.set(false, forKey: recoveryKey)
            safeMode = false
            recoveryMode = false
        }
    }

    /// 用户在界面上点「仍然尝试」时调用：本次运行放行隐藏网页。
    static func allowThisRun() {
        overrideOnce = true
    }

    /// 安全模式界面点「重新加载界面」。
    static func exitRecovery() {
        recoveryMode = false
        UserDefaults.standard.set(false, forKey: recoveryKey)
    }

    /// 兜底界面上点完按钮：把状态收拾成「下次是一次干净启动」，然后退出进程。
    ///
    /// 兜底界面为了不被 Kotlin 初始化带崩，整段初始化是跳过的，所以没法在原地
    /// 接着画主界面 —— 只能让用户再点一次图标，重新走一遍完整的 App.init。
    static func prepareRelaunch() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: activeKey)
        defaults.set(0, forKey: crashKey)
        defaults.set(false, forKey: recoveryKey)
        // 下次仍然先按安全模式起：万一还崩，也不会一上来就把隐藏网页全拉起来。
        defaults.set(true, forKey: safeKey)
        recoveryMode = false
        safeMode = true
    }

    /// 稍等一下再退出，让「请重新打开」这句提示有机会被看到。
    static func relaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            exit(0)
        }
    }

    /// 连主界面都画不出来时：清掉 Instagram 凭证再试一次。
    static func purgeInstagramAndExitRecovery() {
        InstagramStateIsolator.requestQuarantineOnNextLaunch()
        UserDefaults.standard.set(0, forKey: crashKey)
        exitRecovery()
    }

    static var lastCrashCount: Int { UserDefaults.standard.integer(forKey: crashKey) }
}

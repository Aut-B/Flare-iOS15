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
            // 只要上次是「带着 Instagram 登录态」崩的，第一次重试就把 Instagram 隔离掉。
            // 其他账号（微博 / 小红书 / 微信读书）都不动，用户顶多重登一次 Instagram，
            // 总比每次冷启动都崩、只能重装强。
            // 以前只要上次带着 Instagram 登录态崩过一次，第一次重试就把它隔离掉，
            // 结果「登录一次后只要崩过一次就要重登」。改成连续两次没走完才隔离，
            // 单次崩溃只进安全模式，不动任何账号。
            if crashes >= 2 {
                // 连着两次：连主界面都别画了，先停到安全模式界面。
                defaults.set(true, forKey: recoveryKey)
                // 不再自动清微信读书：连续两次没走完启动不等于 WeRead 登录态
                // 有问题，直接清掉只会让用户白白重新扫码。恢复界面仍保留手动
                // 「清掉微信读书登录」，真怀疑它把启动带崩时再点。
                // 15PM 上「登录 Instagram 后每次冷启动都崩」的坏状态在
                // DbAccount / WKWebsiteDataStore 里。恢复界面出现时先隔离
                // Instagram，否则点「重新加载」还是会在 HomeTabsPresenter
                // 初始化时再崩一次。
                InstagramStateIsolator.requestQuarantineOnNextLaunch()
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
        // 崩溃可能发生在 begin() 之后几百毫秒内；不强制落盘的话，
        // 下次启动可能还看到旧的 crashKey / recoveryKey，恢复界面永远等不到。
        defaults.synchronize()

        // 这里不再用「活过 12 秒」当作启动成功：15 Pro Max 上的崩溃发生在
        // 主界面出现十几秒之后，旧的定时器会先把 activeKey 清掉、把崩溃计数归零，
        // 于是每次都是「干净启动 → 再崩」，兜底界面永远等不到。
        // 现在只有真正进入后台（说明这次启动已经稳定可用）才清标记，见 markStable()。
    }

    /// 主界面真正出现后调用。安全模式在主界面稳定存活 45 秒后解除。
    static func markFullUIShown() {
        guard !fullUIShown else { return }
        fullUIShown = true
        InstagramStateIsolator.clearQuarantinePendingOnFullUI()
        // 安全模式下隐藏网页是禁用的（小红书首页流、微信读书书架都靠它）。
        // 以前只有「进后台」才解除，用户如果一直在前台用，就会一直看到
        // 「请求失败」。主界面稳定存活 45 秒后自动解除；崩溃计数不归零，
        // 真崩了下次启动仍然会回到安全模式。
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            guard fullUIShown, safeMode else { return }
            safeMode = false
            UserDefaults.standard.set(false, forKey: safeKey)
        }
    }

    /// 进入后台时调用：这次启动已经完整可用，清掉崩溃标记。
    ///
    /// 崩溃若发生在前台（包括首屏出现后很久），activeKey 会一直保留，
    /// 下次启动继续累加崩溃计数，连续两次就会落到恢复界面。
    static func markStable() {
        guard fullUIShown else { return }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: activeKey)
        defaults.set(0, forKey: crashKey)
        defaults.set(false, forKey: safeKey)
        defaults.set(false, forKey: recoveryKey)
        safeMode = false
        recoveryMode = false
        defaults.synchronize()
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
        defaults.synchronize()
    }

    /// 稍等一下再退出，让「请重新打开」这句提示有机会被看到。
    static func relaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            exit(0)
        }
    }

    /// 清掉微信读书的本地登录态与缓存，让书架回到「重新扫码」，不触发隐藏网页。
    static func clearWereadLocalState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "weread.cookie")
        defaults.removeObject(forKey: "weread.nickname")
        defaults.removeObject(forKey: "weread.readerLinks")
        defaults.removeObject(forKey: "weread.readerLinksById")
        defaults.synchronize()
    }

    /// 恢复界面上点「清掉微信读书登录」：清本地态后走一次干净启动。
    static func purgeWereadAndExitRecovery() {
        clearWereadLocalState()
        UserDefaults.standard.set(0, forKey: crashKey)
        UserDefaults.standard.synchronize()
        exitRecovery()
    }

    /// 连主界面都画不出来时：清掉 Instagram 凭证再试一次。
    static func purgeInstagramAndExitRecovery() {
        InstagramStateIsolator.requestQuarantineOnNextLaunch()
        UserDefaults.standard.set(0, forKey: crashKey)
        UserDefaults.standard.synchronize()
        exitRecovery()
    }

    static var lastCrashCount: Int { UserDefaults.standard.integer(forKey: crashKey) }
}

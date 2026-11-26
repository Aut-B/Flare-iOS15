import Foundation
import Combine
import WebKit
import os

/// 小红书的登录态与首页流。
///
/// 取数不再直接打 `edith.xiaohongshu.com`：那条路签名能算对，但 `URLSession`
/// 的 TLS 指纹 / `X-S-Common` 和真浏览器差太多，服务端一律回 `code -1`。
/// 现在改成让一个真网页自己去请求首页流，我们只把响应 JSON 搬回原生渲染
/// （见 `WebPageHarvester`）—— 请求是页面发的，风控没有理由拦。
///
/// 万一接口钩子没生效（网页改版、响应走 Web Worker），还有一层兜底：
/// 直接把页面里已经渲染出来的卡片 DOM 抄回来。两条路谁先到用谁。
final class XhsStore: ObservableObject {
    static let shared = XhsStore()
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.xiaohongshu",
        category: "profile"
    )

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var notes: [XhsNote] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    /// 上一页是不是失败了。失败时页脚给「点此重试」，不再是一片灰。
    @Published private(set) var loadMoreFailed = false
    /// 当前是不是「关注」流。
    @Published private(set) var following = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "xhs.cookie"
    /// 只有用户主动退出才置 true，避免冷启动把系统仓库里的旧会话又捡回来。
    private let loggedOutKey = "xhs.loggedOut"
    private var loaded = false
    private var harvester: WebPageHarvester?
    /// 连续几次滚动都没捞到新内容，就当到底了，别一直空转。
    private var emptyScrolls = 0
    /// 这一轮刷新里有没有拿到过数据（接口和 DOM 都算）。
    private var receivedAnything = false
    /// 接口层已经生成的首页失败文案（例如 HTTP 461 的 `restrictionMessage`）。
    /// 网页兜底也拿不到内容时优先显示它，别让通用文案把真实状态盖掉。
    private var feedFailureMessage: String?
    /// 首页流的翻页游标（`cursor_score`）。有了它翻页就不用靠「滚网页碰运气」。
    private var cursorScore = ""
    /// 每次刷新 +1：晚到的旧请求不许再改列表。
    private var generation = 0
    /// 页脚节流：底部卡片每次进出屏幕都会触发 `onAppear`。
    private var lastLoadMoreAt = Date.distantPast
    /// 隐藏网页当前加载的是不是「关注」流。
    private var harvesterFollow: Bool?
    /// 最近打开过的详情。首页卡片只有封面/作者名，正文和多图要再打一次
    /// 详情接口；6S 上签名页冷启动要十几秒，同一篇笔记反复进出时不能每次都等。
    /// 只缓存几分钟，点赞数/评论数过期可以接受，正文和多图不会。
    private var detailCache: [String: (note: XhsNote, at: Date)] = [:]
    private var detailCacheOrder: [String] = []
    private let detailCacheLifetime: TimeInterval = 300
    /// 每次登录态真正变化都 +1。WK 异步快照 / 授权校验回来时代次变了就丢弃，
    /// 否则可能用旧 cookie 覆盖用户刚完成的新登录。
    /// Bridge 可能从任意线程调 `adopt`，所以计数要加锁。
    private let sessionGenerationLock = NSLock()
    private var sessionGeneration = 0
    /// 冷启动恢复只跑一次。初始化时不能碰 WKWebView，等真正进小红书
    /// 标签页、视图 `.task` 调 `refreshIfNeeded()` 时再开始。
    private let recoveryLock = NSLock()
    private var recoveryStarted = false

    private static let recommendURL = "https://www.xiaohongshu.com/explore"
    private static let followURL = "https://www.xiaohongshu.com/explore?channel_id=homefeed.follow"

    private init() {
        let loggedOut = defaults.bool(forKey: loggedOutKey)
        if loggedOut {
            defaults.removeObject(forKey: cookieKey)
        }
        let stored = defaults.string(forKey: cookieKey) ?? ""
        let cookie = Self.sanitizeHeader(stored)
        if !stored.isEmpty, cookie != stored {
            defaults.set(cookie, forKey: cookieKey)
        }
        // 存过的 cookie 是上次登录 / Bridge 同步的结果，有 `web_session`
        // 就直接恢复，冷启动不再要求重登。只有本地没有时才去系统仓库捡候选，
        // 那种候选可能是游客会话，必须用 `selfProfile()` 校验后才 adopt。
        isLoggedIn = !loggedOut && Self.hasSession(inHeader: cookie)
        pushCredentials()
        // 这里**绝对不能**碰 WKWebView。
        //
        // `XhsStore.shared` 会在 TabView 构建标签页时就被创建，也就是冷启动
        // 首帧。此时窗口还没就绪，同步建一个 1280x1600 的隐藏页面，在
        // 15 Pro Max 上会直接把进程带走（用户看到的就是「点开就闪退」）。
        // 签名页改成真正要用的时候（进小红书标签页取数）再懒创建；
        // 登录态恢复也放在 `refreshIfNeeded()` 里，不在 init 启动。
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
    }

    nonisolated private static func sanitizeHeader(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "; ")
            .replacingOccurrences(of: "\n", with: "; ")
            .replacingOccurrences(of: "\r", with: "; ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func hasSession(inHeader header: String) -> Bool {
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let index = piece.firstIndex(of: "=") else { continue }
            guard String(piece[piece.startIndex..<index]) == "web_session" else {
                continue
            }
            let value = String(piece[piece.index(after: index)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty
        }
        return false
    }

    nonisolated private static func xhsCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { $0.domain.lowercased().contains("xiaohongshu.com") }
    }

    nonisolated private static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { $0.domain.contains("xiaohongshu.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 本地没有可用 `web_session` 时（例如旧版本 `-100` 把 `xhs.cookie` 删了），
    /// 网页登录态可能还在系统
    /// cookie 仓库里。这里按「本地缓存 → URLSession 共享仓库 → WK 网页仓库」
    /// 依次取候选；每个候选都要先问一次 `selfProfile()`，成功才落盘。
    /// 游客 `web_session` 不能直接当登录态。调用方必须已经在小红书标签页里，
    /// 否则 `selfProfile()` 会提前建隐藏 WKWebView，拖垮冷启动。
    private func recoverFromSharedStorage() async {
        let generation = sessionGenerationToken()
        var candidates: [(header: String, cookies: [HTTPCookie])] = []
        func addCandidate(_ raw: String, cookies: [HTTPCookie]) {
            let header = Self.sanitizeHeader(raw)
            guard !header.isEmpty,
                  !candidates.contains(where: { $0.header == header })
            else { return }
            candidates.append((header, cookies))
        }
        addCandidate(defaults.string(forKey: cookieKey) ?? "", cookies: [])
        if let cookies = HTTPCookieStorage.shared.cookies {
            let targets = Self.xhsCookies(from: cookies)
            addCandidate(Self.cookieHeader(from: targets), cookies: targets)
        }
        // 必须先把 WK 快照读完再校验：`validateSession` 会把候选写进共享
        // WK cookie 仓库，先校验本地旧串可能把网页里刚刷新过的有效会话覆盖掉。
        let cookies = await webKitCookies()
        guard canRestore(generation: generation) else { return }
        let targets = Self.xhsCookies(from: cookies)
        addCandidate(Self.cookieHeader(from: targets), cookies: targets)
        // 回调期间可能已经扫码登录 / Bridge adopt / 主动退出。
        for candidate in candidates {
            guard canRestore(generation: generation) else { return }
            if await validateAndAdopt(
                cookieHeader: candidate.header,
                cookies: candidate.cookies
            ) {
                return
            }
        }
    }

    private func canRestore(generation: Int) -> Bool {
        generation == sessionGenerationToken()
            && !isLoggedIn
            && !defaults.bool(forKey: loggedOutKey)
    }

    private func beginRecovery() -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        guard !recoveryStarted else { return false }
        recoveryStarted = true
        return true
    }

    private func webKitCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// 系统仓库里的候选 cookie 先问一次服务端「我是谁」，成功才落盘；
    /// 游客 `web_session` 会在 `selfProfile()` 里被 -100 拒掉，不会变成
    /// 假登录态。
    private func validateAndAdopt(
        cookieHeader header: String,
        cookies: [HTTPCookie]
    ) async -> Bool {
        let generation = sessionGenerationToken()
        let valid = await XhsService.shared.validateSession(cookie: header)
        guard valid, canRestore(generation: generation) else { return false }
        guard adopt(cookieHeader: header) else { return false }
        if !cookies.isEmpty {
            CookieJar.syncToSharedStorage(cookies)
        }
        scheduleRecoveryRefresh()
        return true
    }

    /// 冷启动恢复晚于视图的 `.task`：`isLoggedIn` 翻成 true 时不会重跑
    /// `.task`，这里补一次首页请求。`adopt` 的状态更新先入主队列，
    /// 所以这个 block 执行时已经可以安全发请求。
    private func scheduleRecoveryRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLoggedIn else { return }
            Task { await self.refresh() }
        }
    }

    // MARK: - 登录态

    private func sessionGenerationToken() -> Int {
        sessionGenerationLock.lock()
        defer { sessionGenerationLock.unlock() }
        return sessionGeneration
    }

    private func bumpSessionGeneration() {
        sessionGenerationLock.lock()
        sessionGeneration += 1
        sessionGenerationLock.unlock()
    }

    @discardableResult
    func adopt(cookies: [HTTPCookie]) -> Bool {
        let header = Self.cookieHeader(from: Self.xhsCookies(from: cookies))
        guard Self.hasSession(inHeader: header) else { return false }
        bumpSessionGeneration()
        defaults.set(header, forKey: cookieKey)
        defaults.set(false, forKey: loggedOutKey)
        pushCredentials()
        // 签名页面的 cookie 也换了，重新加载一次让它拿到新会话。
        XhsSigner.shared.applyCookies(header, force: true)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
            self.loaded = false
        }
        CookieJar.syncToSharedStorage(cookies)
        return true
    }

    /// 直接吃一段原始 cookie 串（Kotlin 登录成功后通过 `XhsBridge` 同步过来）。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        let header = Self.sanitizeHeader(raw)
        guard Self.hasSession(inHeader: header) else { return false }
        // Kotlin 每次取数都会同步同一份 cookie；内容没变就别重置签名页。
        if isLoggedIn, cookie == header { return true }
        bumpSessionGeneration()
        defaults.set(header, forKey: cookieKey)
        defaults.set(false, forKey: loggedOutKey)
        pushCredentials()
        XhsSigner.shared.applyCookies(header, force: true)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
            self.loaded = false
        }
        return true
    }

    /// 重新登录时登录页会先把旧 cookie 清掉；用户中途取消的话，
    /// 隐藏的签名页面就变成匿名会话了。这里把已保存的 cookie 强行灌回去。
    func restoreSignerCookies() {
        guard !cookie.isEmpty else { return }
        XhsSigner.shared.applyCookies(cookie, force: true)
    }

    func logout() {
        bumpSessionGeneration()
        defaults.set(true, forKey: loggedOutKey)
        defaults.removeObject(forKey: cookieKey)
        pushCredentials()
        harvester?.stop()
        harvester = nil
        detailCache.removeAll()
        detailCacheOrder.removeAll()
        // 网页仓库里的旧会话也清掉，否则下次登录页会「一打开就已是登录态」。
        CookieJar.clear(domainSuffix: "xiaohongshu.com") {}
        for cookie in HTTPCookieStorage.shared.cookies ?? []
        where cookie.domain.lowercased().contains("xiaohongshu.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.notes = []
            self.loaded = false
            self.hasMore = true
        }
    }

    private func pushCredentials() {
        XhsService.shared.cookie = cookie
    }

    // MARK: - 首页流

    func refreshIfNeeded() async {
        if isLoggedIn {
            guard !loaded else { return }
            await refresh()
            return
        }
        // 冷启动时 `XhsStore.shared` 会在 TabView 构建标签栏时创建；
        // 等用户真正进小红书标签页（视图 `.task` 调到这里）再恢复会话，
        // 此刻创建签名页不会影响首帧启动。
        guard !defaults.bool(forKey: loggedOutKey), beginRecovery() else { return }
        await recoverFromSharedStorage()
    }

    /// 在「推荐」和「关注」之间切换，切换后重新拉第一页。
    func setFollowing(_ value: Bool) {
        guard following != value else { return }
        following = value
        loaded = false
        emptyScrolls = 0
        hasMore = true
        loadMoreFailed = false
        cursorScore = ""
        notes = []
        Task { await self.refresh() }
    }

    func refresh() async {
        guard isLoggedIn else { return }
        pushCredentials()
        generation += 1
        let token = generation
        cursorScore = ""
        emptyScrolls = 0
        lastLoadMoreAt = Date.distantPast
        detailCache.removeAll()
        detailCacheOrder.removeAll()
        DispatchQueue.main.async {
            self.isLoading = true
            self.isLoadingMore = false
            self.loadMoreFailed = false
            self.errorMessage = nil
            self.feedFailureMessage = nil
            self.hasMore = true
            self.receivedAnything = false
            // 本轮优先用签名页打接口：先把上一轮的抓取页拆掉，避免
            // 6S 上签名页 + 抓取页两个 WebContent 同时活着（519MB + 404MB）。
            self.harvester?.stop()
            self.harvester = nil
            self.harvesterFollow = nil
            // 这里**不清空** notes：刷新失败时旧内容还在，用户不会对着一片空白。
            // 成功时 `merge(replace: true)` 会整批换掉。
        }
        // 冷启动时签名页的 `cookieHeader` 还是空的：先 warmUp 的话，隐藏页会
        // 以匿名会话加载，homefeed 会被判 -100，界面看起来就像掉了登录。
        // 先把已保存的会话灌给签名页；cookie 没变时 `applyCookies` 不会重载。
        XhsSigner.shared.applyCookies(cookie)
        // 灌完 cookie 才能预热：匿名页面会被服务端判未登录，还会触发 logout。
        // 冷启动 JS 跑十几秒，提前拉起后用户点进帖子/评论时签名页已经可用。
        XhsSigner.shared.warmUp()

        // 超时要在发请求**之前**挂上：接口自己最多耗 12 秒，
        // 挂晚了用户就得对着转圈等两倍时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self else { return }
            guard token == self.generation, self.isLoading else { return }
            // 已经切到抓取页兜底时交给它自己的 8 秒超时，别在这里提前报错。
            guard self.harvester == nil else { return }
            self.isLoading = false
            if self.notes.isEmpty {
                // 拿不到任何内容就别再声称「还有下一页」；文案优先用接口
                // 已经给出的 461 / 风控原因，通用兜底文案只作为最后选择。
                self.hasMore = false
                self.errorMessage = self.feedFailureMessage ?? self.failureMessage()
            }
        }

        // 首页流优先走 `homefeed` 接口：它带 `cursor_score`，能一直往下翻，
        // 也比网页首屏那份服务端渲染的通用列表更接近 App 里的推荐流。
        let gotPages = await loadFeedPage(reset: true, token: token)
        guard token == generation, !gotPages, notes.isEmpty else { return }

        // 接口没给数据才启用抓取页兜底。这时签名页那一轮请求已经结束，
        // 互斥槽会把签名页拆掉再建抓取页，任一时刻仍只有一个隐藏页。
        startHarvester(reload: true)
        // 网页首屏要跑一会儿 JS，DOM / `__INITIAL_STATE__` 是兜底。
        scheduleDOMHarvest(delays: [2.5, 5.0])
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            guard token == self.generation, self.isLoading else { return }
            self.isLoading = false
            if self.notes.isEmpty {
                self.hasMore = false
                self.errorMessage = self.feedFailureMessage ?? self.failureMessage()
            }
        }
    }

    /// 用户点「重试」：安全模式也放行一次，别让人卡在「什么都点不动」。
    func retry() async {
        LaunchGuard.allowThisRun()
        await refresh()
    }

    func loadMore() async {
        guard isLoggedIn, !isLoading, !isLoadingMore, hasMore else { return }
        guard !notes.isEmpty else { return }
        // 底部卡片出现在屏幕上会反复触发，2 秒内只放行一次。
        let now = Date()
        guard now.timeIntervalSince(lastLoadMoreAt) > 2 else { return }
        lastLoadMoreAt = now
        let token = generation
        DispatchQueue.main.async {
            self.isLoadingMore = true
            self.loadMoreFailed = false
        }

        if await loadFeedPage(reset: false, token: token) { return }
        guard token == generation else { return }

        // 接口没给下一页：退回「滚隐藏网页 + 抄 DOM」。
        if let harvester = harvester, harvester.isRunning {
            harvester.scroll()
        } else {
            startHarvester(reload: false)
        }
        scheduleDOMHarvest(delays: [1.6, 3.2])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            guard token == self.generation, self.isLoadingMore else { return }
            self.isLoadingMore = false
            // 失败就是失败，别顺手把 `hasMore` 关掉：以前连续两次超时就
            // 永久变成「没有更多了」，用户怎么点都出不来第二页。
            self.loadMoreFailed = true
        }
    }

    /// 页脚「点此重试」：绕过 2 秒节流，不然刚失败立刻点会像没反应。
    func retryLoadMore() async {
        lastLoadMoreAt = Date.distantPast
        await loadMore()
    }

    /// 直接问 `homefeed` 要一页。拿到（或明确不用再试）返回 true。
    @discardableResult
    private func loadFeedPage(reset: Bool, token: Int) async -> Bool {
        do {
            let page = try await XhsService.shared.homeFeed(
                cursor: reset ? nil : cursorScore,
                follow: following,
                refreshType: reset ? 1 : 2,
                noteIndex: reset ? 0 : notes.count
            )
            guard token == generation else { return true }
            if page.notes.isEmpty {
                // 接口明确回了空：这就是最后一页，别再让用户对着
                // 「加载失败，点此重试」反复点。首屏为空则交给 DOM 兜底。
                if !reset {
                    DispatchQueue.main.async {
                        self.hasMore = false
                        self.isLoadingMore = false
                    }
                    // 已经知道是最后一页，直接收工：再走 DOM 兜底会让
                    // 页脚在「没有更多了」和「加载失败」之间来回跳。
                    return true
                }
                // 首屏「成功但 0 条」：build131 的 461 响应就是这个形状。
                // 先记下真实原因交给网页兜底；兜底也空时原样显示，绝不把
                // 它当成一次成功的空列表。
                DispatchQueue.main.async {
                    self.feedFailureMessage = XhsFeedState.message(
                        for: .empty,
                        restriction: self.feedFailureMessage,
                        detail: nil,
                        fallback: self.failureMessage()
                    )
                }
                return false
            }
            if let next = page.next, !next.isEmpty { cursorScore = next }
            merge(page.notes, replace: reset)
            return true
        } catch {
            guard token == generation else { return true }
            if let xhs = error as? XhsError, xhs.needLogin {
                // `-100` 经常只是隐藏页还拿着旧 cookie 或刚被风控挡了一次。
                // 以前这里直接 `logout()` 把 `xhs.cookie` 删掉，用户就得重新
                // 扫码；这里保留登录态，只提示重试。真正退出只由用户主动触发。
                DispatchQueue.main.async {
                    if reset {
                        self.errorMessage =
                            "小红书会话暂时没通过（\(xhs.message)）。登录态已保留，点「重试」再来一次；持续失败再重新登录"
                        self.isLoading = false
                    } else {
                        self.isLoadingMore = false
                        self.loadMoreFailed = true
                    }
                }
                return true
            }
            // 401 / 403 / 461 / 签名失败：`XhsService` 已经把能指导下一步的
            // 文案生成好了。这里必须留住，否则刷新会转进网页兜底并把
            // `errorMessage` 清空 —— build131 的「错误=无」就是这么来的。
            let failure = (error as? XhsError)?.message ?? error.localizedDescription
            DispatchQueue.main.async {
                if reset, self.notes.isEmpty {
                    self.feedFailureMessage = failure
                }
            }
            return false
        }
    }

    /// 抓不到数据时给一句能指导下一步的提示。
    private func failureMessage() -> String {
        let page = harvester?.currentURL ?? ""
        if page.isEmpty {
            return "后台网页没起来（没拿到页面地址）。点「重试」再来一次"
        }
        if page.contains("/login") || page.contains("login?") {
            return "小红书网页版要求登录（当前是未登录状态）。点右上角菜单 →「退出登录」，再重新扫码登录"
        }
        if let error = harvester?.lastError, !error.isEmpty {
            return "网页没打开：\(error)。检查网络后点「重试」"
        }
        return "页面打开了但没抓到首页数据。点「重试」；连续失败就重新扫码登录一次"
    }

    // MARK: - 网页抓取

    private func startHarvester(reload: Bool) {
        guard !LaunchGuard.webViewsBlocked else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage =
                    "本次启动处于安全模式（上次异常退出），已停用后台网页。点「重试」可以强制再试一次"
            }
            return
        }
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            // 页面还活着就只 reload。重建一个 1280x1600 的 WKWebView 在 6s /
            // 15 Pro Max 上要十几秒，用户看到的就是「点了刷新没反应」。
            if
                let existing = self.harvester,
                existing.isRunning,
                self.harvesterFollow == self.following
            {
                if reload { existing.reload() }
                return
            }
            self.harvester?.stop()
            let harvester = WebPageHarvester()
            self.harvester = harvester
            self.harvesterFollow = self.following
            harvester.start(
                url: self.following ? Self.followURL : Self.recommendURL,
                userAgent: WebPlatformUserAgent.desktop,
                cookie: self.cookie,
                cookieDomain: "xiaohongshu.com",
                patterns: ["/api/sns/web/v1/homefeed", "homefeed"],
                onFinish: { [weak self] in
                    // 页面渲染完再把 DOM 抄一遍，双保险。
                    self?.scheduleDOMHarvest(delays: [2.0])
                },
                onFail: { [weak self] _ in
                    self?.scheduleDOMHarvest(delays: [1.2])
                },
                onMessage: { [weak self] message in
                    self?.ingest(message)
                }
            )
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 收到页面自己发出的 homefeed 响应。这里一定是主线程。
    private func ingest(_ message: WebPageHarvester.Message) {
        guard message.url.contains("homefeed") else { return }
        guard
            let data = message.body.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        let code = XhsJSON.int(json["code"])
        guard code == 0 else {
            if code == -100 {
                // 网页自己拿匿名会话发了一次请求，不代表本地 cookie 失效。
                // 保留登录态，让用户点重试，别把整段会话删掉。
                errorMessage =
                    "小红书网页会话暂时没通过（登录态已保留）。点「重试」再来一次；持续失败再重新登录"
                isLoading = false
                if notes.isEmpty { hasMore = false }
                return
            }
            if code == 461 {
                if notes.isEmpty {
                    errorMessage =
                        "小红书首页流要求人机验证（code 461），客户端绕不过。去网页版完成验证后点「重试」；登录态已保留"
                    hasMore = false
                }
                isLoading = false
                isLoadingMore = false
                return
            }
            if code == -1 {
                if notes.isEmpty {
                    errorMessage =
                        "小红书拒绝了首页流请求（code -1），多半是风控。稍后点「重试」；持续失败就重新登录一次"
                    hasMore = false
                }
                isLoading = false
                isLoadingMore = false
                return
            }
            // 网页自己发的那次 homefeed 被风控挡了，不代表一条都拿不到：
            // DOM / `__INITIAL_STATE__` 兜底经常还有数据。有内容就别拿
            // 「请求失败 code -1」去盖住正常列表。
            if notes.isEmpty {
                errorMessage = XhsFeedState.message(
                    for: .rejected(code: code),
                    restriction: nil,
                    detail: XhsJSON.string(json["msg"]),
                    fallback: failureMessage()
                )
                hasMore = false
                isLoading = false
            }
            return
        }

        let payload = XhsJSON.object(json["data"]) ?? [:]
        var batch: [XhsNote] = []
        for item in XhsJSON.array(payload["items"]) {
            // 首页流里混着 `model_type != note` 的推荐位，跳过。
            if let type = XhsJSON.string(item["model_type"]), type != "note" { continue }
            if let note = XhsJSON.note(item, defaultSource: "pc_feed") { batch.append(note) }
        }
        guard !batch.isEmpty else {
            // code 0 但 data 为空：build131 的 461 响应体就是这样。以前这里
            // 直接 return，界面会一直停在「0 条 + hasMore=true」的假成功。
            // 现在如实收尾；接口层已经拿到的 461 / 风控文案优先显示。
            if notes.isEmpty {
                errorMessage = XhsFeedState.message(
                    for: .empty,
                    restriction: feedFailureMessage,
                    detail: nil,
                    fallback: failureMessage()
                )
                hasMore = false
                isLoading = false
                isLoadingMore = false
            }
            return
        }
        merge(batch)
    }

    // MARK: - DOM 兜底

    private func scheduleDOMHarvest(delays: [Double]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.harvestDOM()
                self?.harvestState()
            }
        }
    }

    /// 第三层兜底：首页首屏是服务端渲染的，数据就摆在 `window.__INITIAL_STATE__`
    /// 里。接口钩子被 Worker / 新版 axios 绕过、DOM 又还没铺完的时候，这条路
    /// 往往能一次拿到二三十条 —— 而且完全不依赖页面滚没滚动。
    private func harvestState() {
        guard let harvester = harvester, harvester.isRunning else { return }
        harvester.evaluate(Self.stateScript) { [weak self] text in
            guard let self = self else { return }
            guard !text.isEmpty else { return }
            guard
                let data = text.data(using: .utf8),
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                return
            }
            var batch: [XhsNote] = []
            for item in list {
                guard let note = Self.note(fromDOM: item, source: "pc_feed") else { continue }
                batch.append(note)
            }
            guard !batch.isEmpty else { return }
            self.merge(batch)
        }
    }

    private func harvestDOM() {
        guard let harvester = harvester, harvester.isRunning else { return }
        harvester.evaluate(Self.domScript) { [weak self] text in
            guard let self = self else { return }
            guard !text.isEmpty else { return }
            guard
                let data = text.data(using: .utf8),
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                return
            }
            var batch: [XhsNote] = []
            for item in list {
                guard let note = Self.note(fromDOM: item, source: "pc_feed") else { continue }
                batch.append(note)
            }
            guard !batch.isEmpty else { return }
            self.merge(batch)
        }
    }

    // MARK: - 互动

    /// 点赞 / 取消点赞。界面先自己改状态，这里只负责发请求和回写列表。
    func setLiked(_ note: XhsNote, liked: Bool) async throws {
        if liked {
            try await XhsService.shared.like(noteId: note.id)
        } else {
            try await XhsService.shared.unlike(noteId: note.id)
        }
        DispatchQueue.main.async {
            if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                self.notes[index].liked = liked
            }
        }
    }

    func setCollected(_ note: XhsNote, collected: Bool) async throws {
        if collected {
            try await XhsService.shared.collect(noteId: note.id)
        } else {
            try await XhsService.shared.uncollect(noteId: note.id)
        }
        DispatchQueue.main.async {
            if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                self.notes[index].collected = collected
            }
        }
    }

    // MARK: - 评论

    private struct CommentPageRace {
        var source: String?
        var page: (items: [XhsComment], next: String?)?
        var error: XhsError?
        var loginError: XhsError?
    }

    /// 任务组的结果要跨并发域传回主线程，只带可 `Sendable` 的值。
    private nonisolated struct CommentPageOutcome: Sendable {
        let source: String
        let items: [XhsComment]?
        let next: String?
        let error: XhsError?
    }

    /// 单个来源的评论请求。任务组只捕获值，不会把 `XhsStore` 本身
    /// 带进 @Sendable 闭包。
    private static func loadCommentPage(
        noteId: String,
        token: String,
        source: String,
        cursor: String?
    ) async -> CommentPageOutcome {
        do {
            let page = try await XhsService.shared.comments(
                noteId: noteId,
                xsecToken: token,
                cursor: cursor,
                xsecSource: source
            )
            return CommentPageOutcome(
                source: source,
                items: page.items,
                next: page.next,
                error: nil
            )
        } catch {
            return CommentPageOutcome(
                source: source,
                items: nil,
                next: nil,
                error: (error as? XhsError)
                    ?? XhsError(message: error.localizedDescription, needLogin: false)
            )
        }
    }

    /// 最多同时试两个来源，谁先成功用谁。6S 上签名页一次失败要等 10 秒，
    /// 串行枚举 5 个来源时用户就是对着评论区空白转很久。
    private func raceCommentSources(
        _ sources: [String],
        noteId: String,
        token: String,
        cursor: String?
    ) async -> CommentPageRace {
        await withTaskGroup(of: CommentPageOutcome.self) { group in
            var next = 0
            for _ in 0..<min(2, sources.count) {
                let source = sources[next]
                next += 1
                group.addTask {
                    await Self.loadCommentPage(
                        noteId: noteId,
                        token: token,
                        source: source,
                        cursor: cursor
                    )
                }
            }

            var outcome = CommentPageRace()
            while let page = await group.next() {
                if let items = page.items {
                    group.cancelAll()
                    outcome.source = page.source
                    outcome.page = (items, page.next)
                    return outcome
                }
                if let error = page.error, error.needLogin {
                    group.cancelAll()
                    outcome.loginError = error
                    return outcome
                }
                outcome.error = page.error
                if next < sources.count {
                    let source = sources[next]
                    next += 1
                    group.addTask {
                        await Self.loadCommentPage(
                            noteId: noteId,
                            token: token,
                            source: source,
                            cursor: cursor
                        )
                    }
                }
            }
            return outcome
        }
    }

    private static func loadDetailCandidate(
        noteId: String,
        token: String,
        source: String,
        timeout: TimeInterval
    ) async -> (token: String, source: String, note: XhsNote?) {
        do {
            let note = try await XhsService.shared.note(
                id: noteId,
                xsecToken: token,
                xsecSource: source,
                timeout: timeout,
                attempts: 1
            )
            return (token, source, note)
        } catch {
            return (token, source, nil)
        }
    }

    /// 评论区换 token 时同样并发试来源，拿第一个成功的详情。
    /// `requireUserID` 为 true 时（作者主页入口补 id），没有作者 id 的
    /// 「成功」不算数：继续跑剩余候选，直到有一个带 id 或候选跑完。
    private func raceFreshDetail(
        noteId: String,
        candidates: [(token: String, source: String)],
        requireUserID: Bool = false
    ) async -> (token: String, source: String, note: XhsNote)? {
        // 最坏情况和改前一致：20 秒还没成功就不再起新一轮候选，
        // 别让 6 个候选串成 30 秒以上的等待。
        let deadline = Date().addingTimeInterval(20)
        return await withTaskGroup(of: (token: String, source: String, note: XhsNote?).self) { group in
            var next = 0
            for _ in 0..<min(2, candidates.count) {
                let candidate = candidates[next]
                next += 1
                let timeout = min(10, max(deadline.timeIntervalSinceNow, 1))
                group.addTask {
                    await Self.loadDetailCandidate(
                        noteId: noteId,
                        token: candidate.token,
                        source: candidate.source,
                        timeout: timeout
                    )
                }
            }
            while let outcome = await group.next() {
                if let note = outcome.note,
                   !requireUserID || !note.user.id.isEmpty {
                    group.cancelAll()
                    return (outcome.token, outcome.source, note)
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 1, next < candidates.count {
                    let candidate = candidates[next]
                    next += 1
                    group.addTask {
                        await Self.loadDetailCandidate(
                            noteId: noteId,
                            token: candidate.token,
                            source: candidate.source,
                            timeout: min(10, remaining)
                        )
                    }
                }
            }
            return nil
        }
    }

    func comments(note: XhsNote, cursor: String?) async throws -> (items: [XhsComment], next: String?) {
        var token = note.xsecToken
        var lastError: Error?

        // 从笔记页进评论区时网页用的是 `pc_note`；首页卡片进详情则可能是
        // `pc_feed`。先把笔记自己带的来源排在最前 —— 从用户主页 / 搜索点进来的
        // token 是 `pc_user` / `pc_search` 发的，只试这两个固定来源永远对不上。
        var sources: [String] = []
        for candidate in [note.xsecSource, "pc_note", "pc_feed", "pc_user", "pc_search"] where !candidate.isEmpty {
            if !sources.contains(candidate) { sources.append(candidate) }
        }

        // 换到新 token 后写回列表：否则下次进评论区又拿旧 token 连试两次，
        // 用户看到的就是「每次都要等半天才出评论」。来源一起写回 ——
        // 不记的话每次都要把 pc_note / pc_feed / 自身来源全试一遍。
        //
        // 不能拿 `value != note.xsecToken` 当唯一条件：token 可能没变，
        // 但来源是这次才试出来的，那也要记下来。
        //
        // 定义必须排在第一次调用之前：Swift 的局部函数不做提升。
        func remember(_ value: String, source: String? = nil) {
            // token 可能本来就是空的（公开笔记），但来源仍然值得记下来：
            // 不记的话下次从同一个入口进来还要把 pc_note / pc_feed 全试一遍。
            let tokenChanged = !value.isEmpty && value != note.xsecToken
            let sourceChanged = source.map { !$0.isEmpty && $0 != note.xsecSource } ?? false
            guard tokenChanged || sourceChanged else { return }
            DispatchQueue.main.async {
                if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                    if tokenChanged { self.notes[index].xsecToken = value }
                    if sourceChanged, let source = source {
                        self.notes[index].xsecSource = source
                    }
                }
            }
        }

        let first = await raceCommentSources(
            sources,
            noteId: note.id,
            token: token,
            cursor: cursor
        )
        if let loginError = first.loginError { throw loginError }
        if let page = first.page {
            // 第一轮就成功也要记来源：从用户主页进来的笔记，第一次是靠
            // 枚举试出来的，不记下来下次还要再枚举一遍。
            remember(token, source: first.source)
            return page
        }
        lastError = first.error

        // 卡片上的 xsec_token 会过期。过期后服务端一律回「当前笔记暂时无法浏览」，
        // 这时用详情接口换一个新 token。详情接口本身也要选对来源。
        if let freshResult = await raceFreshDetail(
            noteId: note.id,
            candidates: sources.map { (token, $0) }
        ) {
            let source = freshResult.source
            let fresh = freshResult.note

            let refreshedToken = fresh.xsecToken
            let sourceChanged = !fresh.xsecSource.isEmpty && fresh.xsecSource != source
            let tokenChanged =
                refreshedToken.isEmpty ? !token.isEmpty : refreshedToken != token
            // 详情成功但没给新 token 是常见的（公开笔记本来就没有 token）。
            // 以前这里用 `!fresh.xsecToken.isEmpty` 把这种成功结果直接丢掉，
            // 评论区永远停在第一轮的错误上。只要 token 或来源有变化，就用
            // 刷新后的组合再试一次；两样都没变就说明没有新组合可试了。
            if tokenChanged || sourceChanged {
                var retryTokens: [String] = []
                if refreshedToken.isEmpty {
                    // 旧 token 已经在第一轮把所有来源都试过了；只有详情回了
                    // 不同来源时，旧 token + 新来源才是没试过的组合。
                    if !token.isEmpty, sourceChanged { retryTokens.append(token) }
                    // 详情说这条笔记可见，评论区却拒了旧 token：公开笔记用空
                    // token 再试一次，和详情页的兜底保持一致。
                    retryTokens.append("")
                } else {
                    token = refreshedToken
                    retryTokens.append(token)
                }

                // 详情接口回的 token 自带来源：先按它自己的来，再退到本次请求
                // 的来源。一次刷新只试这两个，不把五个来源再铺一遍。
                var retries: [String] = []
                for candidate in [fresh.xsecSource, source] where !candidate.isEmpty {
                    if !retries.contains(candidate) { retries.append(candidate) }
                }
                for retryToken in retryTokens {
                    for retrySource in retries {
                        let retry = await raceCommentSources(
                            [retrySource],
                            noteId: note.id,
                            token: retryToken,
                            cursor: cursor
                        )
                        if let loginError = retry.loginError { throw loginError }
                        if let page = retry.page {
                            remember(retryToken, source: retry.source ?? retrySource)
                            return page
                        }
                        if let error = retry.error { lastError = error }
                    }
                }
            }
            // 详情已经成功，这次重试就是拿它给的组合；再换来源刷详情只会
            // 多等 10 秒（最坏 5 次），不会有新的 token。
        }

        if let error = lastError { throw error }
        throw XhsError(
            message: "没拿到这条笔记的评论凭证，回首页刷新后再点进来一次",
            needLogin: false
        )
    }

    func postComment(note: XhsNote, content: String) async throws -> XhsComment? {
        let comment = try await XhsService.shared.postComment(noteId: note.id, content: content)
        DispatchQueue.main.async {
            if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                let current = Int(self.notes[index].commentCount) ?? 0
                self.notes[index].commentCount = current > 0 ? String(current + 1) : ""
            }
        }
        return comment
    }

    // MARK: - 用户主页

    func profile(userId: String) async throws -> XhsProfile {
        try await XhsService.shared.profile(userId: userId)
    }

    func selfProfile() async throws -> XhsProfile {
        try await XhsService.shared.selfProfile()
    }

    func userNotes(userId: String, cursor: String?) async throws -> (notes: [XhsNote], next: String?) {
        try await XhsService.shared.userNotes(userId: userId, cursor: cursor)
    }

    /// 详情页先查缓存：同一篇笔记刚看过时直接出正文和多图，不再等接口。
    func cachedDetail(for noteId: String) -> XhsNote? {
        guard let entry = detailCache[noteId] else { return nil }
        guard Date().timeIntervalSince(entry.at) < detailCacheLifetime else {
            detailCache[noteId] = nil
            detailCacheOrder.removeAll { $0 == noteId }
            return nil
        }
        return entry.note
    }

    func rememberDetail(_ note: XhsNote) {
        detailCache[note.id] = (note, Date())
        detailCacheOrder.removeAll { $0 == note.id }
        detailCacheOrder.append(note.id)
        // 只留最近 24 篇，每篇只是图片地址和文字，不占多少内存。
        while detailCacheOrder.count > 24 {
            let removed = detailCacheOrder.removeFirst()
            detailCache[removed] = nil
        }
    }

    /// 拉详情：并发试来源，成功一次就记进缓存。首页卡片 -> 详情页、
    /// 评论换 token、作者 id 补齐都走这里，避免三条路径各自串行枚举。
    func detail(
        for note: XhsNote,
        allowCache: Bool = true,
        requireUserID: Bool = false
    ) async -> XhsNote? {
        if allowCache, let cached = cachedDetail(for: note.id),
           !requireUserID || !cached.user.id.isEmpty {
            return cached
        }
        var candidates: [(token: String, source: String)] = [
            (note.xsecToken, note.xsecSource),
            (note.xsecToken, "pc_note"),
            (note.xsecToken, "pc_feed"),
            (note.xsecToken, "pc_user"),
            (note.xsecToken, "pc_search"),
        ]
        if !note.xsecToken.isEmpty {
            candidates.append(("", "pc_note"))
        }
        var seen = Set<String>()
        candidates = candidates.filter {
            seen.insert("\($0.token)|\($0.source)").inserted
        }
        guard
            let result = await raceFreshDetail(
                noteId: note.id,
                candidates: candidates,
                requireUserID: requireUserID
            )
        else { return nil }
        // 详情只补全首页已有卡片：从作者主页/搜索进来的笔记不在首页流里，
        // 不能因为看了详情就被追加进首页，也不能把 refresh 的加载状态提前收掉。
        merge(
            [result.note],
            appendUnknown: false,
            affectsFeedState: false,
            preferIncomingVideo: true
        )
        // 缺作者 id 的结果不缓存，否则 5 分钟内重试都拿到同一份不完整数据。
        if !requireUserID || !result.note.user.id.isEmpty {
            rememberDetail(result.note)
        }
        return result.note
    }

    /// 卡片上缺作者 id 时补一次详情。首页 DOM 经常只给昵称，
    /// 详情接口的 `note_card.user.userId` 才是主页接口要的 id。
    func resolvedDetail(for note: XhsNote) async -> XhsNote? {
        if let cached = cachedDetail(for: note.id), !cached.user.id.isEmpty {
            return cached
        }
        guard let full = await detail(for: note, allowCache: false, requireUserID: true) else {
            Self.profileLog.error(
                "note \(note.id, privacy: .public) detail fetch failed while resolving author id"
            )
            return nil
        }
        if !full.user.id.isEmpty {
            return full
        }
        Self.profileLog.error(
            "note \(note.id, privacy: .public) still has no author id after detail fetch"
        )
        return nil
    }

    /// 把错误翻成一句能显示的话。掉登录不再自动清 cookie，
    /// 由用户决定是否重新登录，避免一次瞬时 -100 就把会话删掉。
    func message(for error: Error) -> String {
        if let xhs = error as? XhsError {
            return xhs.message
        }
        return error.localizedDescription
    }

    // MARK: - 列表

    private func merge(
        _ batch: [XhsNote],
        replace: Bool = false,
        appendUnknown: Bool = true,
        affectsFeedState: Bool = true,
        preferIncomingVideo: Bool = false
    ) {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            var base = replace ? [XhsNote]() : self.notes
            var changed = false
            for note in batch {
                guard let index = base.firstIndex(where: { $0.id == note.id }) else {
                    // 详情路径只补全已有卡片，不把陌生笔记塞进首页流。
                    if appendUnknown {
                        base.append(note)
                        changed = true
                    }
                    continue
                }
                // 同一条笔记可能是「DOM 先到（无作者 id）→ 接口后到（有 id）」。
                // 以前只认新 id，后到的完整版本会被当成重复项丢掉，作者名
                // 就永远停在不可点的状态。这里把缺的字段补进已有卡片。
                var existing = base[index]
                var enriched = false
                if existing.user.id.isEmpty, !note.user.id.isEmpty {
                    existing.user = XhsUser(
                        id: note.user.id,
                        name: existing.user.name.isEmpty ? note.user.name : existing.user.name,
                        avatar: existing.user.avatar ?? note.user.avatar
                    )
                    enriched = true
                } else if existing.user.name.isEmpty, !note.user.name.isEmpty {
                    existing.user = XhsUser(
                        id: existing.user.id,
                        name: note.user.name,
                        avatar: existing.user.avatar ?? note.user.avatar
                    )
                    enriched = true
                }
                if existing.xsecToken.isEmpty, !note.xsecToken.isEmpty {
                    existing.xsecToken = note.xsecToken
                    enriched = true
                }
                // 详情返回的多图 / 视频直链比首页卡片更全：把结果并进列表，
                // 用户退出详情再进来（或详情缓存过期）时不会退回只剩封面。
                if !note.images.isEmpty {
                    var seen = Set<String>()
                    var mergedImages: [String] = []
                    for url in (note.images + existing.images) where !url.isEmpty {
                        if seen.insert(url).inserted { mergedImages.append(url) }
                    }
                    if mergedImages != existing.images {
                        existing.images = mergedImages
                        enriched = true
                    }
                }
                // 详情接口选出来的直链已验证；即使卡片兜底先塞了 currentSrc，
                // 也要让详情地址覆盖它。普通列表合并仍只在空缺时补。
                if let video = note.videoURL, !video.isEmpty,
                   preferIncomingVideo || existing.videoURL == nil,
                   existing.videoURL != video {
                    existing.videoURL = video
                    enriched = true
                }
                if existing.commentCount.isEmpty, !note.commentCount.isEmpty {
                    existing.commentCount = note.commentCount
                    enriched = true
                }
                if existing.likedCount.isEmpty, !note.likedCount.isEmpty {
                    existing.likedCount = note.likedCount
                    enriched = true
                }
                if existing.shareCount.isEmpty, !note.shareCount.isEmpty {
                    existing.shareCount = note.shareCount
                    enriched = true
                }
                if !existing.liked, note.liked {
                    existing.liked = true
                    enriched = true
                }
                if !existing.collected, note.collected {
                    existing.collected = true
                    enriched = true
                }
                if enriched {
                    base[index] = existing
                    changed = true
                }
            }
            if changed || replace {
                self.notes = base
                if affectsFeedState {
                    self.receivedAnything = true
                    self.emptyScrolls = 0
                    self.loaded = true
                    self.errorMessage = nil
                    self.feedFailureMessage = nil
                    // 兜底可能在「先报错、后从 DOM 拿到内容」之后才成功；
                    // 有内容就恢复翻页能力，别让前面那次失败把 hasMore
                    // 永久关掉。
                    if !self.notes.isEmpty { self.hasMore = true }
                    self.isLoading = false
                }
            }
            // 不管有没有新内容，这一轮翻页都结束了，页脚必须收起来。
            if affectsFeedState {
                self.isLoadingMore = false
            }
        }
        // `ingest` 在主线程，接口请求在后台；统一回主线程改 `@Published`。
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func note(fromDOM item: [String: Any], source: String) -> XhsNote? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        guard let cover = item["cover"] as? String, !cover.isEmpty else { return nil }
        let title = (item["title"] as? String) ?? ""
        let author = (item["author"] as? String) ?? ""
        let avatar = item["avatar"] as? String
        let likes = (item["likes"] as? String) ?? ""
        let rawAspect = (item["aspect"] as? NSNumber)?.doubleValue ?? 0.75
        let aspect = CGFloat(min(max(rawAspect, 0.5), 2.0))
        let isVideo = ((item["video"] as? NSNumber)?.intValue ?? 0) != 0
        // 首页卡片本身不带作者 id 和 xsec_token，缺了这两个：头像点不进主页，
        // 评论接口会被当成「来源不明」拒掉，详情接口也拿不到多图。
        // DOM 脚本已经从卡片里的 <a href> 把它们抠出来了。
        let uid = (item["uid"] as? String) ?? ""
        let token = (item["token"] as? String) ?? ""
        if uid.isEmpty, !author.isEmpty {
            Self.profileLog.info(
                "DOM note \(id, privacy: .public) has author \(author, privacy: .public) but no user id"
            )
        }
        var images: [String] = []
        for value in (item["images"] as? [String]) ?? [] where !value.isEmpty {
            if !images.contains(value) { images.append(value) }
        }
        if images.isEmpty { images = [cover] }
        // 视频直链只有接口/DOM 抓到了才播得起来；抓不到就只显示封面。
        let rawVideo = (item["videoURL"] as? String) ?? ""
        let videoURL = rawVideo.isEmpty ? nil : rawVideo
        return XhsNote(
            id: id,
            title: title,
            desc: "",
            user: XhsUser(id: uid, name: author, avatar: (avatar?.isEmpty ?? true) ? nil : avatar),
            images: images,
            likedCount: likes,
            isVideo: isVideo,
            aspect: aspect,
            videoURL: videoURL,
            xsecToken: token,
            // DOM 抓到的 token 是从卡片 <a href> 里抠的，来源就是当时那个页面。
            xsecSource: source
        )
    }

    /// 首页首屏是服务端渲染的，数据就摆在 `window.__INITIAL_STATE__` 里。
    private static let stateScript = """
    (function(){
      try {
        var state = window.__INITIAL_STATE__;
        if (!state) { return "[]"; }
        var out = [];
        var seen = {};
        var visited = 0;
        function text(v) {
          return (v === null || v === undefined) ? '' : String(v);
        }
        // 真实结构是 noteCard.imageList[].infoList[].url，
        // 元素形如 {infoList:[{url,imageScene}], width, height}。
        // 只认 urlDefault 的话会一张都取不到，首页就只剩封面。
        function firstURL(obj) {
          if (!obj) { return ''; }
          if (typeof obj === 'string') { return obj; }
          if (typeof obj !== 'object') { return ''; }
          var u = obj.urlDefault || obj.url_default || obj.urlPre || obj.url_pre || obj.url || obj.master_url || obj.masterUrl || '';
          if (!u) {
            var lists = [obj.infoList, obj.info_list];
            for (var l = 0; l < lists.length && !u; l++) {
              var list = lists[l];
              if (!list || !list.length) { continue; }
              for (var i = 0; i < list.length; i++) {
                var info = list[i];
                if (info && info.url) { u = info.url; break; }
              }
            }
          }
          return text(u);
        }
        function norm(u) {
          u = text(u);
          if (u.indexOf('//') === 0) { u = 'https:' + u; }
          return u;
        }
        function imageListOf(card) {
          var lists = [card.imageList, card.image_list, card.images];
          for (var l = 0; l < lists.length; l++) {
            if (lists[l] && lists[l].length) { return lists[l]; }
          }
          return null;
        }
        function coverOf(card) {
          var list = imageListOf(card);
          if (list) {
            var first = list[0];
            var u = norm(firstURL(first));
            if (u) {
              var w = Number((first && first.width) || 0);
              var h = Number((first && first.height) || 0);
              return { url: u, aspect: (w > 0 && h > 0) ? (w / h) : 0 };
            }
          }
          var c = card.cover || card.image || null;
          var cu = norm(firstURL(c));
          if (cu) {
            var cw = Number((c && c.width) || 0);
            var ch = Number((c && c.height) || 0);
            return { url: cu, aspect: (cw > 0 && ch > 0) ? (cw / ch) : 0 };
          }
          return { url: '', aspect: 0 };
        }
        function imagesOf(card) {
          var list = imageListOf(card);
          var res = [];
          if (!list) { return res; }
          for (var i = 0; i < list.length && i < 18; i++) {
            var u = norm(firstURL(list[i]));
            if (!u) { continue; }
            if (res.indexOf(u) < 0) { res.push(u); }
          }
          return res;
        }
        function isStreaming(u) {
          var s = text(u).toLowerCase();
          return s.indexOf('.m3u8') >= 0 || s.indexOf('.mpd') >= 0;
        }
        function backupOf(item) {
          var list = item && item.backup_urls;
          if (!list || !list.length) { return ''; }
          for (var b = 0; b < list.length; b++) {
            if (list[b]) { return norm(list[b]); }
          }
          return '';
        }
        // 与 XhsModels.videoURL 同一套规则：h264→h265→av1，渐进式 mp4 优先，
        // 同编码里短边 <= 720 选最大档，没有就选最小档，免得 6S 先拉高清/HLS。
        function pickStream(list) {
          var all = [];
          for (var i = 0; i < list.length; i++) {
            var item = list[i];
            if (!item || typeof item !== 'object') { continue; }
            var u = norm(item.master_url || item.masterUrl || '');
            if (!u) { u = backupOf(item); }
            if (!u) { continue; }
            var w = Number(item.width || 0);
            var h = Number(item.height || 0);
            var shortEdge = (w > 0 && h > 0) ? Math.min(w, h) : 0;
            all.push({ url: u, shortEdge: shortEdge, streaming: isStreaming(u) });
          }
          if (!all.length) { return ''; }
          var progressive = [];
          for (var p = 0; p < all.length; p++) {
            if (!all[p].streaming) { progressive.push(all[p]); }
          }
          var pool = progressive.length ? progressive : all;
          var sized = [];
          for (var s = 0; s < pool.length; s++) {
            if (pool[s].shortEdge > 0) { sized.push(pool[s]); }
          }
          if (!sized.length) { return pool[0].url; }
          var capped = [];
          for (var c = 0; c < sized.length; c++) {
            if (sized[c].shortEdge <= 720) { capped.push(sized[c]); }
          }
          var chosen = null;
          if (capped.length) {
            chosen = capped[0];
            for (var c2 = 1; c2 < capped.length; c2++) {
              if (capped[c2].shortEdge > chosen.shortEdge) { chosen = capped[c2]; }
            }
          } else {
            chosen = sized[0];
            for (var m = 1; m < sized.length; m++) {
              if (sized[m].shortEdge < chosen.shortEdge) { chosen = sized[m]; }
            }
          }
          return chosen.url;
        }
        function videoOf(card) {
          var v = card.video || card.videoInfo || card.video_info || null;
          if (!v || typeof v !== 'object') { return ''; }
          var media = v.media || v.mediaInfo || null;
          var stream = media ? (media.stream || media.streams || null) : null;
          if (!stream) {
            var direct = norm(v.masterUrl || v.master_url || v.url || '');
            return direct && !isStreaming(direct) ? direct : '';
          }
          var codecs = ['h264', 'h265', 'av1'];
          for (var c = 0; c < codecs.length; c++) {
            var arr = stream[codecs[c]];
            if (!arr || !arr.length) { continue; }
            var picked = pickStream(arr);
            if (picked) { return picked; }
          }
          return '';
        }
        function add(card) {
          if (!card || typeof card !== 'object') { return; }
          var id = text(card.noteId || card.note_id || card.id);
          if (!id || id.length < 8 || seen[id]) { return; }
          var imgs = imagesOf(card);
          var info = coverOf(card);
          var cover = info.url || (imgs.length ? imgs[0] : '');
          if (!cover) { return; }
          var user = card.user || card.author || {};
          var interact = card.interactInfo || card.interact_info || {};
          var aspect = info.aspect > 0 ? info.aspect : 0.75;
          if (aspect < 0.5) { aspect = 0.5; }
          if (aspect > 2) { aspect = 2; }
          seen[id] = true;
          out.push({
            id: id,
            cover: cover,
            images: imgs.length ? imgs : [cover],
            title: text(card.displayTitle || card.display_title || card.title || card.desc || ''),
            author: text(user.nickname || user.nickName || user.nick_name || user.name || ''),
            uid: text(user.userId || user.user_id || user.id || ''),
            avatar: norm(user.avatar || ''),
            likes: text(interact.likedCount || interact.liked_count || ''),
            token: text(card.xsecToken || card.xsec_token || ''),
            aspect: aspect,
            video: (text(card.type) === 'video') ? 1 : 0,
            videoURL: videoOf(card)
          });
        }
        function walk(node, depth) {
          if (!node || depth > 10 || visited > 40000) { return; }
          if (Object.prototype.toString.call(node) === '[object Array]') {
            for (var i = 0; i < node.length; i++) { walk(node[i], depth + 1); }
            return;
          }
          if (typeof node !== 'object') { return; }
          visited++;
          if (node.noteCard) { add(node.noteCard); }
          if (node.note_card) { add(node.note_card); }
          if (node.noteId && (node.cover || node.imageList || node.image_list)) { add(node); }
          for (var k in node) {
            if (k === 'noteCard' || k === 'note_card') { continue; }
            var v = node[k];
            if (v && typeof v === 'object') { walk(v, depth + 1); }
          }
        }
        walk(state, 0);
        return JSON.stringify(out);
      } catch (e) {
        return "[]";
      }
    })()
    """

    /// 把已经渲染出来的卡片抄回来。小红书改接口钩子会失效，改 DOM 的概率低得多。
    private static let domScript = """
    (function(){
      var out = [];
      var seen = {};
      function abs(u) {
        try { return new URL(u, location.href).href; } catch (e) { return String(u || ''); }
      }
      function pickId(href) {
        var m = String(href || '').match(/\\/(?:explore|discovery\\/item)\\/([0-9a-zA-Z]{16,32})/);
        return m ? m[1] : '';
      }
      function pickToken(href) {
        var m = String(href || '').match(/[?&]xsec_token=([^&#]+)/);
        if (!m) { return ''; }
        try { return decodeURIComponent(m[1]); } catch (e) { return m[1]; }
      }
      function pickUser(href) {
        var m = String(href || '').match(/\\/user\\/profile\\/([0-9a-zA-Z]+)/);
        return m ? m[1] : '';
      }
      function textOf(node) {
        if (!node) { return ''; }
        var t = node.innerText || node.textContent || '';
        return String(t).replace(/\\s+/g, ' ').trim();
      }
      function streamingVideo(u) {
        var s = String(u || '').toLowerCase();
        return s.indexOf('.m3u8') >= 0 || s.indexOf('.mpd') >= 0;
      }
      // DOM 里没有编码信息，但同样排除 HLS/MPD 与 blob:，有尺寸时按短边 <= 720 选档。
      function videoCandidates(vid) {
        var list = [];
        function add(u, w, h) {
          u = String(u || '').trim();
          if (!u) { return; }
          if (u.indexOf('//') === 0) { u = 'https:' + u; }
          if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) { return; }
          if (streamingVideo(u)) { return; }
          for (var i = 0; i < list.length; i++) {
            if (list[i].url === u) { return; }
          }
          list.push({ url: u, shortEdge: (w > 0 && h > 0) ? Math.min(w, h) : 0 });
        }
        var vw = Number(vid.videoWidth || 0);
        var vh = Number(vid.videoHeight || 0);
        add(vid.currentSrc, vw, vh);
        add(vid.getAttribute('src'), vw, vh);
        add(vid.getAttribute('data-src'), vw, vh);
        var sources = vid.querySelectorAll ? vid.querySelectorAll('source') : [];
        for (var s = 0; s < sources.length; s++) {
          var w = Number(sources[s].getAttribute('data-width') || 0);
          var h = Number(sources[s].getAttribute('data-height') || 0);
          add(sources[s].getAttribute('src'), w || vw, h || vh);
          add(sources[s].getAttribute('data-src'), w || vw, h || vh);
        }
        if (!list.length) { return ''; }
        var sized = [];
        for (var k = 0; k < list.length; k++) {
          if (list[k].shortEdge > 0) { sized.push(list[k]); }
        }
        if (!sized.length) { return list[0].url; }
        var capped = [];
        for (var c = 0; c < sized.length; c++) {
          if (sized[c].shortEdge <= 720) { capped.push(sized[c]); }
        }
        if (capped.length) {
          var best = capped[0];
          for (var b = 1; b < capped.length; b++) {
            if (capped[b].shortEdge > best.shortEdge) { best = capped[b]; }
          }
          return best.url;
        }
        var smallest = sized[0];
        for (var m = 1; m < sized.length; m++) {
          if (sized[m].shortEdge < smallest.shortEdge) { smallest = sized[m]; }
        }
        return smallest.url;
      }
      var anchors = document.querySelectorAll('a[href*="/explore/"], a[href*="/discovery/item/"]');
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        var href = abs(a.getAttribute('href') || a.href || '');
        var id = pickId(href);
        if (!id || seen[id]) { continue; }
        var card = a;
        for (var d = 0; d < 4 && card; d++) {
          if (card.querySelector && card.querySelector('img')) { break; }
          card = card.parentElement;
        }
        if (!card) { card = a; }
        var img = card.querySelector('img');
        if (!img) { continue; }
        var cover = img.getAttribute('src') || img.getAttribute('data-src') || '';
        if (!cover && img.getAttribute('srcset')) {
          cover = String(img.getAttribute('srcset')).split(' ')[0];
        }
        if (!cover) { continue; }
        if (cover.indexOf('//') === 0) { cover = 'https:' + cover; }
        var token = pickToken(href);
        var uid = '';
        var ua = card.querySelector('a[href*="/user/profile/"]');
        if (!ua && a.parentElement) {
          ua = a.parentElement.querySelector('a[href*="/user/profile/"]');
        }
        if (ua) { uid = pickUser(abs(ua.getAttribute('href') || ua.href || '')); }
        var title = '';
        var t = card.querySelector('[class*="title"], [class*="desc"]');
        if (t) { title = textOf(t); }
        if (!title && img.alt) { title = String(img.alt).trim(); }
        var author = '';
        var au = card.querySelector('[class*="author"] [class*="name"], [class*="user"] [class*="name"], [class*="nickname"]');
        if (au) { author = textOf(au); }
        var avatar = '';
        var av = card.querySelector('[class*="avatar"] img, img[class*="avatar"]');
        if (av) {
          avatar = av.getAttribute('src') || '';
          if (avatar.indexOf('//') === 0) { avatar = 'https:' + avatar; }
        }
        var likes = '';
        var lk = card.querySelector('[class*="like"] [class*="count"], [class*="count"]');
        if (lk) { likes = textOf(lk); }
        var imgs = [];
        var all = card.querySelectorAll ? card.querySelectorAll('img') : [];
        for (var k = 0; k < all.length && k < 18; k++) {
          var iu = all[k].getAttribute('src') || all[k].getAttribute('data-src') || '';
          if (!iu && all[k].getAttribute('srcset')) {
            iu = String(all[k].getAttribute('srcset')).split(' ')[0];
          }
          if (!iu) { continue; }
          if (iu.indexOf('//') === 0) { iu = 'https:' + iu; }
          if (imgs.indexOf(iu) < 0) { imgs.push(iu); }
        }
        if (imgs.length === 0) { imgs = [cover]; }
        var vid = card.querySelector ? card.querySelector('video') : null;
        var videoURL = vid ? videoCandidates(vid) : '';
        var w = img.naturalWidth || 0;
        var h = img.naturalHeight || 0;
        var aspect = (w > 0 && h > 0) ? (w / h) : 0.75;
        var cls = String(card.className || '') + ' ' + String(a.className || '');
        var isVideo = /video/i.test(cls) || !!vid;
        seen[id] = true;
        out.push({
          id: id,
          cover: cover,
          images: imgs,
          title: title,
          author: author,
          uid: uid,
          avatar: avatar,
          likes: likes,
          token: token,
          aspect: aspect,
          video: isVideo ? 1 : 0,
          videoURL: videoURL
        });
      }
      return JSON.stringify(out);
    })()
    """
}

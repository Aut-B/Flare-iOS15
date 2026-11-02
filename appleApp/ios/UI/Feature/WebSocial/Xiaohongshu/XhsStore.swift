import Foundation
import Combine
import WebKit

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
    private var loaded = false
    private var harvester: WebPageHarvester?
    /// 连续几次滚动都没捞到新内容，就当到底了，别一直空转。
    private var emptyScrolls = 0
    /// 这一轮刷新里有没有拿到过数据（接口和 DOM 都算）。
    private var receivedAnything = false
    /// 首页流的翻页游标（`cursor_score`）。有了它翻页就不用靠「滚网页碰运气」。
    private var cursorScore = ""
    /// 每次刷新 +1：晚到的旧请求不许再改列表。
    private var generation = 0
    /// 页脚节流：底部卡片每次进出屏幕都会触发 `onAppear`。
    private var lastLoadMoreAt = Date.distantPast
    /// 隐藏网页当前加载的是不是「关注」流。
    private var harvesterFollow: Bool?

    private static let recommendURL = "https://www.xiaohongshu.com/explore"
    private static let followURL = "https://www.xiaohongshu.com/explore?channel_id=homefeed.follow"

    private init() {
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !cookie.isEmpty
        pushCredentials()
        // 这里**绝对不能**碰 WKWebView。
        //
        // `XhsStore.shared` 会在 TabView 构建标签页时就被创建，也就是冷启动
        // 首帧。此时窗口还没就绪，同步建一个 1280x1600 的隐藏页面，在
        // 15 Pro Max 上会直接把进程带走（用户看到的就是「点开就闪退」）。
        // 签名页改成真正要用的时候（进小红书标签页取数）再懒创建。
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
    }

    // MARK: - 登录态

    func adopt(cookies: [HTTPCookie]) {
        let header = CookieJar.header(cookies, domainSuffix: "xiaohongshu.com")
        guard CookieJar.value(inHeader: header, named: "web_session") != nil else { return }
        defaults.set(header, forKey: cookieKey)
        pushCredentials()
        // 签名页面的 cookie 也换了，重新加载一次让它拿到新会话。
        XhsSigner.shared.applyCookies(header, force: true)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
            self.loaded = false
        }
        CookieJar.syncToSharedStorage(cookies)
    }

    /// 直接吃一段原始 cookie 串（Kotlin 登录成功后通过 `XhsBridge` 同步过来）。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        let header =
            raw
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard CookieJar.value(inHeader: header, named: "web_session") != nil else { return false }
        // Kotlin 每次取数都会同步同一份 cookie；内容没变就别重置签名页。
        if isLoggedIn, cookie == header { return true }
        defaults.set(header, forKey: cookieKey)
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
        defaults.removeObject(forKey: cookieKey)
        pushCredentials()
        harvester?.stop()
        harvester = nil
        // 网页仓库里的旧会话也清掉，否则下次登录页会「一打开就已是登录态」。
        CookieJar.clear(domainSuffix: "xiaohongshu.com") {}
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
        guard isLoggedIn, !loaded else { return }
        await refresh()
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
        DispatchQueue.main.async {
            self.isLoading = true
            self.isLoadingMore = false
            self.loadMoreFailed = false
            self.errorMessage = nil
            self.hasMore = true
            self.receivedAnything = false
            // 这里**不清空** notes：刷新失败时旧内容还在，用户不会对着一片空白。
            // 成功时 `merge(replace: true)` 会整批换掉。
        }
        // 签名页早点拉起来：等用户点开笔记再创建，评论区要多等十几秒。
        XhsSigner.shared.warmUp()
        startHarvester(reload: true)
        // 网页首屏要跑一会儿 JS，DOM / `__INITIAL_STATE__` 是兜底。
        scheduleDOMHarvest(delays: [2.5, 5.0])

        // 超时要在发请求**之前**挂上：接口自己最多耗 12 秒，
        // 挂晚了用户就得对着转圈等两倍时间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self else { return }
            guard token == self.generation, self.isLoading else { return }
            self.isLoading = false
            if self.notes.isEmpty {
                self.errorMessage = self.failureMessage()
            }
        }

        // 首页流优先走 `homefeed` 接口：它带 `cursor_score`，能一直往下翻，
        // 也比网页首屏那份服务端渲染的通用列表更接近 App 里的推荐流。
        _ = await loadFeedPage(reset: true, token: token)
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
                return false
            }
            if let next = page.next, !next.isEmpty { cursorScore = next }
            merge(page.notes, replace: reset)
            return true
        } catch {
            guard token == generation else { return true }
            if let xhs = error as? XhsError, xhs.needLogin {
                logout()
                return true
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
                logout()
                errorMessage = XhsError.notLoggedIn.message
                isLoading = false
                return
            }
            // 网页自己发的那次 homefeed 被风控挡了，不代表一条都拿不到：
            // DOM / `__INITIAL_STATE__` 兜底经常还有数据。有内容就别拿
            // 「请求失败 code -1」去盖住正常列表。
            if notes.isEmpty {
                errorMessage = "小红书返回 code \(code)，稍后点「重试」"
                isLoading = false
            }
            return
        }

        let payload = XhsJSON.object(json["data"]) ?? [:]
        var batch: [XhsNote] = []
        for item in XhsJSON.array(payload["items"]) {
            // 首页流里混着 `model_type != note` 的推荐位，跳过。
            if let type = XhsJSON.string(item["model_type"]), type != "note" { continue }
            if let note = XhsJSON.note(item) { batch.append(note) }
        }
        guard !batch.isEmpty else { return }
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
                guard let note = Self.note(fromDOM: item) else { continue }
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
                guard let note = Self.note(fromDOM: item) else { continue }
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

    func comments(note: XhsNote, cursor: String?) async throws -> (items: [XhsComment], next: String?) {
        do {
            return try await XhsService.shared.comments(
                noteId: note.id,
                xsecToken: note.xsecToken,
                cursor: cursor
            )
        } catch {
            // 卡片上的 xsec_token 会过期。过期后服务端一律回「当前笔记暂时无法浏览」，
            // 这时用详情接口换一个新 token 再试一次；换不到就退回原 token，
            // 再换一个 xsec_source 试一次 —— 网页从笔记页进来时用的是 pc_note。
            let fresh = try? await XhsService.shared.note(
                id: note.id,
                xsecToken: note.xsecToken,
                timeout: 8,
                attempts: 1
            )
            let token: String
            if let value = fresh?.xsecToken, !value.isEmpty {
                token = value
            } else {
                token = note.xsecToken
            }
            if let page = try? await XhsService.shared.comments(
                noteId: note.id,
                xsecToken: token,
                cursor: cursor,
                xsecSource: "pc_feed"
            ) {
                return page
            }
            return try await XhsService.shared.comments(
                noteId: note.id,
                xsecToken: token,
                cursor: cursor,
                xsecSource: "pc_note"
            )
        }
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

    /// 把错误翻成一句能显示的话；掉登录就顺手退回登录页。
    func message(for error: Error) -> String {
        if let xhs = error as? XhsError {
            if xhs.needLogin { logout() }
            return xhs.message
        }
        return error.localizedDescription
    }

    // MARK: - 列表

    private func merge(_ batch: [XhsNote], replace: Bool = false) {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            var base = replace ? [XhsNote]() : self.notes
            let known = Set(base.map { $0.id })
            let fresh = batch.filter { !known.contains($0.id) }
            if !fresh.isEmpty {
                base.append(contentsOf: fresh)
                self.notes = base
                self.receivedAnything = true
                self.emptyScrolls = 0
                self.loaded = true
                self.errorMessage = nil
                self.isLoading = false
            }
            if !fresh.isEmpty || replace {
                self.isLoading = false
            }
            // 不管有没有新内容，这一轮翻页都结束了，页脚必须收起来。
            self.isLoadingMore = false
        }
        // `ingest` 在主线程，接口请求在后台；统一回主线程改 `@Published`。
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func note(fromDOM item: [String: Any]) -> XhsNote? {
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
            xsecToken: token
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
        function videoOf(card) {
          var v = card.video || card.videoInfo || card.video_info || null;
          if (!v || typeof v !== 'object') { return ''; }
          var media = v.media || v.mediaInfo || null;
          var stream = media ? (media.stream || media.streams || null) : null;
          if (!stream) {
            return norm(v.masterUrl || v.master_url || v.url || '');
          }
          var codecs = ['h264', 'h265', 'av1'];
          for (var c = 0; c < codecs.length; c++) {
            var arr = stream[codecs[c]];
            if (!arr || !arr.length) { continue; }
            for (var j = 0; j < arr.length && j < 3; j++) {
              var item = arr[j];
              if (!item) { continue; }
              var u = norm(item.master_url || item.masterUrl || '');
              if (!u && item.backup_urls && item.backup_urls.length) {
                u = norm(item.backup_urls[0]);
              }
              if (u) { return u; }
            }
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
        var videoURL = '';
        var vid = card.querySelector ? card.querySelector('video') : null;
        if (vid) {
          videoURL = vid.getAttribute('src') || vid.currentSrc || '';
          if (!videoURL) {
            var vs = vid.querySelector('source');
            if (vs) { videoURL = vs.getAttribute('src') || ''; }
          }
          if (videoURL.indexOf('//') === 0) { videoURL = 'https:' + videoURL; }
        }
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

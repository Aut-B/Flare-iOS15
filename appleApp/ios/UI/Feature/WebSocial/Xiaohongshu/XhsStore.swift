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
        notes = []
        Task { await self.refresh() }
    }

    func refresh() async {
        guard isLoggedIn else { return }
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
            self.notes = []
            self.hasMore = true
            self.emptyScrolls = 0
            self.receivedAnything = false
        }
        startHarvester(reload: true)
        // 网页首屏要跑一会儿 JS。接口和 DOM 两条路都算，谁先到用谁。
        scheduleDOMHarvest(delays: [2.5, 5.0, 7.5, 10.0, 13.0])

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self else { return }
            guard self.isLoading else { return }
            self.isLoading = false
            if self.notes.isEmpty {
                self.errorMessage = self.failureMessage()
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
        DispatchQueue.main.async { self.isLoadingMore = true }
        if let harvester = harvester, harvester.isRunning {
            harvester.scroll()
        } else {
            startHarvester(reload: false)
        }
        scheduleDOMHarvest(delays: [2.2])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            guard self.isLoadingMore else { return }
            self.isLoadingMore = false
            self.emptyScrolls += 1
            if self.emptyScrolls >= 3 {
                self.hasMore = false
            }
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
            if !reload, let existing = self.harvester, existing.isRunning {
                existing.scroll()
                return
            }
            self.harvester?.stop()
            let harvester = WebPageHarvester()
            self.harvester = harvester
            harvester.start(
                url: self.following ? Self.followURL : Self.recommendURL,
                userAgent: WebPlatformUserAgent.desktop,
                cookie: self.cookie,
                cookieDomain: "xiaohongshu.com",
                patterns: ["/api/sns/web/v1/homefeed", "homefeed"],
                onFinish: { [weak self] in
                    // 页面渲染完再把 DOM 抄一遍，双保险。
                    self?.scheduleDOMHarvest(delays: [2.5])
                },
                onFail: { [weak self] _ in
                    self?.scheduleDOMHarvest(delays: [1.5])
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
            } else {
                errorMessage = "小红书返回 code \(code)，稍后点「重试」"
            }
            isLoading = false
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

    private func merge(_ batch: [XhsNote]) {
        let known = Set(notes.map { $0.id })
        let fresh = batch.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        notes.append(contentsOf: fresh)
        receivedAnything = true
        emptyScrolls = 0
        loaded = true
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
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
        return XhsNote(
            id: id,
            title: title,
            desc: "",
            user: XhsUser(id: "", name: author, avatar: (avatar?.isEmpty ?? true) ? nil : avatar),
            images: [cover],
            likedCount: likes,
            isVideo: isVideo,
            aspect: aspect,
            videoURL: nil
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
        function coverOf(card) {
          var c = card.cover || card.image || null;
          if (c && typeof c === 'object') {
            var url = c.urlDefault || c.urlPre || c.url || c.url_default || '';
            var w = Number(c.width || 0);
            var h = Number(c.height || 0);
            return { url: url, aspect: (w > 0 && h > 0) ? (w / h) : 0 };
          }
          if (typeof c === 'string') { return { url: c, aspect: 0 }; }
          var list = card.imageList || card.images || null;
          if (list && list.length) {
            var first = list[0];
            if (first && typeof first === 'object') {
              return { url: first.urlDefault || first.urlPre || first.url || '', aspect: 0 };
            }
            if (typeof first === 'string') { return { url: first, aspect: 0 }; }
          }
          return { url: '', aspect: 0 };
        }
        function add(card) {
          if (!card || typeof card !== 'object') { return; }
          var id = text(card.noteId || card.note_id || card.id);
          if (!id || id.length < 8 || seen[id]) { return; }
          var info = coverOf(card);
          var cover = text(info.url);
          if (!cover) { return; }
          if (cover.indexOf('//') === 0) { cover = 'https:' + cover; }
          var user = card.user || card.author || {};
          var interact = card.interactInfo || card.interact_info || {};
          var aspect = info.aspect > 0 ? info.aspect : 0.75;
          if (aspect < 0.5) { aspect = 0.5; }
          if (aspect > 2) { aspect = 2; }
          seen[id] = true;
          out.push({
            id: id,
            cover: cover,
            title: text(card.displayTitle || card.title || card.desc || ''),
            author: text(user.nickname || user.nickName || user.name || ''),
            avatar: text(user.avatar || ''),
            likes: text(interact.likedCount || interact.liked_count || ''),
            aspect: aspect,
            video: (text(card.type) === 'video') ? 1 : 0
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
          if (node.noteId && (node.cover || node.imageList)) { add(node); }
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
        var w = img.naturalWidth || 0;
        var h = img.naturalHeight || 0;
        var aspect = (w > 0 && h > 0) ? (w / h) : 0.75;
        var cls = String(card.className || '') + ' ' + String(a.className || '');
        seen[id] = true;
        out.push({
          id: id,
          cover: cover,
          title: title,
          author: author,
          avatar: avatar,
          likes: likes,
          aspect: aspect,
          video: /video/i.test(cls) ? 1 : 0
        });
      }
      return JSON.stringify(out);
    })()
    """
}

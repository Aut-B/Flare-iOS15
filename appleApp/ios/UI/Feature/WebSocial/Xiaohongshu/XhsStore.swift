import Foundation
import Combine
import WebKit

/// 小红书的登录态与首页流。
///
/// 取数不再直接打 `edith.xiaohongshu.com`：那条路签名能算对，但 `URLSession`
/// 的 TLS 指纹 / `X-S-Common` 和真浏览器差太多，服务端一律回 `code -1`。
/// 现在改成让一个真网页自己去请求首页流，我们只把响应 JSON 搬回原生渲染
/// （见 `WebPageHarvester`）—— 请求是页面发的，风控没有理由拦。
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

    private static let recommendURL = "https://www.xiaohongshu.com/explore"
    private static let followURL = "https://www.xiaohongshu.com/explore?channel_id=homefeed.follow"

    private init() {
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !cookie.isEmpty
        pushCredentials()
        // 签名页要读页面里的 a1 / webId，只有请求头里的 cookie 不够。
        // 冷启动时把本地保存的 cookie 灌进隐藏 WebView。
        if !cookie.isEmpty {
            XhsSigner.shared.applyCookies(cookie)
        }
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
        XhsSigner.shared.applyCookies(header)
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
        XhsSigner.shared.applyCookies(header)
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
        }
        startHarvester(reload: true)

        // 网页首屏要跑一会儿 JS。22 秒还一条都没捞到就报错，别让用户干等。
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
            guard let self = self else { return }
            guard self.isLoading else { return }
            self.isLoading = false
            if self.notes.isEmpty {
                self.errorMessage = "没抓到首页数据。点「重试」；连续失败就去菜单里重新登录一次"
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self = self else { return }
            guard self.isLoadingMore else { return }
            self.isLoadingMore = false
            self.emptyScrolls += 1
            if self.emptyScrolls >= 3 {
                self.hasMore = false
            }
        }
    }

    // MARK: - 网页抓取

    private func startHarvester(reload: Bool) {
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
                patterns: ["/api/sns/web/v1/homefeed"],
                onFinish: nil,
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

        let known = Set(notes.map { $0.id })
        let fresh = batch.filter { !known.contains($0.id) }
        if !fresh.isEmpty {
            notes.append(contentsOf: fresh)
            emptyScrolls = 0
            loaded = true
            errorMessage = nil
        }
        isLoading = false
        isLoadingMore = false
    }
}
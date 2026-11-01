import Foundation
import Combine
import WebKit

/// 微信读书的登录态与书架缓存。
///
/// 登录态就是浏览器 cookie，用户扫码一次能用很久；真掉线了也不藏着，
/// 书架页会直接变成「重新登录」按钮，点一下重新走扫码。
///
/// 刻意**不加 `@MainActor`**：这个类是单例，SwiftUI 视图在属性初始化器里
/// 取 `shared` 时不在主 actor 上，加了反而编不过。所有 `@Published` 的写入
/// 都显式切回主线程。
final class WereadStore: ObservableObject {
    static let shared = WereadStore()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var nickname: String
    @Published private(set) var books: [WereadBook] = []
    @Published private(set) var isLoading = false
    /// 书名 → 网页阅读器地址（`/web/reader/<hash>`）。
    ///
    /// 网页阅读器认的是那个 hash，用 `shelf/sync` 给的数字 bookId 自己拼一定
    /// 404 —— 这也是上一版「点进去白屏」的原因。hash 只能从网页书架的链接里拿。
    @Published private(set) var readerLinks: [String: String] = [:]
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "weread.cookie"
    private let nameKey = "weread.nickname"
    private let linksKey = "weread.readerLinks"

    private var harvester: WebPageHarvester?
    private var harvesting = false
    private var harvested: [WereadBook] = []

    private init() {
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = Self.looksLoggedIn(cookie)
        nickname = defaults.string(forKey: nameKey) ?? ""
        readerLinks = defaults.dictionary(forKey: linksKey) as? [String: String] ?? [:]
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
    }

    // MARK: - 登录态

    /// 从 WKWebView 的 cookie 仓库里捞微信读书的 cookie。
    static func readCookies(from store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(
                    returning: cookies.filter { $0.domain.contains("qq.com") }
                )
            }
        }
    }

    static func cookieHeader(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { $0.domain.contains("weread.qq.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    @discardableResult
    func adopt(cookies: [HTTPCookie]) -> Bool {
        let header = Self.cookieHeader(from: cookies)
        guard Self.looksLoggedIn(header) else { return false }
        defaults.set(header, forKey: cookieKey)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
        }
        return true
    }

    /// 直接吃一段**原始 cookie 串**（用户从浏览器里复制出来的）。
    ///
    /// 6s 这类老机器上 WKWebView 打不开微信读书的扫码页，只能给一条
    /// 「别处登录好，把 cookie 贴进来」的通道。返回是否被接受。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        // 从 DevTools / 扩展里复制出来的经常带换行，先摊平成 `k=v; k=v`。
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }
        let header =
            text
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
        guard Self.looksLoggedIn(header) else { return false }
        defaults.set(header, forKey: cookieKey)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
        }
        return true
    }

    /// 微信读书书架接口两样都要：`wr_vid` 是账号，`wr_skey` 才是会话。
    private static func looksLoggedIn(_ header: String) -> Bool {
        header.contains("wr_vid=") && header.contains("wr_skey=")
    }

    func logout() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nameKey)
        harvester?.stop()
        harvester = nil
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.nickname = ""
            self.books = []
            self.readerLinks = [:]
        }
    }

    /// 服务端说登录失效时调用：清掉本地 cookie，让界面回到「重新登录」。
    func handleAuthFailure() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nameKey)
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.nickname = ""
            self.books = []
            self.readerLinks = [:]
            self.errorMessage = WereadError.notLoggedIn.errorDescription
        }
    }

    // MARK: - 书架

    func refreshShelf() async {
        guard !cookie.isEmpty else { return }
        DispatchQueue.main.async { self.isLoading = true }
        do {
            let list = try await WereadService.shared.shelf(cookie: cookie)
            DispatchQueue.main.async {
                self.books = list
                self.errorMessage = nil
            }
        } catch WereadError.notLoggedIn {
            handleAuthFailure()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.errorMessage = message }
        }
        DispatchQueue.main.async { self.isLoading = false }
        // 接口只给数字 id，阅读器要的是网页里的 hash，所以顺手再抄一遍网页书架。
        syncWebShelf()
    }

    // MARK: - 网页书架（拿阅读器地址 + 补齐书单）

    /// 打开一个隐藏的真网页跑一遍线上书架：既补齐 `shelf/sync` 漏掉的书，
    /// 也把每本书在网页阅读器里的真实地址（`/web/reader/<hash>`）抄下来。
    func syncWebShelf(scrolls: Int = 3) {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard self.isLoggedIn, !self.harvesting else { return }
            self.harvesting = true
            self.harvested = []
            self.harvester?.stop()
            let harvester = WebPageHarvester()
            self.harvester = harvester
            harvester.start(
                url: "https://weread.qq.com/web/shelf",
                userAgent: WebPlatformUserAgent.desktop,
                cookie: self.cookie,
                cookieDomain: "weread.qq.com",
                patterns: ["/web/shelf/sync"],
                onFinish: { [weak self] in
                    // 书架是 JS 渲染的，等它铺完再抄链接。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.extractReaderLinks()
                    }
                },
                onMessage: { [weak self] message in
                    self?.ingestShelf(message)
                }
            )
            // 网页书架也是滚动加载，往下拉几次把书捞全。
            let steps = max(scrolls, 1)
            for index in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 2.5) { [weak self] in
                    self?.harvester?.scroll()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 2.5 + 3.0) { [weak self] in
                self?.finishHarvest()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 网页阅读器地址。书名对不上时返回 nil，调用方退回「网页书架 + 自动点开」。
    func readerLink(for book: WereadBook) -> String? {
        let key = Self.normalize(book.title)
        if let url = readerLinks[key], !url.isEmpty { return url }
        return nil
    }

    /// 阅读器里真正跳成功以后把地址记下来，下次点这本书就是秒开。
    ///
    /// 有些书的链接不在书架的 DOM 里（懒渲染、分组折叠），第一次只能靠
    /// 「网页书架 + 自动点开」，这条兜底让第二次不用再绕。
    func rememberReaderLink(title: String, url: String) {
        guard !title.isEmpty, url.contains("/web/reader/") else { return }
        let key = Self.normalize(title)
        if readerLinks[key] == url { return }
        var merged = readerLinks
        merged[key] = url
        readerLinks = merged
        defaults.set(merged, forKey: linksKey)
    }

    private func ingestShelf(_ message: WebPageHarvester.Message) {
        guard message.url.contains("/web/shelf/sync") else { return }
        guard
            let data = message.body.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }
        let list = WereadService.shared.books(fromShelfJSON: json)
        guard !list.isEmpty else { return }
        let known = Set(harvested.map { $0.id })
        harvested.append(contentsOf: list.filter { !known.contains($0.id) })
    }

    private func extractReaderLinks() {
        let script = """
        (function(){
          var out = [];
          var links = document.querySelectorAll('a[href*="/web/reader/"]');
          for (var i = 0; i < links.length; i++) {
            var a = links[i];
            var href = a.href || '';
            if (!href) { continue; }
            var title = '';
            var node = a;
            for (var d = 0; d < 5 && node; d++) {
              var attr = (node.getAttribute && node.getAttribute('title')) || '';
              if (!attr && node.querySelector) {
                var cand = node.querySelector('[class*="title"], [class*="name"]');
                if (cand) { attr = cand.textContent || ''; }
              }
              attr = String(attr || '').replace(/\\s+/g, ' ').trim();
              if (attr.length > 0 && attr.length < 80) { title = attr; break; }
              node = node.parentElement;
            }
            if (!title) { continue; }
            out.push({title: title, href: href});
          }
          return JSON.stringify(out);
        })()
        """
        harvester?.evaluate(script) { [weak self] text in
            guard let self = self else { return }
            guard
                let data = text.data(using: .utf8),
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                return
            }
            var merged = self.readerLinks
            for item in list {
                guard
                    let title = item["title"] as? String,
                    let href = item["href"] as? String,
                    !href.isEmpty
                else {
                    continue
                }
                merged[Self.normalize(title)] = href
            }
            if merged.count != self.readerLinks.count {
                self.readerLinks = merged
                self.defaults.set(merged, forKey: self.linksKey)
            }
        }
    }

    private func finishHarvest() {
        harvesting = false
        harvester?.stop()
        harvester = nil
        if !harvested.isEmpty {
            var merged = books
            let known = Set(merged.map { $0.id })
            merged.append(contentsOf: harvested.filter { !known.contains($0.id) })
            books = merged
        }
        harvested = []
    }

    private static func normalize(_ title: String) -> String {
        title
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - 章节

    func chapters(for bookId: String) async throws -> [WereadChapter] {
        do {
            return try await WereadService.shared.chapters(bookId: bookId, cookie: cookie)
        } catch WereadError.notLoggedIn {
            handleAuthFailure()
            throw WereadError.notLoggedIn
        }
    }

    func content(bookId: String, chapterUid: Int) async throws -> String {
        do {
            return try await WereadService.shared.content(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: cookie
            )
        } catch WereadError.notLoggedIn {
            handleAuthFailure()
            throw WereadError.notLoggedIn
        }
    }

    func progress(for bookId: String) async -> WereadProgress? {
        try? await WereadService.shared.progress(bookId: bookId, cookie: cookie)
    }

    func report(bookId: String, chapterUid: Int, offset: Int) {
        let cookie = cookie
        guard !cookie.isEmpty else { return }
        Task.detached(priority: .utility) {
            await WereadService.shared.reportProgress(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterOffset: offset,
                cookie: cookie
            )
        }
    }
}

import Foundation
import Combine
import WebKit

/// 小红书的登录态与首页流。
///
/// 凭证是网页版 cookie（关键 `web_session`）。签名用的隐藏网页和登录页
/// 共用 `WKWebsiteDataStore.default()`，登录完 cookie 自动同步过去，
/// 只需让那个页面重新加载一次。
final class XhsStore: ObservableObject {
    static let shared = XhsStore()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var notes: [XhsNote] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// 当前是不是「关注」流。
    @Published private(set) var following = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "xhs.cookie"
    private var nextCursor: String?
    private var loaded = false

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

    func logout() {
        defaults.removeObject(forKey: cookieKey)
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.notes = []
            self.nextCursor = nil
            self.loaded = false
        }
    }

    private func pushCredentials() {
        XhsService.shared.cookie = cookie
    }

    private func handle(_ error: Error) {
        if let error = error as? XhsError, error.needLogin {
            logout()
            DispatchQueue.main.async { self.errorMessage = error.message }
            return
        }
        let message = error.localizedDescription
        DispatchQueue.main.async { self.errorMessage = message }
    }

    // MARK: - 首页流

    func refreshIfNeeded() async {
        guard isLoggedIn, !loaded else { return }
        await refresh()
    }

    /// 在「推荐」和「关注」之间切换，切换后重新拉第一页。
    /// 由按钮直接调用，所以是同步方法 —— 内部自己起任务去刷。
    func setFollowing(_ value: Bool) {
        guard following != value else { return }
        following = value
        loaded = false
        notes = []
        nextCursor = nil
        Task { await self.refresh() }
    }

    func refresh() async {
        guard isLoggedIn else { return }
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        defer { DispatchQueue.main.async { self.isLoading = false } }
        do {
            let result = try await XhsService.shared.homeFeed(cursor: nil, follow: following)
            DispatchQueue.main.async {
                self.notes = result.notes
                self.nextCursor = result.next
                self.loaded = true
                self.errorMessage = nil
            }
        } catch {
            handle(error)
        }
    }

    func loadMore() async {
        guard isLoggedIn, let cursor = nextCursor, !isLoadingMore else { return }
        DispatchQueue.main.async { self.isLoadingMore = true }
        defer { DispatchQueue.main.async { self.isLoadingMore = false } }
        do {
            let result = try await XhsService.shared.homeFeed(cursor: cursor, follow: following)
            DispatchQueue.main.async {
                let known = Set(self.notes.map { $0.id })
                self.notes.append(contentsOf: result.notes.filter { !known.contains($0.id) })
                self.nextCursor = result.next
            }
        } catch {
            handle(error)
        }
    }
}

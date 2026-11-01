import Foundation
import Combine
import WebKit

/// Instagram 的登录态与首页时间线。
///
/// 凭证就是网页版 cookie（关键是 `sessionid`），存 UserDefaults，
/// 掉线时接口返回 401，这里清掉登录态让界面回到「重新登录」。
final class InstagramStore: ObservableObject {
    static let shared = InstagramStore()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var userName: String
    @Published private(set) var feed: [IGMedia] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "instagram.cookie"
    private let userKey = "instagram.username"
    private var nextCursor: String?
    private var loaded = false
    /// 防止重复刷新：`.task` 和下拉刷新同时触发时会叠在一起，
    /// 界面就会一直转圈。
    private var refreshing = false
    /// 上一次已经请求过的翻页游标。接口把 `next_max_id` 原样返回时，
    /// 列表底部会反复触发 `onAppear` → 无限请求 → 永远在「刷新」。
    private var lastLoadMoreCursor: String?

    private init() {
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !cookie.isEmpty
        userName = defaults.string(forKey: userKey) ?? ""
        pushCredentials()
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
    }

    // MARK: - 登录态

    func adopt(cookies: [HTTPCookie]) {
        let header = CookieJar.header(cookies, domainSuffix: "instagram.com")
        guard adopt(cookieHeader: header) else { return }
        // 顺手把 cookie 灌进 URLSession 共享仓库，网页兜底页也能直接用。
        CookieJar.syncToSharedStorage(cookies)
    }

    /// 直接吃一段原始 cookie 串（Kotlin 登录成功后通过 `InstagramBridge` 同步过来）。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        let normalized =
            raw
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只留可见 ASCII：cookie 里混进换行 / 中文时，`URLRequest.setValue`
        // 会抛 ObjC 异常直接闪退（Kotlin 也接不住）。
        let header = InstagramService.sanitizeHeader(normalized)
        guard CookieJar.value(inHeader: header, named: "sessionid") != nil else { return false }
        // Kotlin 每次取数都会把同一份 cookie 同步过来。内容没变就直接返回，
        // 否则会把用户名清空、反复请求 currentUser，时间线看起来一直在闪。
        if isLoggedIn, cookie == header { return true }
        defaults.set(header, forKey: cookieKey)
        // 之前这里把 `ds_user_id`（纯数字）当成用户名存了，界面会显示一串数字。
        // 真正的用户名异步从接口补，拿不到就留空。
        defaults.removeObject(forKey: userKey)
        pushCredentials()
        DispatchQueue.main.async {
            self.userName = ""
            self.isLoggedIn = true
            self.errorMessage = nil
            self.loaded = false
        }
        refreshUserName()
        return true
    }

    private func refreshUserName() {
        Task { [weak self] in
            guard let self else { return }
            guard let user = try? await InstagramService.shared.currentUser() else { return }
            DispatchQueue.main.async {
                self.userName = user.userName
                self.defaults.set(user.userName, forKey: self.userKey)
            }
        }
    }

    func logout() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: userKey)
        pushCredentials()
        lastLoadMoreCursor = nil
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.userName = ""
            self.feed = []
            self.nextCursor = nil
            self.loaded = false
        }
    }

    private func pushCredentials() {
        let header = cookie
        let service = InstagramService.shared
        service.cookie = header
        service.csrfToken = CookieJar.value(inHeader: header, named: "csrftoken") ?? ""
        service.userId = CookieJar.value(inHeader: header, named: "ds_user_id") ?? ""
    }

    private func handle(_ error: Error) {
        if let error = error as? IGError, error.needLogin {
            logout()
            DispatchQueue.main.async {
                self.errorMessage = error.message
            }
            return
        }
        let message = error.localizedDescription
        DispatchQueue.main.async { self.errorMessage = message }
    }

    // MARK: - 时间线

    func refreshIfNeeded() async {
        guard isLoggedIn, !loaded else { return }
        await refresh()
    }

    func refresh() async {
        guard isLoggedIn, !refreshing else { return }
        refreshing = true
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        defer {
            refreshing = false
            DispatchQueue.main.async { self.isLoading = false }
        }
        do {
            let result = try await InstagramService.shared.homeFeed(cursor: nil)
            DispatchQueue.main.async {
                self.feed = result.items
                self.nextCursor = result.next
                self.loaded = true
                self.errorMessage = nil
                self.lastLoadMoreCursor = nil
            }
        } catch {
            handle(error)
        }
    }

    func loadMore() async {
        guard isLoggedIn, let cursor = nextCursor, !isLoadingMore else { return }
        guard cursor != lastLoadMoreCursor else { return }
        lastLoadMoreCursor = cursor
        DispatchQueue.main.async { self.isLoadingMore = true }
        defer { DispatchQueue.main.async { self.isLoadingMore = false } }
        do {
            let result = try await InstagramService.shared.homeFeed(cursor: cursor)
            DispatchQueue.main.async {
                let known = Set(self.feed.map { $0.id })
                self.feed.append(contentsOf: result.items.filter { !known.contains($0.id) })
                self.nextCursor = result.next
            }
        } catch {
            handle(error)
        }
    }
}

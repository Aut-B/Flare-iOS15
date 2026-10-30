import Foundation
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
        guard CookieJar.value(inHeader: header, named: "sessionid") != nil else { return }
        defaults.set(header, forKey: cookieKey)
        let name = CookieJar.value(inHeader: header, named: "ds_user_id") ?? ""
        defaults.set(name, forKey: userKey)
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
            self.loaded = false
        }
        // 顺手把 cookie 灌进 URLSession 共享仓库，网页兜底页也能直接用。
        CookieJar.syncToSharedStorage(cookies)
    }

    func logout() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: userKey)
        pushCredentials()
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
        guard isLoggedIn else { return }
        pushCredentials()
        DispatchQueue.main.async {
            self.isLoading = true
            self.errorMessage = nil
        }
        defer { DispatchQueue.main.async { self.isLoading = false } }
        do {
            let result = try await InstagramService.shared.homeFeed(cursor: nil)
            DispatchQueue.main.async {
                self.feed = result.items
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

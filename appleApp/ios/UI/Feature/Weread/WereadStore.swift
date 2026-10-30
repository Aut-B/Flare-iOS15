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
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "weread.cookie"
    private let nameKey = "weread.nickname"

    private init() {
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !cookie.isEmpty
        nickname = defaults.string(forKey: nameKey) ?? ""
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

    func adopt(cookies: [HTTPCookie]) {
        let header = Self.cookieHeader(from: cookies)
        guard header.contains("wr_vid=") else { return }
        defaults.set(header, forKey: cookieKey)
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
        }
    }

    func logout() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nameKey)
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.nickname = ""
            self.books = []
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
            self.errorMessage = WereadError.notLoggedIn.errorDescription
        }
    }

    // MARK: - 书架

    func refreshShelf() async {
        guard !cookie.isEmpty else { return }
        DispatchQueue.main.async { self.isLoading = true }
        defer { DispatchQueue.main.async { self.isLoading = false } }
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

import Foundation
import Combine
import WebKit
import os

/// 点赞按钮要显示的状态：原始 `IGMedia` 字段 + Store 里的乐观覆盖。
struct IGLikeState: Equatable {
    var liked: Bool
    var count: Int
}

/// Instagram 的登录态与首页时间线。
///
/// 凭证就是网页版 cookie（关键是 `sessionid`），存 UserDefaults，
/// 掉线时接口返回 401，这里清掉登录态让界面回到「重新登录」。
final class InstagramStore: ObservableObject {
    static let shared = InstagramStore()
    private static let log = Logger(subsystem: "dev.dimension.flare.instagram", category: "like")

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var userName: String
    @Published private(set) var feed: [IGMedia] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    /// `IGMedia` 是不可变结构体，点赞后没法原地改。这里按帖子 id 存一份
    /// 当前显示值，时间线和详情都从这里读；乐观更新与失败回滚只动这一处。
    @Published private(set) var likeOverrides: [String: IGLikeState] = [:]
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
    /// 同一篇帖子只允许一个点赞请求在飞，避免连点 / 时间线与详情两个
    /// 按钮同时触发时请求乱序，最后把状态翻回去。
    private let likeLock = NSLock()
    private var likeInFlight: Set<String> = []

    private init() {
        let stored = defaults.string(forKey: cookieKey) ?? ""
        let cleaned = InstagramService.sanitizeHeader(stored)
        // 自愈：老版本可能把带换行 / 中文的脏 cookie 存进过 UserDefaults。
        // 这种串一旦进了 HTTP 头，setValue 会抛 ObjC 异常（SIGABRT），
        // 而且覆盖安装不会清 UserDefaults —— 表现就是「登录一次以后再也打不开」。
        if !stored.isEmpty,
            cleaned != stored || CookieJar.value(inHeader: cleaned, named: "sessionid") == nil
        {
            defaults.removeObject(forKey: cookieKey)
            defaults.removeObject(forKey: userKey)
        }
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !cookie.isEmpty
        userName = defaults.string(forKey: userKey) ?? ""
        pushCredentials()
    }

    /// 启动连续失败时的最后手段：把可能带崩启动路径的凭证丢掉。
    /// 用户顶多重登一次，总比 App 完全打不开强。
    static func purgeStoredCookie() {
        InstagramStateIsolator.requestQuarantineOnNextLaunch()
        UserDefaults.standard.removeObject(forKey: "instagram.cookie")
        UserDefaults.standard.removeObject(forKey: "instagram.username")
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
    }

    // MARK: - 登录态

    func adopt(cookies: [HTTPCookie]) {
        guard !InstagramStateIsolator.suppressAdoptionThisLaunch else { return }
        let header = CookieJar.header(cookies, domainSuffix: "instagram.com")
        guard adopt(cookieHeader: header) else { return }
        // 顺手把 cookie 灌进 URLSession 共享仓库，网页兜底页也能直接用。
        CookieJar.syncToSharedStorage(cookies)
    }

    /// 直接吃一段原始 cookie 串（Kotlin 登录成功后通过 `InstagramBridge` 同步过来）。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        guard !InstagramStateIsolator.suppressAdoptionThisLaunch else { return false }
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
            self.likeOverrides = [:]
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
            self.likeOverrides = [:]
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

    // MARK: - 点赞

    /// 按钮显示用的状态：没有本地覆盖时就用接口返回的 `has_liked` / `like_count`。
    func likeState(for media: IGMedia) -> IGLikeState {
        let mediaId = Self.requestMediaId(media.id)
        return likeOverrides[mediaId] ?? IGLikeState(liked: media.hasLiked, count: media.likeCount)
    }

    func likePost(_ media: IGMedia) async throws {
        try await setLiked(media, liked: true)
    }

    func unlikePost(_ media: IGMedia) async throws {
        try await setLiked(media, liked: false)
    }

    private func setLiked(_ media: IGMedia, liked: Bool) async throws {
        let mediaId = Self.requestMediaId(media.id)
        guard beginLike(mediaId) else { return }
        defer { endLike(mediaId) }

        // 网页版的写接口只认 cookie 里的 `csrftoken`；每次写之前重新灌一遍，
        // 避免 Store 刚换过 cookie、Service 还拿着旧 token。
        pushCredentials()
        let previous = likeState(for: media)
        guard previous.liked != liked else { return }
        let next = IGLikeState(
            liked: liked,
            count: max(0, previous.count + (liked ? 1 : -1))
        )

        // 乐观更新：先翻 UI，请求失败再翻回来。
        DispatchQueue.main.async {
            self.likeOverrides[mediaId] = next
        }

        do {
            if liked {
                try await InstagramService.shared.like(mediaId: mediaId)
            } else {
                try await InstagramService.shared.unlike(mediaId: mediaId)
            }
        } catch {
            let action = liked ? "like" : "unlike"
            Self.log.error(
                "\(action, privacy: .public) failed media=\(mediaId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async {
                self.likeOverrides[mediaId] = previous
            }
            throw error
        }
    }

    /// 时间线返回的 `id` 常是 `<pk>_<user pk>`，但点赞路径和表单只认数字 `pk`。
    /// 同时用它做覆盖键，确保时间线与详情页指向同一篇帖子。
    private static func requestMediaId(_ id: String) -> String {
        guard let separator = id.firstIndex(of: "_") else { return id }
        let prefix = id[..<separator]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return id }
        return String(prefix)
    }

    private func beginLike(_ mediaId: String) -> Bool {
        likeLock.lock()
        defer { likeLock.unlock() }
        return likeInFlight.insert(mediaId).inserted
    }

    private func endLike(_ mediaId: String) {
        likeLock.lock()
        likeInFlight.remove(mediaId)
        likeLock.unlock()
    }

    // MARK: - 时间线

    func refreshIfNeeded() async {
        guard isLoggedIn, !loaded else { return }
        // 安全模式（上次启动没走完看门狗）下不要一进 App 就自动拉时间线：
        // 少一个开机就发请求、开机就解一大坨 JSON 的崩溃机会。
        // 用户手动点刷新不受影响。
        guard !LaunchGuard.safeMode else { return }
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
                // 刷新拿到的是服务端权威状态，清掉上一轮的本地覆盖。
                self.likeOverrides = [:]
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

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
/// 掉线时接口返回 401 只提示重试，不删 cookie：一次瞬时 401 不代表会话失效，
/// 删掉反而会让下次冷启动也恢复不回来。只有主动退出 / 隔离才清。
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
    /// 用户主动退出 / 强制隔离后置 true。只有它为空时才允许
    /// 从系统 cookie 仓库把旧会话捡回来，否则退出登录会被冷启动撤销。
    private let loggedOutKey = IGSession.loggedOutKey
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
    /// 每次登录态真正变化都 +1。WK 异步快照回来时代次变了就丢弃，
    /// 否则可能用旧 cookie 覆盖用户刚完成的新登录。
    /// Bridge 可能从任意线程调 `adopt`，所以计数要加锁。
    private let sessionGenerationLock = NSLock()
    private var sessionGeneration = 0

    private init() {
        let loggedOut = defaults.bool(forKey: loggedOutKey)
        let stored = defaults.string(forKey: cookieKey) ?? ""
        // 老版本可能用换行分隔 cookie；先还原分隔符，避免清洗时把值粘坏。
        let cleaned = IGSession.normalizeCookieHeader(stored)
        let hasSession = IGSession.hasUsableSession(cleaned)
        // 自愈：老版本可能把带换行 / 中文的脏 cookie 存进过 UserDefaults。
        // 这种串一旦进了 HTTP 头，setValue 会抛 ObjC 异常（SIGABRT）。
        // 但清洗后只要 `sessionid` 还在，就必须把洗干净的串写回去，而不是
        // 把整段登录态删掉 —— 以前这里一删，覆盖安装后每次冷启动都要重登。
        if !loggedOut, !stored.isEmpty, hasSession {
            if cleaned != stored {
                defaults.set(cleaned, forKey: cookieKey)
            }
        } else if !loggedOut,
            let recovered = Self.recoverCookieFromSharedStorage()
        {
            // UserDefaults 被旧版本的隔离逻辑清过，但系统 cookie 仓库里
            // 还留着登录态（IG 网页版仍显示已登录）。这里捡回来，
            // 冷启动就不用再扫码。
            defaults.set(recovered, forKey: cookieKey)
            defaults.removeObject(forKey: userKey)
        } else {
            defaults.removeObject(forKey: cookieKey)
            defaults.removeObject(forKey: userKey)
        }
        let cookie = defaults.string(forKey: cookieKey) ?? ""
        isLoggedIn = !loggedOut && IGSession.hasUsableSession(cookie)
        userName = defaults.string(forKey: userKey) ?? ""
        pushCredentials()
        if !isLoggedIn {
            recoverFromWebKitIfNeeded()
        }
    }

    /// 启动连续失败时的最后手段：把可能带崩启动路径的凭证丢掉。
    /// 用户顶多重登一次，总比 App 完全打不开强。
    static func purgeStoredCookie() {
        InstagramStateIsolator.requestQuarantineOnNextLaunch()
        UserDefaults.standard.removeObject(forKey: "instagram.cookie")
        UserDefaults.standard.removeObject(forKey: "instagram.username")
        UserDefaults.standard.set(true, forKey: IGSession.loggedOutKey)
    }

    var cookie: String {
        defaults.string(forKey: cookieKey) ?? ""
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

    func adopt(cookies: [HTTPCookie]) {
        guard !InstagramStateIsolator.suppressAdoptionThisLaunch else { return }
        let header = IGSession.header(from: cookies, domainSuffix: "instagram.com")
        guard adopt(cookieHeader: header) else { return }
        // 顺手把 cookie 灌进 URLSession 共享仓库，网页兜底页也能直接用。
        CookieJar.syncToSharedStorage(cookies)
    }

    /// 直接吃一段原始 cookie 串（Kotlin 登录成功后通过 `InstagramBridge` 同步过来）。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        guard !InstagramStateIsolator.suppressAdoptionThisLaunch else { return false }
        let normalized = IGSession.normalizeCookieHeader(raw)
        // 只留可见 ASCII：cookie 里混进换行 / 中文时，`URLRequest.setValue`
        // 会抛 ObjC 异常直接闪退（Kotlin 也接不住）。
        let header = IGSession.sanitizeHeader(normalized)
        guard IGSession.hasUsableSession(header) else { return false }
        // Kotlin 每次取数都会把同一份 cookie 同步过来。内容没变就直接返回，
        // 否则会把用户名清空、反复请求 currentUser，时间线看起来一直在闪。
        if isLoggedIn, cookie == header { return true }
        bumpSessionGeneration()
        defaults.set(header, forKey: cookieKey)
        // 有新的有效会话，撤销「已主动退出」标记。
        defaults.set(false, forKey: loggedOutKey)
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
        // 主动退出不能被下一次冷启动的「系统 cookie 恢复」撤销。
        bumpSessionGeneration()
        defaults.set(true, forKey: loggedOutKey)
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
        service.csrfToken = IGSession.value(inHeader: header, named: "csrftoken") ?? ""
        service.userId = IGSession.value(inHeader: header, named: "ds_user_id") ?? ""
    }

    /// 从 URLSession 共享仓库里拼回 Instagram 的 cookie。
    ///
    /// 旧版本把 UserDefaults 里的 `instagram.cookie` 删掉后，网页版
    /// （WKWebView）里的会话仍在。这里只做同步读取，不创建任何 WebView。
    private static func recoverCookieFromSharedStorage() -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return nil }
        let targets = cookies.filter { $0.domain.lowercased().contains("instagram.com") }
        let header = IGSession.header(from: targets, domainSuffix: "instagram.com")
        guard IGSession.hasUsableSession(header) else { return nil }
        return header
    }

    /// UserDefaults 和共享仓库都没有时，再给 WK 网页仓库一次机会。
    /// 只读 cookie，不创建 WebView；`adopt` 自己会检查隔离/退出标记。
    private func recoverFromWebKitIfNeeded() {
        guard !defaults.bool(forKey: loggedOutKey) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLoggedIn else { return }
            guard !self.defaults.bool(forKey: self.loggedOutKey),
                !InstagramStateIsolator.suppressAdoptionThisLaunch
            else { return }
            // 等主队列的这一拍里 Bridge 可能已经同步了 cookie；别再用
            // 启动时的旧结论去 WK 里捞，更不能用旧快照覆盖新会话。
            if self.hasStoredSession {
                self.useStoredSession()
                return
            }
            let generation = self.sessionGenerationToken()
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                DispatchQueue.main.async {
                    guard !self.defaults.bool(forKey: self.loggedOutKey) else { return }
                    guard !InstagramStateIsolator.suppressAdoptionThisLaunch else { return }
                    // 回调期间用户可能已经登录 / Bridge 已经 adopt / 主动退出。
                    // 旧快照只在登录态没有变化时才允许落盘。
                    guard generation == self.sessionGenerationToken() else { return }
                    if self.hasStoredSession {
                        self.useStoredSession()
                        return
                    }
                    self.adopt(cookies: cookies)
                    self.refreshAfterRecovery()
                }
            }
        }
    }

    private var hasStoredSession: Bool {
        IGSession.hasUsableSession(cookie)
    }

    /// 会话可能由隔离器的 WK 校验先一步写进 UserDefaults。Store 已经
    /// 构造完时不会自动读到它，这里补一次内存状态，别让界面停在登录页。
    private func useStoredSession() {
        guard hasStoredSession, !defaults.bool(forKey: loggedOutKey) else { return }
        bumpSessionGeneration()
        defaults.set(false, forKey: loggedOutKey)
        pushCredentials()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isLoggedIn {
                self.isLoggedIn = true
                self.errorMessage = nil
                self.loaded = false
                self.refreshUserName()
            }
            self.refreshAfterRecovery()
        }
    }

    /// 恢复晚于首页的 `.task`；`isLoggedIn` 后来才翻成 true，`.task`
    /// 不会重跑，这里补一次首屏请求。
    private func refreshAfterRecovery() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLoggedIn else { return }
            Task { await self.refreshIfNeeded() }
        }
    }

    private func handle(_ error: Error) {
        if let error = error as? IGError, error.needLogin {
            // 一次瞬时 401 / login_required 不代表 cookie 真失效。以前这里
            // 直接 logout()，会把 cookie 和「已主动退出」标记一起改掉，
            // 之后冷启动再也不会从系统仓库恢复，只能重新扫码。
            // 保留登录态，只提示重试；真正退出由用户主动触发。
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
        let mediaId = InstagramService.mediaID(media.id)
        return likeOverrides[mediaId] ?? IGLikeState(liked: media.hasLiked, count: media.likeCount)
    }

    func likePost(_ media: IGMedia) async throws {
        try await setLiked(media, liked: true)
    }

    func unlikePost(_ media: IGMedia) async throws {
        try await setLiked(media, liked: false)
    }

    private func setLiked(_ media: IGMedia, liked: Bool) async throws {
        let mediaId = InstagramService.mediaID(media.id)
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
                // 首屏先并发预取前几张封面，不用等卡片全部布局完才逐个 onAppear。
                IGImageCache.shared.prefetch(result.items.prefix(4).compactMap(\.cover))
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
                let added = result.items.filter { !known.contains($0.id) }
                self.feed.append(contentsOf: added)
                self.nextCursor = result.next
                IGImageCache.shared.prefetch(added.prefix(4).compactMap(\.cover))
            }
        } catch {
            handle(error)
        }
    }
}

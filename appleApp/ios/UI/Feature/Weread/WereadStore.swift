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
    /// 这张表只存**真在网页里打开过**的地址：`readerLink(for:)` 拼出来的
    /// 地址不会写进来，避免一次拼错就永久错下去。
    @Published private(set) var readerLinks: [String: String] = [:]
    /// bookId → 阅读器地址。书名会重名、会带副标题，用 id 记最稳，
    /// 点书时先认这张表，认不到才去看书名。
    @Published private(set) var bookLinks: [String: String] = [:]
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let cookieKey = "weread.cookie"
    private let nameKey = "weread.nickname"
    private let loggedOutKey = "weread.loggedOut"
    private let linksKey = "weread.readerLinks"
    private let linksByIdKey = "weread.readerLinksById"
    private let linksEpochKey = "weread.readerLinksEpoch"
    /// 本机阅读进度：`weread.progress.<bookId>`。服务端上报失败/断网时靠它续读。
    private let progressPrefix = "weread.progress."
    /// 缓存校验逻辑变了就换这个值：老版本把「白屏地址」也写进过缓存，
    /// 升级后自动丢一次，省得用户每本书点进去都是白的。
    private static let linksEpoch = "build77"

    private var harvester: WebPageHarvester?
    private var harvesting = false
    private var harvested: [WereadBook] = []
    /// 一次启动里只跑一次线上书架同步。隐藏网页很吃 CPU，
    /// 反复建页面既费电，也容易在旧机型上把进程拖崩。
    private var syncedThisSession = false
    /// cookie 与会话 generation 必须一起变：generation 每次换会话都递增，
    /// 用来丢弃迟到的续期回调 / 旧请求的 rejected。
    private let sessionLock = NSLock()
    private var sessionGeneration = 0
    private var currentCookie = ""
    /// 鉴权恢复串行化：同一时刻只允许一个请求续期、试系统仓库候选、切 cookie。
    private let recoveryGate = WereadRecoveryGate()

    private init() {
        let loggedOut = defaults.bool(forKey: loggedOutKey)
        let storedCookie = defaults.string(forKey: cookieKey) ?? ""
        var restoredCookie = storedCookie
        // 旧版本清过本地 cookie，但网页登录态可能还在 URLSession 共享仓库里。
        // 这里同步捡一次，让界面首帧就能看到已登录；WK 仓库异步再补。
        if !loggedOut, !Self.looksLoggedIn(restoredCookie),
           let recovered = Self.cookieHeaderFromSharedStorage() {
            restoredCookie = recovered
            defaults.set(recovered, forKey: cookieKey)
        }
        currentCookie = restoredCookie
        isLoggedIn = !loggedOut && Self.looksLoggedIn(restoredCookie)
        nickname = defaults.string(forKey: nameKey) ?? ""
        readerLinks = defaults.dictionary(forKey: linksKey) as? [String: String] ?? [:]
        bookLinks = defaults.dictionary(forKey: linksByIdKey) as? [String: String] ?? [:]
        if defaults.string(forKey: linksEpochKey) != Self.linksEpoch {
            defaults.removeObject(forKey: linksKey)
            defaults.removeObject(forKey: linksByIdKey)
            defaults.set(Self.linksEpoch, forKey: linksEpochKey)
            readerLinks = [:]
            bookLinks = [:]
        }
        if !isLoggedIn {
            recoverFromWebKitIfNeeded()
        }
    }

    var cookie: String {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return currentCookie
    }

    private func sessionSnapshot() -> (cookie: String, generation: Int, loggedOut: Bool) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (
            currentCookie,
            sessionGeneration,
            defaults.bool(forKey: loggedOutKey)
        )
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
        // 同名 cookie 以最后一个为准；保留首次出现的位置，避免重复键
        // 让服务端读到过期值。
        var order: [String] = []
        var values: [String: String] = [:]
        for cookie in cookies where cookie.domain.contains("weread.qq.com") {
            let name = cookie.name
            guard !name.isEmpty, !cookie.value.isEmpty else { continue }
            if values[name] == nil { order.append(name) }
            values[name] = cookie.value
        }
        return order.compactMap { name in
            values[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }

    @discardableResult
    func adopt(cookies: [HTTPCookie]) -> Bool {
        adopt(cookieHeader: Self.cookieHeader(from: cookies))
    }

    /// 直接吃一段**原始 cookie 串**（用户从浏览器里复制出来的）。
    ///
    /// 6s 这类老机器上 WKWebView 打不开微信读书的扫码页，只能给一条
    /// 「别处登录好，把 cookie 贴进来」的通道。返回是否被接受。
    @discardableResult
    func adopt(cookieHeader raw: String) -> Bool {
        let header = Self.normalizeCookieHeader(raw)
        guard Self.looksLoggedIn(header) else { return false }
        sessionLock.lock()
        let wasLoggedOut = defaults.bool(forKey: loggedOutKey)
        if currentCookie != header || wasLoggedOut {
            sessionGeneration += 1
        }
        currentCookie = header
        defaults.set(header, forKey: cookieKey)
        defaults.set(false, forKey: loggedOutKey)
        sessionLock.unlock()
        DispatchQueue.main.async {
            self.isLoggedIn = true
            self.errorMessage = nil
        }
        return true
    }

    /// 从 DevTools / 扩展里复制、或从 WK 仓库拼出来的 cookie 经常带换行。
    private static func normalizeCookieHeader(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count))
        }
        return
            text
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "; "))
    }

    /// 微信读书书架接口两样都要：`wr_vid` 是账号，`wr_skey` 才是会话。
    /// 必须校验值非空，不能用 `contains("wr_skey=")` 把空值当登录。
    private static func looksLoggedIn(_ header: String) -> Bool {
        var hasUserId = false
        var hasSession = false
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if name == "wr_vid" { hasUserId = true }
            if name == "wr_skey" { hasSession = true }
        }
        return hasUserId && hasSession
    }

    /// 从 URLSession 共享仓库同步取一次 cookie，不创建任何 WebView。
    private static func cookieHeaderFromSharedStorage() -> String? {
        guard let cookies = HTTPCookieStorage.shared.cookies else { return nil }
        let header = cookieHeader(from: cookies)
        return looksLoggedIn(header) ? header : nil
    }

    /// 本地 cookie 为空或无效时才走这里；只读 WK 的 cookie 仓库，不建页面。
    private func recoverFromWebKitIfNeeded() {
        let snapshot = sessionSnapshot()
        guard !snapshot.loggedOut, !isLoggedIn else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = self.sessionSnapshot()
                guard snapshot.generation == now.generation,
                      !self.isLoggedIn,
                      !now.loggedOut
                else {
                    return
                }
                guard self.adopt(cookieHeader: Self.cookieHeader(from: cookies)),
                      self.books.isEmpty
                else {
                    return
                }
                // 视图的 `.task` 在 isLoggedIn 翻成 true 之前已经跑过了，
                // 这里补一次首屏请求，避免停在空白书架。
                Task { await self.refreshShelf() }
            }
        }
    }

    /// 收集 HTTPCookieStorage 与 WK 仓库里的全部有效会话（去重后），
    /// 不再只取第一个：HTTP 里可能还是过期会话，WK 里才是新会话。
    private static func systemCookieCandidates() async -> [String] {
        var raw: [String] = []
        if let cookies = HTTPCookieStorage.shared.cookies {
            raw.append(cookieHeader(from: cookies))
        }
        let webKitCookies = await readCookies(from: .default())
        raw.append(cookieHeader(from: webKitCookies))

        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let header = normalizeCookieHeader(item)
            guard looksLoggedIn(header) else { continue }
            let fingerprint = cookieFingerprint(header)
            guard seen.insert(fingerprint).inserted else { continue }
            result.append(header)
        }
        return result
    }

    /// 同名键排序后比较，避免两个仓库只是顺序不同就被当成两份会话。
    private static func cookieFingerprint(_ header: String) -> String {
        header
            .split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ";")
    }

    /// 提交续期结果：只有 generation 未变、当前 cookie 仍是续期源时才落盘。
    /// 写入不同 cookie 时递增 generation，让旧的 rejected 自动失效。
    private func commitRenewedCookie(
        _ renewed: String,
        source: String,
        generation: Int
    ) -> Bool {
        guard Self.looksLoggedIn(renewed) else { return false }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !defaults.bool(forKey: loggedOutKey),
              generation == sessionGeneration,
              currentCookie == source,
              renewed != currentCookie
        else {
            return false
        }
        sessionGeneration += 1
        currentCookie = renewed
        defaults.set(renewed, forKey: cookieKey)
        return true
    }

    /// 系统仓库候选只有在本地会话仍是那个失败会话时才采用，避免覆盖
    /// 用户刚完成的新登录或别处已提交的续期。
    private func adoptRecoveredCandidate(
        _ header: String,
        expectedCookie: String,
        expectedGeneration: Int
    ) -> Bool {
        guard Self.looksLoggedIn(header) else { return false }
        sessionLock.lock()
        guard !defaults.bool(forKey: loggedOutKey),
              sessionGeneration == expectedGeneration,
              currentCookie == expectedCookie
        else {
            sessionLock.unlock()
            return false
        }
        let changed = currentCookie != header
        if changed {
            sessionGeneration += 1
            currentCookie = header
            defaults.set(header, forKey: cookieKey)
        }
        defaults.set(false, forKey: loggedOutKey)
        sessionLock.unlock()
        if changed {
            DispatchQueue.main.async {
                self.isLoggedIn = true
                self.errorMessage = nil
            }
        }
        return true
    }

    /// 业务请求的统一鉴权恢复入口：本地失败 → 串行续期 → 系统仓库候选；
    /// 成功才 adopt，明确拒绝才注销，临时失败保留 cookie。
    private func withSessionRecovery<T>(
        _ operation: @escaping (String) async throws -> T
    ) async throws -> T {
        let snapshot = sessionSnapshot()
        if !snapshot.loggedOut, Self.looksLoggedIn(snapshot.cookie) {
            do {
                return try await operation(snapshot.cookie)
            } catch let failure as WereadAuthFailure {
                guard case .rejected = failure else { throw failure }
                return try await withRecoveryGate {
                    try await self.recoverAfterRejection(
                        operation,
                        failedCookie: snapshot.cookie,
                        failedGeneration: snapshot.generation
                    )
                }
            }
        }
        guard !snapshot.loggedOut else { throw WereadError.notLoggedIn }
        return try await withRecoveryGate {
            try await self.recoverWithoutLocalCookie(operation, initial: snapshot)
        }
    }

    /// 串行化整个恢复过程，避免同一 cookie 并发续期后拿旧 rejected 清掉新会话。
    private func withRecoveryGate<T>(_ body: () async throws -> T) async throws -> T {
        await recoveryGate.acquire()
        do {
            let value = try await body()
            await recoveryGate.release()
            return value
        } catch {
            await recoveryGate.release()
            throw error
        }
    }

    private func recoverAfterRejection<T>(
        _ operation: @escaping (String) async throws -> T,
        failedCookie initialCookie: String,
        failedGeneration initialGeneration: Int
    ) async throws -> T {
        var failedCookie = initialCookie
        var failedGeneration = initialGeneration
        var renewed = false
        var sawTransient = false
        var tried = Set<String>([initialCookie])

        for _ in 0..<3 {
            let snapshot = sessionSnapshot()
            if snapshot.loggedOut { throw WereadError.notLoggedIn }

            // 恢复期间别处已经换了新会话：先用当前会话重试，不再续期旧 cookie。
            if Self.looksLoggedIn(snapshot.cookie), snapshot.cookie != failedCookie {
                failedCookie = snapshot.cookie
                failedGeneration = snapshot.generation
                renewed = false
                tried.insert(failedCookie)
                do {
                    return try await operation(failedCookie)
                } catch let failure as WereadAuthFailure {
                    if case .transient = failure { throw failure }
                    guard case .rejected(let failed) = failure else { throw failure }
                    failedCookie = failed
                    failedGeneration = sessionSnapshot().generation
                    continue
                }
            }

            guard Self.looksLoggedIn(snapshot.cookie),
                  snapshot.cookie == failedCookie,
                  snapshot.generation == failedGeneration
            else {
                break
            }
            guard !renewed else { break }
            renewed = true

            switch await WereadService.shared.renew(cookie: failedCookie) {
            case .renewed(let newCookie) where newCookie != failedCookie:
                if commitRenewedCookie(
                    newCookie,
                    source: failedCookie,
                    generation: failedGeneration
                ) {
                    failedCookie = newCookie
                    failedGeneration = sessionSnapshot().generation
                    // 新 cookie 是新的源会话：若它仍被拒绝，允许它自己再续期一次，
                    // 但绝不把旧 cookie 的 rejected 结果套到它身上。
                    renewed = false
                } else {
                    let now = sessionSnapshot()
                    if now.loggedOut { throw WereadError.notLoggedIn }
                    guard Self.looksLoggedIn(now.cookie) else {
                        // 续期结果因退出/重新登录被丢弃；不要注销新状态。
                        throw WereadAuthFailure.transient
                    }
                    if now.cookie == failedCookie {
                        // generation 变了但 cookie 没变（例如重登同一串），旧续期不能覆盖。
                        throw WereadAuthFailure.transient
                    }
                    failedCookie = now.cookie
                    failedGeneration = now.generation
                    // 换成了别处提交的新会话：这是一份没试过续期的 cookie，
                    // 下一轮若仍被拒绝要允许它自己走一次 renewal。
                    renewed = false
                }
                tried.insert(failedCookie)
                do {
                    return try await operation(failedCookie)
                } catch let failure as WereadAuthFailure {
                    if case .transient = failure { throw failure }
                    guard case .rejected(let failed) = failure else { throw failure }
                    failedCookie = failed
                    failedGeneration = sessionSnapshot().generation
                    continue
                }
            case .rejected:
                break
            case .unchanged, .transient:
                // 服务端没给新会话或只是网络失败：保留 cookie，再试一次。
                // `.unchanged` 说明续期本身成功，后面即便数据请求再被拒绝，
                // 也不能当作「同源续期失败」去注销，只能报告暂时无法确认。
                sawTransient = true
                do {
                    return try await operation(failedCookie)
                } catch let failure as WereadAuthFailure {
                    if case .transient = failure { throw failure }
                    guard case .rejected(let failed) = failure else { throw failure }
                    failedCookie = failed
                    failedGeneration = sessionSnapshot().generation
                }
                break
            case .renewed:
                break
            }
        }

        // 所有系统仓库候选逐份试；某份被拒绝或临时失败都继续下一份。
        let candidates = await Self.systemCookieCandidates()
        var lastTransientError: Error?
        for candidate in candidates {
            let snapshot = sessionSnapshot()
            if snapshot.loggedOut { throw WereadError.notLoggedIn }
            guard tried.insert(candidate).inserted else { continue }
            do {
                let value = try await operation(candidate)
                _ = adoptRecoveredCandidate(
                    candidate,
                    expectedCookie: failedCookie,
                    expectedGeneration: failedGeneration
                )
                return value
            } catch let failure as WereadAuthFailure {
                switch failure {
                case .rejected:
                    continue
                case .transient:
                    sawTransient = true
                    continue
                }
            } catch {
                // 传输 / 解析等临时失败不是服务端拒绝：保留本地 cookie，
                // 继续试下一份候选，别让第一份候选的网络错误挡住后面的有效会话。
                sawTransient = true
                lastTransientError = error
                continue
            }
        }

        if sawTransient {
            let message = WereadAuthFailure.transient.errorDescription
            DispatchQueue.main.async { self.errorMessage = message }
            if let lastTransientError { throw lastTransientError }
            throw WereadAuthFailure.transient
        }
        if handleAuthFailure(expectedCookie: failedCookie, generation: failedGeneration) {
            throw WereadError.notLoggedIn
        }
        // 状态在恢复期间被别处改过（新登录/主动退出）：没有注销任何会话，
        // 不能对用户谎称登录已过期。
        throw WereadAuthFailure.transient
    }

    /// 本地没有有效 cookie 时，也只从系统仓库候选里逐个尝试。
    private func recoverWithoutLocalCookie<T>(
        _ operation: @escaping (String) async throws -> T,
        initial: (cookie: String, generation: Int, loggedOut: Bool)
    ) async throws -> T {
        var sawTransient = false
        var lastTransientError: Error?
        let candidates = await Self.systemCookieCandidates()
        for candidate in candidates {
            let snapshot = sessionSnapshot()
            if snapshot.loggedOut { throw WereadError.notLoggedIn }
            do {
                let value = try await operation(candidate)
                _ = adoptRecoveredCandidate(
                    candidate,
                    expectedCookie: initial.cookie,
                    expectedGeneration: initial.generation
                )
                return value
            } catch let failure as WereadAuthFailure {
                switch failure {
                case .rejected:
                    continue
                case .transient:
                    sawTransient = true
                    continue
                }
            } catch {
                sawTransient = true
                lastTransientError = error
                continue
            }
        }
        if sawTransient {
            let message = WereadAuthFailure.transient.errorDescription
            DispatchQueue.main.async { self.errorMessage = message }
            if let lastTransientError { throw lastTransientError }
            throw WereadAuthFailure.transient
        }
        throw WereadError.notLoggedIn
    }

    func logout() {
        sessionLock.lock()
        sessionGeneration += 1
        currentCookie = ""
        defaults.set(true, forKey: loggedOutKey)
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nameKey)
        sessionLock.unlock()
        harvester?.stop()
        harvester = nil
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.nickname = ""
            self.books = []
            self.readerLinks = [:]
            self.bookLinks = [:]
        }
    }

    /// 只有服务端明确拒绝时才调用：清掉本地 cookie，让界面回到「重新登录」。
    /// 必须带上失败时的源 cookie 与 generation；状态已变则说明有更新的
    /// 会话或用户主动退出，不能拿旧请求的结果去清登录态。
    @discardableResult
    private func handleAuthFailure(expectedCookie: String, generation: Int) -> Bool {
        sessionLock.lock()
        guard sessionGeneration == generation,
              currentCookie == expectedCookie,
              !defaults.bool(forKey: loggedOutKey)
        else {
            sessionLock.unlock()
            return false
        }
        sessionGeneration += 1
        currentCookie = ""
        defaults.set(true, forKey: loggedOutKey)
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: nameKey)
        sessionLock.unlock()
        DispatchQueue.main.async {
            self.isLoggedIn = false
            self.nickname = ""
            self.books = []
            self.readerLinks = [:]
            self.bookLinks = [:]
            self.errorMessage = WereadError.notLoggedIn.errorDescription
        }
        return true
    }

    // MARK: - 书架

    func refreshShelf() async {
        if cookie.isEmpty {
            // 旧版本清过本地 cookie，但共享仓库里可能还有登录态。
            guard !defaults.bool(forKey: loggedOutKey),
                  let recovered = Self.cookieHeaderFromSharedStorage()
            else { return }
            adopt(cookieHeader: recovered)
        }
        DispatchQueue.main.async { self.isLoading = true }
        do {
            let list = try await withSessionRecovery { attemptCookie in
                try await WereadService.shared.shelf(cookie: attemptCookie)
            }
            DispatchQueue.main.async {
                self.books = list
                self.errorMessage = nil
            }
        } catch let failure as WereadAuthFailure {
            let message = failure.errorDescription
            DispatchQueue.main.async { self.errorMessage = message }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { self.errorMessage = message }
        }
        DispatchQueue.main.async { self.isLoading = false }
        // 原生阅读器只要数字 bookId，不再为了 reader hash 在后台跑隐藏网页。
        // 线上书架的补全/链接抄取保留为「重新同步线上书架」的手动操作，
        // 避免每次刷新书架都建一个 WebView 把 6s 拖慢。
    }

    // MARK: - 网页书架（拿阅读器地址 + 补齐书单）

    /// 打开一个隐藏的真网页跑一遍线上书架：既补齐 `shelf/sync` 漏掉的书，
    /// 也把每本书在网页阅读器里的真实地址（`/web/reader/<hash>`）抄下来。
    func syncWebShelf(scrolls: Int = 5) {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard self.isLoggedIn, !LaunchGuard.webViewsBlocked, !self.harvesting else { return }
            self.syncedThisSession = true
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        self?.extractReaderLinks()
                    }
                },
                onFail: { [weak self, weak harvester] _ in
                    // 页面打不开就别继续养着 1280×1600 的 WebContent，
                    // 立刻收尾（仍会先抄一遍 DOM，拿不到就返回空）。
                    guard let self = self, let harvester = harvester else { return }
                    self.finishHarvest(from: harvester)
                },
                onMessage: { [weak self] message in
                    self?.ingestShelf(message)
                }
            )
            // 页面书架也是滚动加载，往下拉几次把书捞全。
            let steps = max(scrolls, 1)
            for index in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.8) { [weak self] in
                    // 身份校验：harvester 已被换掉/停掉时这些旧定时器必须变成空操作，
                    // 否则它们会去滚动新的页面，6S 上会叠出一堆无意义的渲染与唤醒。
                    guard let self = self, self.harvester === harvester else { return }
                    harvester.scroll()
                }
            }
            // 只抄一次 DOM 是不够的：网页书架是分批渲染的，后面几屏的书
            // 在第一次抄的时候还没进 DOM，那些书就永远拿不到 reader hash，
            // 点进去只能退回网页书架再点一次。这里每隔一段时间抄一遍。
            for delay in [2.6, 4.4, 6.2, 8.0, 9.8, 11.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.harvester === harvester else { return }
                    self.extractReaderLinks(from: harvester)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 1.8 + 4.2) { [weak self] in
                guard let self = self, self.harvester === harvester else { return }
                self.finishHarvest(from: harvester)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 书架页每次出现都会调，这里挡一道，只在本进程里跑一次。
    func syncWebShelfIfNeeded() {
        guard !syncedThisSession else { return }
        syncWebShelf()
    }

    /// 点书时调用：有缓存就秒开；没有就现场跑一遍网页书架，最多等 8 秒。
    ///
    /// 8 秒是上限不是常态：书架页在 6s 这种老机器上要两三秒才铺完，
    /// 等太久用户只会觉得「卡住了」。等不到就交给调用方直接进网页书架。
    func resolveReaderLink(for book: WereadBook, timeout: TimeInterval = 8) async -> String? {
        if let url = await linkOnMain(for: book) { return url }
        let alreadyHarvesting = await MainActor.run { self.harvesting }
        if !alreadyHarvesting {
            await MainActor.run { self.syncWebShelf(scrolls: 4) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let url = await linkOnMain(for: book) { return url }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        return await linkOnMain(for: book)
    }

    private func linkOnMain(for book: WereadBook) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: self.readerLink(for: book))
            }
        }
    }

    /// 网页阅读器地址。书名对不上时返回 nil，调用方退回「网页书架 + 自动点开」。
    ///
    /// 地址本来就能自己算：`/web/reader/{_e(bookId)}`，`_e()` 就是
    /// `WereadCrypto.calcHash`。以前这里判「拼出来大概率 404」并直接返回 nil，
    /// 是误判 —— 抄 DOM 只是为了拿到无章节后缀的那条链接，不影响可用性。
    /// 现在顺序是：抄到的真地址 → 自己拼（必要时带 `k{_e(chapterUid)}`）。
    func readerLink(for book: WereadBook) -> String? {
        if !book.id.isEmpty, let url = bookLinks[book.id], !url.isEmpty { return url }
        let key = Self.normalize(book.title)
        if let url = readerLinks[key], !url.isEmpty { return url }
        guard !book.id.isEmpty else { return nil }
        if book.id.hasPrefix("MP_WXS_") {
            return WereadService.shared.mpReaderURL(bookId: book.id)?.absoluteString
        }
        return WereadService.shared.readerURLString(bookId: book.id)
    }

    /// 阅读器里真正跳成功以后把地址记下来，下次点这本书就是秒开。
    ///
    /// 有些书的链接不在书架的 DOM 里（懒渲染、分组折叠），第一次只能靠
    /// 「网页书架 + 自动点开」，这条兜底让第二次不用再绕。
    func rememberReaderLink(bookId: String, title: String, url: String) {
        guard url.contains("/web/reader/") else { return }
        if !bookId.isEmpty, bookLinks[bookId] != url {
            var merged = bookLinks
            merged[bookId] = url
            bookLinks = merged
            defaults.set(merged, forKey: linksByIdKey)
        }
        guard !title.isEmpty else { return }
        let key = Self.normalize(title)
        guard readerLinks[key] != url else { return }
        var merged = readerLinks
        merged[key] = url
        readerLinks = merged
        defaults.set(merged, forKey: linksKey)
    }

    /// 清掉「书名 / bookId → 阅读器地址」两张缓存。
    ///
    /// 缓存里可能留着打不开的地址（上一版把白屏地址也写进去了），
    /// 清掉之后点书会重新走「网页书架 → 点开 → 记下真地址」。
    func clearReaderLinks() {
        bookLinks = [:]
        readerLinks = [:]
        defaults.removeObject(forKey: linksByIdKey)
        defaults.removeObject(forKey: linksKey)
        defaults.set(Self.linksEpoch, forKey: linksEpochKey)
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

    private func extractReaderLinks(from harvester: WebPageHarvester? = nil) {
        let target = harvester ?? self.harvester
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
            var bookId = '';
            for (var d = 0; d < 6 && node; d++) {
              if (!bookId && node.getAttribute) {
                bookId = node.getAttribute('data-book-id') || node.getAttribute('data-bookid') || '';
              }
              var attr = (node.getAttribute && node.getAttribute('title')) || '';
              if (!attr && node.querySelector) {
                var cand = node.querySelector('[class*="title"], [class*="name"]');
                if (cand) { attr = cand.textContent || ''; }
              }
              attr = String(attr || '').replace(/\\s+/g, ' ').trim();
              if (!title && attr.length > 0 && attr.length < 80) { title = attr; }
              node = node.parentElement;
            }
            if (!title && !bookId) { continue; }
            out.push({title: title, href: href, bookId: bookId});
          }
          return JSON.stringify(out);
        })()
        """
        target?.evaluate(script) { [weak self] text in
            guard let self = self else { return }
            guard
                let data = text.data(using: .utf8),
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else {
                return
            }
            var byTitle = self.readerLinks
            var byId = self.bookLinks
            for item in list {
                guard let href = item["href"] as? String, !href.isEmpty else { continue }
                let bookId = (item["bookId"] as? String) ?? ""
                let title = (item["title"] as? String) ?? ""
                if !bookId.isEmpty { byId[bookId] = href }
                if !title.isEmpty { byTitle[Self.normalize(title)] = href }
            }
            if byId.count != self.bookLinks.count {
                self.bookLinks = byId
                self.defaults.set(byId, forKey: self.linksByIdKey)
            }
            if byTitle.count != self.readerLinks.count {
                self.readerLinks = byTitle
                self.defaults.set(byTitle, forKey: self.linksKey)
            }
        }
    }

    private func finishHarvest(from harvester: WebPageHarvester) {
        // 停页面之前再抄最后一遍，把最后一屏滚出来的书也算上。
        extractReaderLinks(from: harvester)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.harvester === harvester else { return }
            self.harvesting = false
            harvester.stop()
            self.harvester = nil
            if !self.harvested.isEmpty {
                var merged = self.books
                let known = Set(merged.map { $0.id })
                merged.append(contentsOf: self.harvested.filter { !known.contains($0.id) })
                self.books = merged
            }
            self.harvested = []
        }
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
        try await withSessionRecovery { attemptCookie in
            try await WereadService.shared.chapters(bookId: bookId, cookie: attemptCookie)
        }
    }

    func content(bookId: String, chapterUid: Int) async throws -> String {
        try await withSessionRecovery { attemptCookie in
            try await WereadService.shared.content(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: attemptCookie
            )
        }
    }

    /// 云端划线/想法和目录走同一套会话恢复：`bookmarklist` 对过期 cookie
    /// 会静默返回 `{}`，必须由 Service 识别出来后在这里续期重试，否则
    /// 首页目录能打开、笔记却永远显示为空。
    func bookmarks(for bookId: String) async throws -> [WereadBookmark] {
        try await withSessionRecovery { attemptCookie in
            try await WereadService.shared.bookmarks(bookId: bookId, cookie: attemptCookie)
        }
    }

    /// 本机上次阅读位置 + 服务端进度，按时间择新。
    ///
    /// 服务端 `updateTime` 比本机记录新（例如用户又用官方 App 读过）就用
    /// 服务端，继续「继承其它 App 的进度」；本机记录更新或服务端没有时间戳
    /// 时优先保住本机位置 —— 上报失败/断网时不能每次重进都从头开始。
    func progress(for bookId: String) async -> WereadProgress? {
        let local = storedProgress(bookId: bookId)
        var remote: WereadService.ProgressSnapshot?
        do {
            // 走统一鉴权恢复：cookie 刚好过期时先续期，再读服务端进度；
            // 否则本次会拿 nil，用户仍会从第一章开始。
            remote = try await withSessionRecovery { attemptCookie in
                try await WereadService.shared.progressSnapshot(
                    bookId: bookId,
                    cookie: attemptCookie
                )
            }
        } catch {
            remote = nil
            WereadService.screenDiag(
                "进度服务端读取失败 book=\(bookId) \(error.localizedDescription)"
            )
        }

        let localText = local.map {
            "\($0.chapterUid)/\($0.chapterOffset)@\(Int($0.savedAt))"
        } ?? "nil"
        let remoteText = remote.map {
            "\($0.chapterUid)/\($0.chapterOffset)@\(Int($0.updatedAt))"
        } ?? "nil"
        WereadService.screenDiag(
            "进度 book=\(bookId) local=\(localText) remote=\(remoteText)"
        )

        switch (local, remote) {
        case let (local?, nil):
            return local.progress
        case let (nil, remote?):
            remember(remote, bookId: bookId)
            return remote.progress
        case let (local?, remote?):
            if remote.updatedAt > 0, remote.updatedAt > local.savedAt {
                remember(remote, bookId: bookId)
                return remote.progress
            }
            return local.progress
        case (nil, nil):
            return nil
        }
    }

    /// 只落本机，不上报：滚动过程中定期存一份，App 被杀掉也能续读。
    func cacheProgress(bookId: String, chapterUid: Int, offset: Int, percent: Int) {
        guard !bookId.isEmpty, chapterUid > 0 else { return }
        storeProgress(
            bookId: bookId,
            chapterUid: chapterUid,
            chapterOffset: max(offset, 0),
            percent: min(max(percent, 0), 100)
        )
    }

    func report(
        bookId: String,
        chapterUid: Int,
        offset: Int,
        chapterIndex: Int,
        percent: Int = 0
    ) {
        guard !bookId.isEmpty, chapterUid > 0 else { return }
        // 先落本机：断网、未登录或服务端不认上报时，重进仍能回到原位。
        cacheProgress(
            bookId: bookId,
            chapterUid: chapterUid,
            offset: offset,
            percent: percent
        )
        let cookie = cookie
        guard !cookie.isEmpty else { return }
        Task.detached(priority: .utility) {
            await WereadService.shared.reportProgress(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterOffset: offset,
                chapterIndex: chapterIndex,
                cookie: cookie
            )
        }
    }

    private func progressKey(_ bookId: String) -> String {
        progressPrefix + bookId
    }

    private func storedProgress(bookId: String) -> WereadStoredProgress? {
        guard !bookId.isEmpty, let data = defaults.data(forKey: progressKey(bookId)) else {
            return nil
        }
        return try? JSONDecoder().decode(WereadStoredProgress.self, from: data)
    }

    private func storeProgress(bookId: String, chapterUid: Int, chapterOffset: Int, percent: Int) {
        let value = WereadStoredProgress(
            chapterUid: chapterUid,
            chapterOffset: chapterOffset,
            percent: percent,
            savedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: progressKey(bookId))
    }

    /// 服务端进度在本地留一份：下次断网/未登录也能续读。
    private func remember(_ remote: WereadService.ProgressSnapshot, bookId: String) {
        guard remote.chapterUid > 0 else { return }
        let value = WereadStoredProgress(
            chapterUid: remote.chapterUid,
            chapterOffset: remote.chapterOffset,
            percent: remote.percent,
            savedAt: remote.updatedAt
        )
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: progressKey(bookId))
    }
}

/// 本机阅读进度缓存。`savedAt` 是本地保存时间（秒），用来和服务端
/// `updateTime` 比较，决定这次续读听谁的。
private struct WereadStoredProgress: Codable {
    let chapterUid: Int
    let chapterOffset: Int
    let percent: Int
    let savedAt: TimeInterval

    var progress: WereadProgress {
        WereadProgress(
            chapterUid: chapterUid,
            chapterOffset: chapterOffset,
            percent: percent
        )
    }
}

/// 简单的异步互斥：鉴权恢复（续期 + 试系统仓库候选 + 切 cookie）
/// 一次只跑一条，后来的请求排队，拿到已刷新会话后直接重试。
private actor WereadRecoveryGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

import Foundation
import os
import CryptoKit

/// 续期结果必须可区分：只有服务端明确拒绝才允许上层清掉登录态。
nonisolated enum WereadRenewalOutcome: Sendable, Equatable {
    /// 服务端给了新的 `Set-Cookie`，并且和旧串不同。
    case renewed(String)
    /// 服务端说续期成功，但没有下发新 cookie（或值没变）。
    case unchanged
    /// 服务端明确拒绝了这个会话（401/403、`succ=0`、`-2010/-2012`）。
    case rejected
    /// 网络/HTTP/解析等临时失败，不能据此注销用户。
    case transient
}

/// 需要和 `WereadError` 区分开的鉴权失败：`rejected` 可以清登录态，
/// `transient` 必须保留 cookie 让用户重试。
nonisolated enum WereadAuthFailure: Error, LocalizedError, Sendable, Equatable {
    /// 服务端明确拒绝了这个 cookie；注销前必须确认它仍是当前会话。
    case rejected(failedCookie: String)
    case transient

    var errorDescription: String? {
        switch self {
        case .rejected:
            return "微信读书登录已失效，请重新登录。"
        case .transient:
            return "登录状态暂时无法确认，已保留本地登录信息，请检查网络后重试。"
        }
    }
}

/// 服务端「我的想法」里的一条，只保留编辑需要的字段。
///
/// `reviewId` 是 `/web/review/edit` 的定位字段；`chapterUid` / `range` /
/// `abstract` 用来和本地划线、`bookmarklist` 条目对上。
nonisolated struct WereadOwnReview: Hashable, Identifiable, Sendable {
    let reviewId: String
    let chapterUid: Int
    let range: String
    let abstract: String
    let content: String

    var id: String { reviewId }
}

/// `/web/book/read` 的结果。只用来记诊断和判断「服务端到底认没认」，
/// 不据此清登录态 —— 时长上报失败不该把用户踢下线。
nonisolated enum WereadReadReportOutcome: Sendable, Equatable {
    /// 回包明确 `succ == 1`。
    case accepted
    /// HTTP 2xx 但回包没有 `succ` / `errCode`，无法确认是否计入。
    case uncertain(String)
    /// 服务端给了非 0 的 `errCode`。
    case rejected(String)
    /// 拿不到 readerToken，按要求不发假 rt。
    case missingToken
    /// 网络/解析失败。
    case failed(String)
}

/// 微信读书 Web 接口封装。
///
/// 全部走 `weread.qq.com` 的网页接口，登录态就是浏览器那套 cookie
/// （`wr_vid` / `wr_skey` / `wr_rt`）。正文接口带签名，响应还要解密，
/// 算法在 `WereadCrypto` 里。
final class WereadService: @unchecked Sendable {
    static let shared = WereadService()

    private let base = "https://weread.qq.com"
    private let session: URLSession
    private let log = Logger(subsystem: "dev.dimension.flare.weread", category: "service")

    /// 阅读器页面的会话信标缓存。
    ///
    /// 抓一次页面几百 KB，每章都抓太浪费，也更容易触发风控。
    /// 按「书 + 章」缓存，条目里带抓取时间，超过 `sessionTTL` 就当过期重抓。
    /// 用锁保护：`content()` 在并发 prefetch 里会被同时调用。
    private let sessionLock = NSLock()
    private var sessionCache: [String: (value: WereadReaderSession, stamp: Date)] = [:]
    /// `shelf/sync` 解析时见过的 PDF 书。原生阅读器只认 epub/txt 的章节分片，
    /// PDF 要在读正文前分流到网页版，不能等 chapter 接口返回空 HTML 再补救。
    private let pdfLock = NSLock()
    private var pdfBookIDs = Set<String>()
    /// 官方格式信息。`otherType` / `showType` 决定当前到底是 PDF 还是
    /// 电子书，不能只看 `type == 11`，否则双格式书会被误判。
    private var bookFormatCache: [String: WereadBookFormatInfo] = [:]
    /// 新增划线必填 `bookVersion`，按书缓存，避免每划一次都多拉一次详情。
    /// 取不到时不缓存，下次划线会重试。
    private let bookVersionLock = NSLock()
    private var bookVersionCache: [String: BookVersions] = [:]

    /// `/web/getConfig` 下发的 reader token，`sg` 签名要用。
    /// 按 cookie 摘要缓存，过期或服务端回 -806 时重取。
    private let readTokenLock = NSLock()
    private var readTokenCache: [String: (token: String, stamp: Date)] = [:]
    private static let readTokenTTL: TimeInterval = 600

    /// 阅读上报要用本章阅读器页面的 `ps`/`pc`，但正文可能走的是不需要信标的
    /// 旧版直连。抓页面有成本，同一章 2 分钟内最多为上报补抓一次；
    /// 抓到的会话另存 10 分钟，避免正文缓存过期后上报退回占位 `ps`/`pc`。
    private let readSessionAttemptLock = NSLock()
    private var readSessionAttempts: [String: Date] = [:]
    private static let readSessionAttemptTTL: TimeInterval = 120

    /// 只给时长上报复用的阅读器会话。官方阅读器在一个章节里始终用页面加载时
    /// 那组 `psvts`/`pclts` 上报，所以这里不跟着正文缓存 2 分钟一起过期。
    private let readReportSessionLock = NSLock()
    private var readReportSessions: [String: (value: WereadReaderSession, stamp: Date)] = [:]
    private static let readReportSessionTTL: TimeInterval = 600

    /// NSLock.lock()/unlock() 不允许在 async 上下文调用（Swift 6 严格并发），
    /// 所以把缓存读写包在同步方法里，async 侧只调这两个方法。
    private func cachedBookVersion(for bookId: String) -> BookVersions? {
        bookVersionLock.lock()
        defer { bookVersionLock.unlock() }
        return bookVersionCache[bookId]
    }

    private func storeBookVersion(_ versions: BookVersions, for bookId: String) {
        bookVersionLock.lock()
        defer { bookVersionLock.unlock() }
        bookVersionCache[bookId] = versions
    }

    /// NSLock 不能直接在 async 上下文里 lock，读写都包成同步方法。
    private func cachedReaderToken(for key: String) -> String? {
        readTokenLock.lock()
        defer { readTokenLock.unlock() }
        guard let entry = readTokenCache[key] else { return nil }
        if Date().timeIntervalSince(entry.stamp) > Self.readTokenTTL {
            readTokenCache[key] = nil
            return nil
        }
        return entry.token.isEmpty ? nil : entry.token
    }

    private func storeReaderToken(_ token: String, for key: String) {
        guard !token.isEmpty else { return }
        readTokenLock.lock()
        defer { readTokenLock.unlock() }
        let now = Date()
        readTokenCache = readTokenCache.filter { now.timeIntervalSince($0.value.stamp) <= Self.readTokenTTL }
        readTokenCache[key] = (token, now)
    }

    private func invalidateReaderToken(for key: String) {
        readTokenLock.lock()
        readTokenCache[key] = nil
        readTokenLock.unlock()
    }

    /// 同一章 2 分钟内只补抓一次阅读器页面；抓不到就退回占位 `ps`/`pc`。
    private func beginReadSessionAttempt(for key: String) -> Bool {
        readSessionAttemptLock.lock()
        defer { readSessionAttemptLock.unlock() }
        let now = Date()
        if let last = readSessionAttempts[key],
           now.timeIntervalSince(last) < Self.readSessionAttemptTTL
        {
            return false
        }
        if readSessionAttempts.count > 20 {
            readSessionAttempts = readSessionAttempts.filter {
                now.timeIntervalSince($0.value) <= Self.readSessionAttemptTTL
            }
        }
        readSessionAttempts[key] = now
        return true
    }

    private func cachedReadReportSession(
        for key: String
    ) -> (session: WereadReaderSession, stamp: Date)? {
        readReportSessionLock.lock()
        defer { readReportSessionLock.unlock() }
        guard let entry = readReportSessions[key] else { return nil }
        if Date().timeIntervalSince(entry.stamp) > Self.readReportSessionTTL {
            readReportSessions[key] = nil
            return nil
        }
        return (entry.value, entry.stamp)
    }

    @discardableResult
    private func storeReadReportSession(
        _ value: WereadReaderSession,
        for key: String
    ) -> Date {
        readReportSessionLock.lock()
        defer { readReportSessionLock.unlock() }
        let now = Date()
        readReportSessions = readReportSessions.filter {
            now.timeIntervalSince($0.value.stamp) <= Self.readReportSessionTTL
        }
        readReportSessions[key] = (value, now)
        return now
    }

    /// 信标有效期。`psvts` 会随时间失效，太短会反复抓页面，太长会拿到过期的。
    private static let sessionTTL: TimeInterval = 120
    /// 同一源 cookie 的并发续期只打一次服务端，其余调用等这一次结果。
    private let renewalCoordinator = WereadRenewalCoordinator()

    /// 抓取阅读器页面时用的 UA。
    ///
    /// 必须是桌面 UA：手机 UA 下 weread 会把 `/web/reader/...` 换成「打开 App」引导页，
    /// 里面根本没有 `__INITIAL_STATE__`。`WereadReaderView` 那边也是这么做的。
    private static let readerUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-Hans-CN;q=1",
            "Referer": "https://weread.qq.com/",
            "Origin": "https://weread.qq.com",
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - 阅读器会话信标

    /// 抓「这一章」的阅读器会话信标。
    ///
    /// 流程：GET `/web/reader/{_e(bookId)}k{_e(chapterUid)}` → 从 HTML 里抠
    /// `window.__INITIAL_STATE__.reader` 的 `psvts` / `pclts` / `token`。
    ///
    /// **失败一律返回 nil，不抛错**：拿不到信标不该阻断阅读，调用方会退回
    /// Step 1 的老行为（写死 ps/pc、不加 sc）继续试。
    func readerSession(bookId: String, chapterUid: Int, cookie: String) async -> WereadReaderSession? {
        let cacheKey = "\(bookId)#\(chapterUid)"
        if let cached = cachedSession(for: cacheKey) { return cached }

        guard let url = readerURL(bookId: bookId, chapterUid: chapterUid) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")

        do {
            let (data, response) = try await self.session.data(for: request)
            var readerStatus = -1
            if let http = response as? HTTPURLResponse { readerStatus = http.statusCode }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.notice("weread diag: reader page HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else {
                log.notice("weread diag: reader page not utf8")
                return nil
            }
            let hasMarker = html.contains("__INITIAL_STATE__")
            log.notice(
                "weread diag: reader page status=\(readerStatus, privacy: .public) len=\(html.count, privacy: .public) hasInitialState=\(hasMarker, privacy: .public)"
            )
            guard let parsed = WereadReaderSessionParser.session(from: html) else {
                log.notice("weread diag: reader page has no session beacon")
                return nil
            }
            // 只解析出 token、没有 `psvts`/`pclts` 的页面没法拿来取正文，
            // 当没信标处理，让调用方直接走旧版请求。
            guard !parsed.isEmpty else {
                log.notice("weread diag: reader page session beacon is empty")
                return nil
            }
            log.notice(
                "weread diag: reader session ok psvts=\(parsed.psvts.count, privacy: .public) pclts=\(parsed.pclts.count, privacy: .public) defaultPs=\(!parsed.defaultPs.isEmpty, privacy: .public)"
            )
            storeSession(parsed, for: cacheKey)
            return parsed
        } catch {
            log.notice("weread diag: reader page fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func cachedSession(for key: String) -> WereadReaderSession? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let entry = sessionCache[key] else { return nil }
        if Date().timeIntervalSince(entry.stamp) > Self.sessionTTL {
            sessionCache[key] = nil
            return nil
        }
        return entry.value
    }

    private func storeSession(_ value: WereadReaderSession, for key: String) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        // 顺手清掉过期条目，避免这本书读完一章攒一条一直不清。
        let now = Date()
        sessionCache = sessionCache.filter { now.timeIntervalSince($0.value.stamp) <= Self.sessionTTL }
        sessionCache[key] = (value, now)
    }

    /// 让阅读器页面里的信标失效（比如正文接口回了 `{}`，说明手里的信标不对）。
    func invalidateSession(bookId: String, chapterUid: Int) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        sessionCache["\(bookId)#\(chapterUid)"] = nil
    }

    // MARK: - 会话续期

    /// cookie 过期时续一次。
    ///
    /// 服务端成功时回 `{"succ":1}`。成功但没有下发新 cookie 是
    /// `.unchanged`，不是失败；传输错误是 `.transient`。只有服务端
    /// 明确拒绝时才返回 `.rejected`，调用方据此决定是否清登录态。
    ///
    /// 同一个源 cookie 的并发续期会合并成一次请求；结果由 Store
    /// 以「源 cookie + generation」为条件原子落盘。
    func renew(cookie: String) async -> WereadRenewalOutcome {
        await renewalCoordinator.renew(cookie: cookie) { [weak self] in
            guard let self else { return .transient }
            return await self.performRenewal(cookie: cookie)
        }
    }

    private func performRenewal(cookie: String) async -> WereadRenewalOutcome {
        var request = URLRequest(url: URL(string: "\(base)/web/login/renewal")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.authProbeTimeout
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["rq": "%2Fweb%2Fbook%2Fread", "ql": false]
        )
        do {
            let (data, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    log.info("weread: renewal rejected HTTP \(http.statusCode, privacy: .public)")
                    return .rejected
                }
                guard (200..<300).contains(http.statusCode) else {
                    log.info("weread: renewal transient HTTP \(http.statusCode, privacy: .public)")
                    return .transient
                }
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                log.info("weread: renewal returned a non-JSON body")
                return .transient
            }
            if let code = intValue(json["errCode"]), code == -2010 || code == -2012 {
                log.info("weread: renewal rejected errCode \(code, privacy: .public)")
                return .rejected
            }
            guard intValue(json["succ"]) == 1 else {
                if let succ = intValue(json["succ"]), succ == 0 {
                    log.info("weread: renewal rejected succ=0")
                    return .rejected
                }
                log.info("weread: renewal response has no success flag")
                return .transient
            }
            // 从响应头里捞新 cookie，合并进旧的。
            let merged = Self.mergeCookies(existing: cookie, response: response)
            if let merged, merged != cookie {
                log.info("weread: renewal ok, cookie changed")
                return .renewed(merged)
            }
            log.info("weread: renewal ok, cookie unchanged")
            return .unchanged
        } catch {
            log.info("weread: renewal failed: \(String(describing: error), privacy: .public)")
            return .transient
        }
    }

    /// 把 `Set-Cookie` 里的 kv 合并进旧 cookie 串。
    ///
    /// 同名 cookie 以服务端新值为准 —— 过期的 `wr_skey` 同时存在会导致
    /// 「登录超时」反复出现。
    private static func mergeCookies(existing: String, response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        var pairs: [(String, String)] = []
        var index: [String: Int] = [:]
        for part in existing.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let at = index[name] {
                pairs[at].1 = value
            } else {
                index[name] = pairs.count
                pairs.append((name, value))
            }
        }

        // 只有会话键真的换了才算续期成功。`Set-Cookie` 里经常还会刷新
        // 埋点/设备类 cookie；把它们当新会话会让调用方误以为已经续期，
        // 用同一个 `wr_skey` 重试再被拒，最后错误地注销用户。
        var sessionChanged = false
        for (key, raw) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            for line in String(describing: raw).components(separatedBy: "\n") {
                let head = line.split(separator: ";").first.map(String.init) ?? ""
                let pieces = head.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { continue }
                let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                if let at = index[name] {
                    if pairs[at].1 != value {
                        pairs[at].1 = value
                        if name == "wr_skey" { sessionChanged = true }
                    }
                } else {
                    index[name] = pairs.count
                    pairs.append((name, value))
                    if name == "wr_skey" { sessionChanged = true }
                }
            }
        }
        guard sessionChanged else { return nil }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    // MARK: - 书架

    /// 鉴权探活、续期与书架分页的单项超时。会话默认 20 秒对进页恢复太久：
    /// 网络黑洞时要尽快落到「重试」，超时按临时失败处理，cookie 不会被清。
    private static let authProbeTimeout: TimeInterval = 10

    /// 拉书架。`maxPages` 限制翻页数：进页恢复会话时只要 1 页先抢首屏，
    /// 等书架可见后由调用方再补全；普通刷新默认拉满 4 页。
    func shelf(cookie: String, maxPages: Int = 4) async throws -> [WereadBook] {
        do {
            return try await fetchShelf(cookie: cookie, maxPages: maxPages)
        } catch WereadError.notLoggedIn {
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
    }

    private func fetchShelf(cookie: String, maxPages: Int) async throws -> [WereadBook] {
        // `synckeys=0` 只给第一页，书架大的人会少一截（用户说的「没还原全」）。
        // 接口会在响应里回一个新的 synckey，带着它再要一页，直到没有新书。
        var result: [WereadBook] = []
        var seen = Set<String>()
        var syncKey = "0"
        var pages: [[String: Any]] = []
        for _ in 0..<max(1, min(maxPages, 4)) {
            let url = URL(string: "\(base)/web/shelf/sync?synckeys=\(syncKey)&teenmode=0&album=1")!
            var request = URLRequest(url: url)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.timeoutInterval = Self.authProbeTimeout

            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            pages.append(json)

            var added = 0
            for book in books(fromShelfJSON: json) where !seen.contains(book.id) {
                seen.insert(book.id)
                result.append(book)
                added += 1
            }
            guard added > 0 else { break }
            let next =
                (json["synckey"] as? NSNumber)?.stringValue
                ?? (json["synckeyStr"] as? String)
            guard let nextKey = next, !nextKey.isEmpty, nextKey != syncKey, nextKey != "0" else {
                break
            }
            syncKey = nextKey
        }
        // 分组和阅读进度往往只在第一页下发：后几页的书单独解析会掉分组、
        // 丢掉「最近阅读」时间。把每一页合并成一份响应再解析一遍。
        guard pages.count > 1 else { return result }
        return books(fromShelfJSON: pages)
    }

    /// 多页 `shelf/sync` 合并后再解析：`bookGroups` / `bookProgress` 可能
    /// 分散在不同页，逐页解析会让后几页的书没有分组、排序也不对。
    func books(fromShelfJSON pages: [[String: Any]]) -> [WereadBook] {
        var books: [[String: Any]] = []
        var archive: [[String: Any]] = []
        var groups: [[String: Any]] = []
        var progress: [[String: Any]] = []
        for page in pages {
            books.append(contentsOf: page["books"] as? [[String: Any]] ?? [])
            archive.append(contentsOf: page["archive"] as? [[String: Any]] ?? [])
            for key in ["bookGroups", "book_groups", "groups"] {
                groups.append(contentsOf: page[key] as? [[String: Any]] ?? [])
            }
            for key in ["bookProgress", "book_progress"] {
                progress.append(contentsOf: page[key] as? [[String: Any]] ?? [])
            }
        }
        let merged: [String: Any] = [
            "books": books,
            "archive": archive,
            "bookGroups": groups,
            "bookProgress": progress,
        ]
        return self.books(fromShelfJSON: merged)
    }

    /// 把 `shelf/sync` 的响应翻成书单。
    ///
    /// 网页版书架拉的也是这个接口，`WebPageHarvester` 会把响应搬回来，
    /// 所以解析只写这一份，两条路共用。
    func books(fromShelfJSON json: [String: Any]) -> [WereadBook] {
        // `books` 是书架上的书，`archive` 是归档过的书；只看 books 会少一截，
        // 用户会觉得「书架没还原全」。
        let books = json["books"] as? [[String: Any]] ?? []
        let archive = json["archive"] as? [[String: Any]] ?? []
        let groups = groupMap(json)
        let progress = progressMap(json)
        var seen = Set<String>()
        var result: [WereadBook] = []
        for item in books + archive {
            guard var book = parseBook(item), !seen.contains(book.id) else { continue }
            seen.insert(book.id)
            if let name = groups[book.id] { book.group = name }
            // `books` 里往往没有进度，进度和时间戳在 `bookProgress` 里。
            if let extra = progress[book.id] {
                if extra.percent > book.progress { book.progress = extra.percent }
                if extra.updatedAt > book.updatedAt { book.updatedAt = extra.updatedAt }
            }
            result.append(book)
        }
        return result
    }

    /// 书架分组的「书 → 分组名」映射。
    ///
    /// 网页书架的分组在 `shelf/sync` 里叫 `bookGroups`，不同版本还见过
    /// `book_groups` / `groups`，组内书目又可能是 `bookIds` / `book_ids` / `books`
    /// 三种写法（字符串数组或对象数组）。全都试一遍，认不出来就当没分组。
    private func groupMap(_ json: [String: Any]) -> [String: String] {
        var map: [String: String] = [:]
        var containers: [[String: Any]] = []
        for key in ["bookGroups", "book_groups", "groups"] {
            if let list = json[key] as? [[String: Any]] {
                containers.append(contentsOf: list)
            }
        }
        for group in containers {
            let name =
                (group["title"] as? String)
                ?? (group["name"] as? String)
                ?? ""
            guard !name.isEmpty else { continue }
            var ids: [String] = []
            for key in ["bookIds", "book_ids", "books"] {
                if let list = group[key] as? [String] {
                    ids.append(contentsOf: list)
                } else if let list = group[key] as? [[String: Any]] {
                    for item in list {
                        if let id = item["bookId"] as? String {
                            ids.append(id)
                        } else if let number = item["bookId"] as? NSNumber {
                            ids.append(number.stringValue)
                        }
                    }
                }
            }
            for id in ids where !id.isEmpty {
                if map[id] == nil { map[id] = name }
            }
        }
        return map
    }

    /// 每本书的阅读进度与最近阅读时间。
    ///
    /// `shelf/sync` 把书的信息和阅读进度分成两份：`books` 只有书本身，
    /// 进度、`updateTime` 全在 `bookProgress` 里。只读 `books` 的话书架
    /// 既没有进度百分比，也没法按「最近阅读」排序 —— 用户看到的顺序
    /// 就是接口给的原始顺序。
    private func progressMap(
        _ json: [String: Any]
    ) -> [String: (percent: Int, updatedAt: TimeInterval)] {
        var map: [String: (percent: Int, updatedAt: TimeInterval)] = [:]
        var containers: [[String: Any]] = []
        for key in ["bookProgress", "book_progress"] {
            if let list = json[key] as? [[String: Any]] {
                containers.append(contentsOf: list)
            }
        }
        for item in containers {
            let id =
                (item["bookId"] as? String)
                ?? (item["bookId"] as? NSNumber)?.stringValue
            guard let bookId = id, !bookId.isEmpty else { continue }
            map[bookId] = (percentValue(item), stampValue(item))
        }
        return map
    }

    /// `bookProgress[].progress` 有三种形态：整数、单个对象、对象数组。
    /// 只按整数读的话，网页版那种 `{chapterUid, progress}` 会一律变成 0。
    private func percentValue(_ item: [String: Any]) -> Int {
        let raw: Int?
        if let list = item["progress"] as? [[String: Any]] {
            raw = intValue(list.first?["progress"])
        } else if let dict = item["progress"] as? [String: Any] {
            raw = intValue(dict["progress"])
        } else {
            raw = intValue(item["progress"])
        }
        return min(max(raw ?? 0, 0), 100)
    }

    /// 最近阅读时间。`readUpdateTime` 是书架级的秒级时间戳，
    /// `progress[].updateTime` 是每本书自己的（常见是毫秒）。
    private func stampValue(_ item: [String: Any]) -> TimeInterval {
        var stamp = intValue(item["readUpdateTime"]) ?? 0
        if stamp == 0, let list = item["progress"] as? [[String: Any]] {
            stamp = intValue(list.first?["updateTime"]) ?? 0
        }
        if stamp == 0, let dict = item["progress"] as? [String: Any] {
            stamp = intValue(dict["updateTime"]) ?? 0
        }
        if stamp == 0 {
            stamp = intValue(item["updateTime"]) ?? 0
        }
        var value = TimeInterval(max(stamp, 0))
        if value > 10_000_000_000 { value /= 1000 }
        return value
    }

    // MARK: - 目录

    func chapters(bookId: String, cookie: String) async throws -> [WereadChapter] {
        do {
            return try await fetchChapters(bookId: bookId, cookie: cookie)
        } catch WereadError.notLoggedIn {
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
    }

    /// 目录主用现行 `/web/book/chapterInfos`；新接口返回空时回退老
    /// `/web/book/publicchapterInfos` 一次，兼容只认老接口的会话。
    private func fetchChapters(bookId: String, cookie: String) async throws -> [WereadChapter] {
        let primary = try await fetchChapterList(
            api: "chapterInfos",
            bookId: bookId,
            cookie: cookie
        )
        guard primary.isEmpty else { return primary }

        Self.screenDiag("目录 chapterInfos chapters=0，回退 publicchapterInfos")
        let fallback = try await fetchChapterList(
            api: "publicchapterInfos",
            bookId: bookId,
            cookie: cookie
        )
        return fallback
    }

    private func fetchChapterList(
        api: String,
        bookId: String,
        cookie: String
    ) async throws -> [WereadChapter] {
        var request = URLRequest(url: URL(string: "\(base)/web/book/\(api)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bookIds": [bookId]])

        let (data, status) = try await sendWithStatus(request)
        let json = try parseObject(data)
        try checkError(json)

        let entries = json["data"] as? [[String: Any]] ?? []
        let target = entries.first { ($0["bookId"] as? String) == bookId } ?? entries.first
        let updated = target?["updated"] as? [[String: Any]] ?? []
        let topKeys = json.keys.sorted().prefix(8).joined(separator: ",")
        Self.screenDiag(
            "目录接口 /web/book/\(api) → \(status) → updated=\(updated.count) entries=\(entries.count) target=\(target != nil) keys=\(topKeys)"
        )

        return updated.compactMap { item -> WereadChapter? in
            guard let uid = intValue(item["chapterUid"]) else { return nil }
            return WereadChapter(
                uid: uid,
                index: intValue(item["chapterIdx"]) ?? 0,
                title: item["title"] as? String ?? "",
                level: intValue(item["level"]) ?? 1,
                wordCount: intValue(item["wordCount"]) ?? 0,
                translateVersion: intValue(item["translateVersion"]) ?? 0
            )
        }
    }

    // MARK: - 正文

    /// 返回一章的 HTML。epub 书要拼 4 个分片，txt 书拼 2 个。
    ///
    /// 取正文的优先级（从「旧」到「新」）：
    /// 1. 旧版直接正文请求：固定 `ps`/`pc`，不带 `sc` / `prevChapter`。
    ///    107 版就靠这条路径正常看书，所以放第一位；
    /// 2. 旧版回 `{}` → 再试阅读器页面信标：真实 `ps`/`pc` + `sc=1`（epub 书需要）；
    /// 3. 还是空 → 丢掉缓存信标、重抓一次页面，再试一次；
    /// 4. 回 `-2012`（登录超时）→ 交给 Store 串行续期、切换会话后重试。
    func content(bookId: String, chapterUid: Int, cookie: String) async throws -> String {
        do {
            return try await fetchChapterWithFallback(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: cookie
            )
        } catch WereadError.notLoggedIn {
            // 续期/候选会话切换统一由 Store 串行处理；这里只标记被拒绝的源 cookie。
            // 旧实现会在续期成功后丢掉信标缓存；现在续期搬到 Store，也必须
            // 在换会话重试前丢掉，否则新 cookie 仍会带着旧 `psvts` 再吃一次 -2012。
            invalidateSession(bookId: bookId, chapterUid: chapterUid)
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
    }

    /// 取正文顺序：**先旧版直连，再阅读器会话信标**。
    ///
    /// 107 版（能正常看书的版本）就是直接带固定 `ps`/`pc` 直连，书架里的书
    /// 一直能取到。后来为了 epub 书加了「阅读器会话信标」，却把它放在了最前面：
    /// 只要抓到信标，就改用页面里的 `ps` 并追加 `sc` / `prevChapter`，
    /// 反而把原本能用的旧版请求挤掉了 —— 这就是「做完选文段之后反而看不了书」。
    ///
    /// 所以顺序改回去：旧版直连优先（恢复 107 行为），空了再试信标（给 epub 书留路）。
    private func fetchChapterWithFallback(
        bookId: String,
        chapterUid: Int,
        cookie: String
    ) async throws -> String {
        // 1. 旧版直连：与 107 完全一致，不带信标、不带 sc/prevChapter。
        do {
            return try await fetchChapter(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: cookie,
                beacon: nil
            )
        } catch WereadError.empty {
            // 2. 旧版拿不到，再尝试这一章的阅读器会话信标（epub 书需要）。
            var beacon = await readerSession(bookId: bookId, chapterUid: chapterUid, cookie: cookie)
            if beacon?.ps(for: chapterUid) == nil { beacon = nil }
            guard let beaconValue = beacon else {
                // 没有信标可用：只能刷新一次再试旧版。
                return try await fetchWithRefreshedSession(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    previous: nil
                )
            }
            log.notice("weread diag: legacy direct request empty, retrying with reader session beacon")
            do {
                return try await fetchChapter(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    beacon: beaconValue
                )
            } catch WereadError.empty {
                return try await fetchWithRefreshedSession(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    previous: beaconValue
                )
            }
        }
    }

    /// 丢掉缓存信标、重抓一次页面，再取一次正文。
    private func fetchWithRefreshedSession(
        bookId: String,
        chapterUid: Int,
        cookie: String,
        previous: WereadReaderSession?
    ) async throws -> String {
        invalidateSession(bookId: bookId, chapterUid: chapterUid)
        guard let fresh = await readerSession(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie
        ), fresh.ps(for: chapterUid) != nil, fresh != previous else {
            log.info("weread: content empty and no refreshed session beacon")
            throw WereadError.empty
        }
        log.info("weread: retrying content with refreshed reader session")
        return try await fetchChapter(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie,
            beacon: fresh
        )
    }

    private func fetchChapter(
        bookId: String,
        chapterUid: Int,
        cookie: String,
        beacon: WereadReaderSession?
    ) async throws -> String {
        let uid = String(chapterUid)

        // 四种分片用 `try?`：txt 书请求 `e_*` 会 404，以前这里 `try await`
        // 一抛错就整章失败，下面的 `t_*` 兜底根本走不到 —— 表现就是
        // 「点开一直白屏 / 一直转圈」。
        //
        // 显式标 `String?`：`async let x = try? f()` 在 Swift 6.x 下会让编译器
        // 在「声明处用 try?」和「被延后调用的函数里用 try?」之间有歧义，
        // 加了类型标注就没有解释空间了。
        async let epub0: String? = try? fragment("/web/book/chapter/e_0", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie, beacon: beacon)
        async let epub1: String? = try? fragment("/web/book/chapter/e_1", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie, beacon: beacon)
        async let epub2: String? = try? fragment("/web/book/chapter/e_2", bookId: bookId, chapterUid: uid, st: 1, cookie: cookie, beacon: beacon)
        async let epub3: String? = try? fragment("/web/book/chapter/e_3", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie, beacon: beacon)

        let (raw0, raw1, raw2, raw3) = await (epub0, epub1, epub2, epub3)
        let part0 = raw0 ?? ""
        let part1 = raw1 ?? ""
        let part2 = raw2 ?? ""
        let part3 = raw3 ?? ""

        // 先认格式再拼：`{}` 是「参数/会话不对」的失败响应，TXT 书的 `e_*`
        // 返回的是章节元数据 JSON。这两种都不是正文，以前那句
        // `!part0.isEmpty` 会把它们当成有效分片送进 decrypt，
        // 解出空串/垃圾后抛 empty —— 用户看到的就是白屏。
        switch try shardFormat(part0, part1, part3) {
        case .txt:
            return try await textChapter(bookId: bookId, chapterUid: uid, cookie: cookie, beacon: beacon)
        case .epub:
            break
        }

        let style = WereadCrypto.decrypt(part2)
        var html = WereadCrypto.decrypt(part0 + part1 + part3)
        guard !html.isEmpty else { throw WereadError.empty }
        html = clean(html)
        if !style.isEmpty {
            html = "<style>\(style)</style>\(html)"
        }
        return html
    }

    /// 分片形态判定。
    ///
    /// - 都是空 → 接口没给内容
    /// - `e_0` 以 `{` 开头 → 要么是 `{}`（请求错误），要么是 TXT 书的章节元数据
    /// - 其余当 epub
    private enum ShardFormat {
        case epub
        case txt
    }

    private func shardFormat(
        _ part0: String,
        _ part1: String,
        _ part3: String
    ) throws -> ShardFormat {
        if part0.isEmpty, part1.isEmpty, part3.isEmpty {
            throw WereadError.empty
        }
        let head = part0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("{") else { return .epub }
        // TXT 书：`e_*` 回的是含 bookId 的章节元数据。
        if head.contains("\"bookId\"") {
            return .txt
        }
        // 其余 JSON 一律是错误响应（`{}`、errCode 等）。
        if let data = head.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = intValue(json["errCode"]), code == -2010 || code == -2012 {
                throw WereadError.notLoggedIn
            }
            if let message = json["errMsg"] as? String, !message.isEmpty {
                throw WereadError.server(message)
            }
            if !json.isEmpty {
                throw WereadError.server("正文接口返回了 JSON，不是章节内容")
            }
            // `{}`：签名/会话/参数不对。参考实现里最常见的原因是
            // `ps`/`pc` 不是本次阅读器会话的 psvts / _e(ct)，以及缺 `sc=1`。
            throw WereadError.empty
        }
        throw WereadError.empty
    }

    /// 老 txt 书走 `t_0` / `t_1`。
    private func textChapter(
        bookId: String,
        chapterUid: String,
        cookie: String,
        beacon: WereadReaderSession?
    ) async throws -> String {
        async let txt0: String? = try? fragment("/web/book/chapter/t_0", bookId: bookId, chapterUid: chapterUid, st: 0, cookie: cookie, beacon: beacon)
        async let txt1: String? = try? fragment("/web/book/chapter/t_1", bookId: bookId, chapterUid: chapterUid, st: 1, cookie: cookie, beacon: beacon)
        let (rawText0, rawText1) = await (txt0, txt1)
        let text = WereadCrypto.decrypt((rawText0 ?? "") + (rawText1 ?? ""))
        guard !text.isEmpty else { throw WereadError.empty }
        return clean(text)
    }

    // MARK: - 翻译（实验）

    /// 切换微读官方翻译开关。译文由章节正文随 `.wr-translation` 节点返回，
    /// 这里只改服务端状态，不保存任何译文。
    ///
    /// 接口不是公开 API，字段语义只能真机确认。这里按最保守的规则判定：
    /// 只有显式成功字段才返回 `.accepted`，2xx 空回包返回 `.uncertain`。
    func setTranslation(
        bookId: String,
        enabled: Bool,
        cookie: String
    ) async throws -> WereadTranslationAck {
        var request = URLRequest(url: URL(string: "\(base)/web/reader/toggleTranslate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "bookId": bookId,
            "enabled": enabled,
        ])

        let (data, status) = try await sendWithStatus(request, redactBody: true)
        let action = enabled ? "开启" : "关闭"
        if data.isEmpty {
            return .uncertain("官方返回 HTTP \(status)，空回包，未确认是否\(action)")
        }
        let raw = try parseObject(data)
        let json = translationPayload(raw)
        try checkError(raw)
        try checkError(json)
        return translationAck(json, status: status, action: action)
    }

    /// 触发一次官方译文生成/轮询。`uid` 传当前 `chapterUid`。
    ///
    /// 官方 `read[]` 的初始版本是 `chapter.translateVersion || 0`：未翻译
    /// 章节必须传 0，不能拿 1 冒充「已持有译文」，否则服务端会误判不需要
    /// 生成。之后只把回包（顶层或 `curStatus`）里的新版本沿用到下一轮。
    ///
    /// 完成信号按官方轮询语义读 `curStatus`：当前 `uid` 的
    /// `translateVersion` 大于 `chapterVersion` 即视为译文已生成；
    /// `stopPoll` 只表示停止轮询，不保证有译文。字段语义尚未真机证实，
    /// 失败只按回包如实上报，不做本地机翻兜底。
    func requestTranslation(
        bookId: String,
        uid: Int,
        chapterVersion: Int,
        translateVersion: Int,
        cookie: String
    ) async throws -> WereadTranslationTrigger {
        var request = URLRequest(url: URL(string: "\(base)/web/book/enRead")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "bookId": bookId,
            "reference": [
                "uid": uid,
                "texts": [String](),
            ],
            "read": [
                [
                    "uid": uid,
                    "translateVersion": translateVersion,
                ],
            ],
        ])

        let (data, _) = try await sendWithStatus(request, redactBody: true)
        if data.isEmpty {
            return WereadTranslationTrigger(
                state: .pending,
                translateVersion: nil,
                tip: nil
            )
        }
        let raw = try parseObject(data)
        let json = translationPayload(raw)
        try checkError(raw)
        try checkError(json)
        let stop = boolValue(json["stopPoll"]) ?? false
        let statusVersion = curStatusVersion(json, uid: uid)
        let topVersion = intValue(json["translateVersion"]) ?? intValue(json["version"])
        let latestVersion = [statusVersion, topVersion].compactMap { $0 }.max()
        let state: WereadTranslationTrigger.State
        if let statusVersion, statusVersion > chapterVersion {
            state = .completed
        } else if stop {
            state = .stop
        } else {
            state = .pending
        }
        return WereadTranslationTrigger(
            state: state,
            translateVersion: latestVersion,
            tip: translationTip(json)
        )
    }

    /// 官方 `curStatus` 的元素带 `uid` / `translateVersion`；回包可能是数组，
    /// 也可能是以 uid 为键的字典。只取当前章节的版本号，别的章节忽略。
    private func curStatusVersion(_ json: [String: Any], uid: Int) -> Int? {
        guard let raw = json["curStatus"] ?? json["curstatus"] else { return nil }
        if let list = raw as? [[String: Any]] {
            for item in list where intValue(item["uid"]) == uid {
                if let version = translationVersion(in: item) { return version }
            }
            return nil
        }
        if let map = raw as? [String: Any] {
            if let item = map[String(uid)] as? [String: Any],
               let version = translationVersion(in: item)
            {
                return version
            }
            for value in map.values {
                guard let item = value as? [String: Any],
                      intValue(item["uid"]) == uid,
                      let version = translationVersion(in: item)
                else { continue }
                return version
            }
        }
        return nil
    }

    private func translationVersion(in item: [String: Any]) -> Int? {
        intValue(item["translateVersion"])
            ?? intValue(item["translateversion"])
            ?? intValue(item["version"])
    }

    /// 会员摘要只用于失败时补充说明。Flare 不用它拦截翻译，
    /// 也不据此判断一本书有没有译文；取不到就返回 nil。
    func memberCardStatus(cookie: String) async -> Bool? {
        var request = URLRequest(
            url: URL(string: "\(base)/web/pay/memberCardSummary?pf=ios")!
        )
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        do {
            let (data, _) = try await sendWithStatus(request, redactBody: true)
            let raw = try parseObject(data)
            let json = translationPayload(raw)
            try checkError(raw)
            try checkError(json)
            if let value =
                boolValue(json["isPaying"])
                ?? boolValue(json["isMember"])
                ?? boolValue(json["member"])
                ?? boolValue(json["isVip"])
                ?? boolValue(json["vip"])
            {
                return value
            }
            if let status = intValue(json["memberStatus"]) {
                return status == 1
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 把 2xx 回包翻译成「确认 / 未确认 / 拒绝」，不把空回包当成功。
    private func translationAck(
        _ json: [String: Any],
        status: Int,
        action: String
    ) -> WereadTranslationAck {
        if intValue(json["succ"]) == 0 || boolValue(json["success"]) == false {
            return .rejected(translationTip(json) ?? "官方拒绝\(action)翻译")
        }
        if intValue(json["succ"]) == 1 || boolValue(json["success"]) == true {
            return .accepted
        }
        let keys = json.keys.sorted().prefix(6).joined(separator: ",")
        let fields = keys.isEmpty ? "空回包" : keys
        return .uncertain(
            "官方返回 HTTP \(status)，但没有明确确认\(action)（字段：\(fields)）"
        )
    }

    /// 官方回包有时把业务字段放顶层，有时包一层 `data`。
    /// 两层合并、`data` 优先：顶层 `succ` 不会因为 `data` 非空而漏判，
    /// `data` 为空对象时也仍按顶层读，避免把空壳当结果。
    private func translationPayload(_ raw: [String: Any]) -> [String: Any] {
        guard let data = raw["data"] as? [String: Any], !data.isEmpty else {
            return raw
        }
        var merged = raw
        merged.removeValue(forKey: "data")
        for (key, value) in data {
            merged[key] = value
        }
        return merged
    }

    /// 官方提示可能在不同字段/数组里，取第一个能读的文本。
    private func translationTip(_ json: [String: Any]) -> String? {
        if let tips = json["tips"] {
            if let text = tips as? String, !text.isEmpty { return text }
            if let list = tips as? [String] {
                let text = list.filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty { return text }
            }
            if let list = tips as? [[String: Any]] {
                let text = list.compactMap {
                    ($0["content"] as? String)
                        ?? ($0["text"] as? String)
                        ?? ($0["tips"] as? String)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                if !text.isEmpty { return text }
            }
        }
        for key in ["errMsg", "errmsg", "message", "msg"] {
            if let text = json[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - 进度

    /// 带服务端时间戳的进度快照。`updatedAt` 是 `updateTime` 换算成秒；
    /// 服务端没给时为 0，交给上层决定要不要信本地记录。
    struct ProgressSnapshot: Sendable {
        let chapterUid: Int
        let chapterOffset: Int
        let percent: Int
        let updatedAt: TimeInterval

        var progress: WereadProgress {
            WereadProgress(
                chapterUid: chapterUid,
                chapterOffset: chapterOffset,
                percent: percent
            )
        }
    }

    func progress(bookId: String, cookie: String) async throws -> WereadProgress? {
        guard let snapshot = try await progressSnapshot(bookId: bookId, cookie: cookie) else {
            return nil
        }
        return WereadProgress(
            chapterUid: snapshot.chapterUid,
            chapterOffset: snapshot.chapterOffset,
            percent: snapshot.percent
        )
    }

    /// 拉这本书的阅读进度。
    ///
    /// `/web/book/getProgress` 真机响应是**顶层平铺**
    /// （`{"bookId":...,"chapterUid":5,"chapterOffset":330,...}`），
    /// 旧代码只认 `json["book"]`，于是明明有进度也被当成「没读过」，
    /// 每次打开都从第一章开始。这里同时兼容 `book` / `data` 包一层的形态。
    func progressSnapshot(bookId: String, cookie: String) async throws -> ProgressSnapshot? {
        let url = URL(string: "\(base)/web/book/getProgress?bookId=\(bookId)")!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")

        let data = try await send(request)
        let json = try parseObject(data)
        // 没读过时接口会给 errCode，当作「没有进度」处理，不弹错误。
        if let code = intValue(json["errCode"]) ?? intValue(json["errcode"]), code != 0 {
            return nil
        }

        guard let node = progressNode(in: json) else { return nil }
        let chapterUid =
            intValue(node["chapterUid"])
            ?? intValue(node["chapter_uid"])
            ?? intValue(node["chapterId"])
            ?? 0
        let chapterOffset =
            intValue(node["chapterOffset"])
            ?? intValue(node["chapter_offset"])
            ?? 0
        // `progress` 是整本书的 0-100 百分比，不是章内比例；拿它当
        // 章内进度会把「读到全书一半」错误地滚到本章一半。章内兜底
        // 只认明确带 chapter 前缀的字段。
        let percent =
            intValue(node["chapterProgress"])
            ?? intValue(node["chapter_progress"])
            ?? intValue(node["chapterPercent"])
            ?? intValue(node["chapter_percent"])
            ?? 0
        // 没有 chapterUid 就无法定位到章，offset 再大也不能可靠恢复。
        guard chapterUid > 0 else { return nil }
        let chapterPercent = min(max(percent, 0), 100)

        var stampNodes: [[String: Any]] = [node]
        if let nested = node["progress"] as? [String: Any] { stampNodes.append(nested) }
        if let list = node["progress"] as? [[String: Any]], let first = list.first {
            stampNodes.append(first)
        }
        let rawStamp =
            stampNodes.compactMap { intValue($0["updateTime"]) ?? intValue($0["update_time"]) }.first
            ?? intValue(json["updateTime"])
            ?? intValue(json["update_time"])
            ?? intValue(json["readUpdateTime"])
            ?? intValue(json["read_update_time"])
            ?? 0
        // 微读时间戳有时是毫秒。
        let updatedAt = rawStamp > 100_000_000_000
            ? Double(rawStamp) / 1000
            : Double(rawStamp)

        return ProgressSnapshot(
            chapterUid: chapterUid,
            chapterOffset: chapterOffset,
            percent: chapterPercent,
            updatedAt: updatedAt
        )
    }

    /// 找真正带进度字段的那一层：顶层优先，其次 `book` / `data` / `bookInfo`。
    private func progressNode(in json: [String: Any]) -> [String: Any]? {
        var containers: [[String: Any]] = [json]
        for key in ["book", "bookInfo", "bookinfo", "data"] {
            guard let layer = json[key] as? [String: Any] else { continue }
            containers.append(layer)
            if let nested = layer["book"] as? [String: Any] { containers.append(nested) }
            if let nested = layer["bookInfo"] as? [String: Any] { containers.append(nested) }
        }
        var nodes: [[String: Any]] = []
        for item in containers {
            nodes.append(item)
            if let nested = item["progress"] as? [String: Any] { nodes.append(nested) }
            if let list = item["progress"] as? [[String: Any]] {
                nodes.append(contentsOf: list)
            }
        }
        // 先认真正带章节号的节点：顶层可能只有 `progress` 数组，不能
        // 挡住含 chapterUid 的 `book` / `data` / `progress[]`。`chapterUid`
        // 为 0 的节点也不能选，否则会在目录里永远匹配不到章。
        return nodes.first { node in
            (intValue(node["chapterUid"])
                ?? intValue(node["chapter_uid"])
                ?? intValue(node["chapterId"])
                ?? 0) > 0
        }
    }

    /// 上报阅读进度 / 阅读时长。失败不抛错 —— 报告丢一次不影响读书。
    ///
    /// `rt == 0` 时保持旧行为，只报章节进度；`rt > 0` 时按官方 reader JS
    /// `FETCH_READER_BOOK_READ` 的完整字段上报：
    /// `appId,b,c,ci,co,sm,pr,rt,ts,rn,sg,ct,ps,pc`，最后 `s = sign(全部字段)`。
    ///
    /// - `rt`：距上次上报的前台阅读秒数，官方上限 60；
    /// - `sg = sha256("\(ts)\(rn)\(readerToken)")`，token 来自 `/web/getConfig`；
    /// - `ci` 是章节序号（官方 `currentChapter.chapterIdx`），`c` 是 chapterUid 的 calcHash；
    /// - `ps` 取本章阅读器页面的 `psvts` 原值；`pc` 优先页面的 `pclts`，
    ///   没有就按官方 `_e(页面挂载秒)` 用会话抓取时刻现算（`ps` 拿不到才退回历史占位串）。
    @discardableResult
    func reportProgress(
        bookId: String,
        chapterUid: Int,
        chapterOffset: Int,
        chapterIndex: Int,
        rt: Int = 0,
        cookie: String
    ) async -> WereadReadReportOutcome {
        let seconds = min(max(rt, 0), 60)
        guard seconds > 0 else {
            await reportLegacyProgress(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterOffset: chapterOffset,
                chapterIndex: chapterIndex,
                cookie: cookie
            )
            // 这是纯进度上报，没有阅读时长可确认；不能伪装成「已发送时长」。
            return .failed("rt=0")
        }

        let tokenKey = WereadCrypto.md5(cookie)
        guard let token = await readerToken(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie,
            key: tokenKey
        ) else {
            let line = "read 缺 readerToken，跳过时长上报 rt=\(seconds)"
            Self.screenDiag(line)
            log.notice("weread diag: \(line, privacy: .public)")
            return .missingToken
        }

        let outcome = await postReadReport(
            bookId: bookId,
            chapterUid: chapterUid,
            chapterOffset: chapterOffset,
            chapterIndex: chapterIndex,
            rt: seconds,
            token: token,
            cookie: cookie
        )
        // 官方在 -806 时先刷新 getConfig 再重试一次。
        if case .rejected(let reason) = outcome, reason.contains("-806") {
            invalidateReaderToken(for: tokenKey)
            guard let fresh = await readerToken(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: cookie,
                key: tokenKey
            ) else {
                return outcome
            }
            return await postReadReport(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterOffset: chapterOffset,
                chapterIndex: chapterIndex,
                rt: seconds,
                token: fresh,
                cookie: cookie
            )
        }
        return outcome
    }

    /// 旧的进度上报：不依赖 readerToken / 签名，只在没有时长时使用。
    private func reportLegacyProgress(
        bookId: String,
        chapterUid: Int,
        chapterOffset: Int,
        chapterIndex: Int,
        cookie: String
    ) async {
        var request = URLRequest(url: URL(string: "\(base)/web/book/read")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "b": WereadCrypto.calcHash(bookId),
            "c": WereadCrypto.calcHash(String(chapterUid)),
            "ci": chapterIndex,
            "co": chapterOffset,
            "pr": 0,
            "ts": now * 1000,
            "ct": now,
            "rn": Int.random(in: 0..<1000),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await send(request)
    }

    /// 带 `rt` 的完整上报。`ps` 没有信标时退回历史占位串，`pc` 依次取页面
    /// `pclts` / 会话抓取时刻的 `_e(...)`；是否真被采信以服务端回包为准。
    private func postReadReport(
        bookId: String,
        chapterUid: Int,
        chapterOffset: Int,
        chapterIndex: Int,
        rt: Int,
        token: String,
        cookie: String
    ) async -> WereadReadReportOutcome {
        let sessionEntry = await readSessionForReport(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie
        )
        let now = Date().timeIntervalSince1970
        let ts = Int(now * 1000)
        let ct = Int(now)
        let rn = Int.random(in: 0..<1000)
        let sg = Self.sha256Hex("\(ts)\(rn)\(token)")
        let offset = max(chapterOffset, 0)
        let livePs = sessionEntry?.session.ps(for: chapterUid)
        let ps = livePs ?? Self.placeholderPs
        // 官方页面挂载时 `pclts = _e(当前秒级时间戳)`，整章不变；页面里没解析到
        // （或只是初始值 "0"）就用会话抓取时刻换算，避免每 30 秒变一次 `pc`。
        let livePc = sessionEntry?.session.pc(for: ct)
        let pc: String
        let pcSource: String
        if let livePc, !livePc.isEmpty, livePc != "0" {
            pc = livePc
            pcSource = "page"
        } else if let stamp = sessionEntry?.stamp {
            pc = WereadCrypto.calcHash(String(Int(stamp.timeIntervalSince1970)))
            pcSource = "calcHash(sessionStamp)"
        } else {
            pc = WereadCrypto.calcHash(String(ct))
            pcSource = "calcHash(ct)"
        }
        let appId = Self.readAppId(for: Self.readerUserAgent)

        let fields: [(String, String)] = [
            ("appId", appId),
            ("b", WereadCrypto.calcHash(bookId)),
            ("c", WereadCrypto.calcHash(String(chapterUid))),
            ("ci", String(chapterIndex)),
            ("co", String(offset)),
            ("sm", ""),
            ("pr", "0"),
            ("rt", String(rt)),
            ("ts", String(ts)),
            ("rn", String(rn)),
            ("sg", sg),
            ("ct", String(ct)),
            ("ps", ps),
            ("pc", pc),
        ]

        var request = URLRequest(url: URL(string: "\(base)/web/book/read")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")

        let payload: [String: Any] = [
            "appId": appId,
            "b": WereadCrypto.calcHash(bookId),
            "c": WereadCrypto.calcHash(String(chapterUid)),
            "ci": chapterIndex,
            "co": offset,
            "sm": "",
            "pr": 0,
            "rt": rt,
            "ts": ts,
            "rn": rn,
            "sg": sg,
            "ct": ct,
            "ps": ps,
            "pc": pc,
            "s": WereadCrypto.sign(fields),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let psSource = livePs != nil ? "session" : "placeholder"
        let beaconSource = "ps=\(psSource) pc=\(pcSource)"
        Self.screenDiag("read 上报 rt=\(rt) \(beaconSource) tokenLen=\(token.count)")
        // 不用 sendWithStatus：它会把非 2xx 也当 error 抛，且这里必须拿到真实
        // 状态码来区分「2xx 空回包（官方 {} 成功形态）」和「登录页/劫持页/5xx」。
        // 后者绝不能标成 .uncertain，否则调用方 consumeReadingSeconds(rt) 会
        // 永久扣掉这段时长且不重试，服务端进度也不会发。
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let head = String(decoding: data.prefix(160), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let succ = intValue(json?["succ"])
            let errCode = intValue(json?["errCode"]) ?? intValue(json?["errcode"])
            if succ == 1 {
                let line = "read OK rt=\(rt) status=\(status) \(beaconSource) head=\(head)"
                Self.screenDiag(line)
                log.notice("weread diag: \(line, privacy: .public)")
                return .accepted
            }
            if let errCode, errCode != 0 {
                let reason = "errCode=\(errCode) status=\(status) head=\(head)"
                let line = "read 拒绝 rt=\(rt) \(reason)"
                Self.screenDiag(line)
                log.notice("weread diag: \(line, privacy: .public)")
                return .rejected(reason)
            }
            // 只有 2xx + 空回包或可解析的 JSON 对象（`{}` 官方成功形态）才算
            // 「已发送但未确认」——这段时长真机再看是否计入。
            let is2xx = (200..<300).contains(status)
            let isEmptyOrJSON = data.isEmpty || json != nil
            if is2xx && isEmptyOrJSON {
                let line = "read 已发送 rt=\(rt) status=\(status) 2xx 无 succ/errCode（官方 {} 也算成功）head=\(head)"
                Self.screenDiag(line)
                log.notice("weread diag: \(line, privacy: .public)")
                return .uncertain(head)
            }
            // 非 2xx / HTML 登录页 / 解析失败：保留 pending 到下一轮，不消费 rt。
            let reason = "HTTP \(status) head=\(head)"
            let line = "read 失败 rt=\(rt) \(reason)"
            Self.screenDiag(line)
            log.notice("weread diag: \(line, privacy: .public)")
            return .failed(reason)
        } catch {
            let reason = String(describing: error)
            let line = "read 失败 rt=\(rt) error=\(reason)"
            Self.screenDiag(line)
            log.notice("weread diag: \(line, privacy: .public)")
            return .failed(reason)
        }
    }

    /// 取 readerToken：优先 10 分钟缓存，其次 `/web/getConfig`，
    /// 最后退回本章阅读器页面里的 `reader.token`。
    private func readerToken(
        bookId: String,
        chapterUid: Int,
        cookie: String,
        key: String
    ) async -> String? {
        if let cached = cachedReaderToken(for: key) { return cached }
        if let token = await fetchReaderToken(cookie: cookie) {
            storeReaderToken(token, for: key)
            return token
        }
        if let entry = await readSessionForReport(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie
        ), !entry.session.token.isEmpty {
            storeReaderToken(entry.session.token, for: key)
            return entry.session.token
        }
        return nil
    }

    private func fetchReaderToken(cookie: String) async -> String? {
        guard let url = URL(string: "\(base)/web/getConfig") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")
        do {
            let data = try await send(request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = json?["data"] as? [String: Any]
            let token =
                (nested?["token"] as? String)
                ?? (json?["token"] as? String)
                ?? ""
            guard !token.isEmpty else {
                log.notice("weread diag: getConfig 无 token")
                return nil
            }
            log.notice("weread diag: getConfig tokenLen=\(token.count, privacy: .public)")
            return token
        } catch {
            log.notice(
                "weread diag: getConfig 失败 \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// 正文可能走旧版直连、没留下信标；为上报补抓本章阅读器页面，
    /// 同一章 2 分钟内最多一次，避免每 30 秒下载一遍 HTML。
    private func readSessionForReport(
        bookId: String,
        chapterUid: Int,
        cookie: String
    ) async -> (session: WereadReaderSession, stamp: Date)? {
        let key = "\(bookId)#\(chapterUid)"
        if let cached = cachedReadReportSession(for: key) { return cached }
        if let cached = cachedSession(for: key) {
            return (cached, storeReadReportSession(cached, for: key))
        }
        guard beginReadSessionAttempt(for: key) else { return nil }
        guard let fetched = await readerSession(
            bookId: bookId,
            chapterUid: chapterUid,
            cookie: cookie
        ) else {
            return nil
        }
        return (fetched, storeReadReportSession(fetched, for: key))
    }

    // MARK: - 服务端笔记

    /// 一条「想法」。接口返回的是 review 列表，和划线按 `range` 关联。
    private struct ServerThought {
        let id: String
        let chapterUid: Int
        let range: String
        let abstract: String
        let content: String
        let createTime: TimeInterval
    }

    /// 拉取用户在这本书里同步到微读服务端的划线，并把「想法」挂到对应划线上。
    ///
    /// 对照 wereadx `web_book_bookmarklist`：GET `/web/book/bookmarklist?bookId=`
    /// 带 cookie。`updated[]` 只有划线字段（`bookmarkId / chapterUid /
    /// markText / range / createTime`），**没有 `note`**；想法来自
    /// `/web/review/list?listType=11&mine=1`，按 `range` 对齐
    /// （与 obsidian-weread-plugin `parseHighlights` 的做法一致）。
    ///
    /// 想法接口失败不影响划线：只降级成「没有想法」，不阻断阅读。
    func bookmarks(bookId: String, cookie: String) async throws -> [WereadBookmark] {
        do {
            return try await fetchBookmarks(bookId: bookId, cookie: cookie)
        } catch WereadError.notLoggedIn {
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
    }

    private func fetchBookmarks(bookId: String, cookie: String) async throws -> [WereadBookmark] {
        guard !cookie.isEmpty else { throw WereadError.notLoggedIn }
        var components = URLComponents(string: "\(base)/web/book/bookmarklist")
        components?.queryItems = [URLQueryItem(name: "bookId", value: bookId)]
        guard let url = components?.url else {
            throw WereadError.server("笔记接口地址无效")
        }

        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let data = try await send(request)
        let json = try parseObject(data)
        try checkError(json)

        let updated: [[String: Any]]
        if let list = json["updated"] as? [[String: Any]] {
            updated = list
        } else if !json.keys.contains("updated") {
            // 这本书在服务端没有划线时，接口返回 200 + `{}`，不是坏响应。
            updated = []
            let message = "bookmarklist book=\(bookId) 无 updated[]，按无服务端笔记处理"
            Self.screenDiag(message)
            FlareDiagnostics.shared.record(.weread, "RES", message)
        } else {
            Self.screenDiag("bookmarklist book=\(bookId) updated[] 类型错误")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "bookmarklist book=\(bookId) updated[] 类型错误"
            )
            throw WereadError.decodeFailed
        }
        let thoughtFetch = await fetchThoughts(bookId: bookId, cookie: cookie)
        let thoughts = thoughtFetch.thoughts
        // bookmarklist 对无效/过期 cookie 也会返回 200 + `{}`，不能只凭响应体
        // 判断「真的没有笔记」。review/list 会明确回 -2010/-2012，用它兜底：
        // 云端为空且想法接口说登录态失效时，交给 Store 续期/换会话后重试。
        if updated.isEmpty, thoughtFetch.authRejected {
            let message =
                "bookmarklist book=\(bookId) updated=0 且 review/list 登录态被拒绝；触发会话恢复"
            Self.screenDiag(message)
            FlareDiagnostics.shared.record(.weread, "ERR", message)
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
        // bookmarklist 为空且 review/list 临时失败时，不能把空数组当成
        // 「云端确实没有笔记」交给面板显示。否则网络抖动会让用户误以为
        // 笔记丢了，编辑/删除入口也会被一起藏掉。
        if updated.isEmpty, thoughtFetch.failed {
            let message =
                "bookmarklist book=\(bookId) updated=0 且 review/list 失败，无法确认云端笔记"
            Self.screenDiag(message)
            FlareDiagnostics.shared.record(.weread, "ERR", message)
            throw WereadError.server("云端笔记加载失败，请检查网络后重试")
        }
        // `range` 是章内字符偏移，不同章节会重复，必须带上 chapterUid 才能对齐。
        var thoughtsByLocation: [String: [ServerThought]] = [:]
        var usedThoughtIds = Set<String>()
        for thought in thoughts where !thought.range.isEmpty {
            let key = thoughtLocation(chapterUid: thought.chapterUid, range: thought.range)
            thoughtsByLocation[key, default: []].append(thought)
        }
        var thoughtsByText: [String: [ServerThought]] = [:]
        for thought in thoughts where !thought.abstract.isEmpty {
            let key = thoughtTextLocation(chapterUid: thought.chapterUid, text: thought.abstract)
            thoughtsByText[key, default: []].append(thought)
        }

        var result: [WereadBookmark] = []
        var seen = Set<String>()
        for (index, item) in updated.enumerated() {
            guard let chapterUid = intValue(item["chapterUid"]) else { continue }
            let markText = ((item["markText"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markText.isEmpty else { continue }

            let range = stringValue(item["range"])
            // 云端 id 可能是 JSON 字符串、数字或数组；统一转成字符串，
            // 否则数字 id 会被当成缺失并生成 `bookmark-...` 合成 id，删除时
            // 拿不到真实 bookmarkId。
            let rawId = identifierString(item["bookmarkId"])
            let id = rawId.isEmpty ? "bookmark-\(chapterUid)-\(range)-\(index)" : rawId
            guard seen.insert(id).inserted else { continue }

            var notes: [String] = []
            if let inlineNote = item["note"] as? String, !inlineNote.isEmpty {
                notes.append(inlineNote)
            }
            let location = thoughtLocation(chapterUid: chapterUid, range: range)
            let matched =
                thoughtsByLocation[location]
                ?? thoughtsByText[thoughtTextLocation(chapterUid: chapterUid, text: markText)]
            if let matched {
                for thought in matched {
                    usedThoughtIds.insert(thought.id)
                    if !thought.content.isEmpty, !notes.contains(thought.content) {
                        notes.append(thought.content)
                    }
                }
            }

            result.append(
                WereadBookmark(
                    id: id,
                    chapterUid: chapterUid,
                    markText: markText,
                    note: notes.joined(separator: "\n\n"),
                    range: range,
                    createTime: TimeInterval(intValue(item["createTime"]) ?? 0)
                )
            )
        }

        // 没有对应划线的想法（整章想法、或划线已被删除）也要能看到。
        for thought in thoughts where !usedThoughtIds.contains(thought.id) {
            guard !thought.content.isEmpty else { continue }
            result.append(
                WereadBookmark(
                    id: thought.id,
                    chapterUid: thought.chapterUid,
                    markText: thought.abstract,
                    note: thought.content,
                    range: thought.range,
                    createTime: thought.createTime
                )
            )
        }

        let summary =
            "bookmarklist book=\(bookId) updated=\(updated.count) reviews=\(thoughtFetch.reviewCount) total=\(thoughtFetch.totalCount) more=\(thoughtFetch.hasMore ? 1 : 0) type1=\(thoughtFetch.type1Count) type4=\(thoughtFetch.type4Count) vid=\(thoughtFetch.hasUserVid ? 1 : 0) thoughts=\(thoughts.count) parsed=\(result.count)"
        Self.screenDiag(summary)
        FlareDiagnostics.shared.record(.weread, "RES", summary)
        return result
    }

    private func thoughtLocation(chapterUid: Int, range: String) -> String {
        "\(chapterUid)|\(range)"
    }

    private func thoughtTextLocation(chapterUid: Int, text: String) -> String {
        "\(chapterUid)|\(text)"
    }

    private struct ThoughtFetchResult {
        var thoughts: [ServerThought] = []
        var reviewCount = 0
        var totalCount = 0
        var hasMore = false
        var type1Count = 0
        var type4Count = 0
        var hasUserVid = false
        var authRejected = false
        /// 非鉴权失败（网络 / 解密 / 解析）：调用方不能把空数组当成「确实没有想法」。
        var failed = false
    }

    /// 拉取自己的「想法」。失败只记日志并返回空数组，不影响划线；
    /// 非鉴权失败用 `failed` 标出，登录态被拒绝时用 `authRejected` 标出，
    /// 由 caller 决定是否续期或把空数组当成「确实没有想法」。
    ///
    /// `type == 1` 是划线想法，`type == 4` 是整章想法（官方也会展示），
    /// 两种都收；整章想法不按 range 挂到某条划线上。
    private func fetchThoughts(bookId: String, cookie: String) async -> ThoughtFetchResult {
        var result = ThoughtFetchResult()
        // 11-25 真机对照坐实（flare-diagnostic-20261125-133336.txt）：同一 cookie 同一本书，
        // review/list 在手机 UA 下三组参数（Flare 现用 / 官方 reader / wereadx 极简）全回
        // 41B 空；只有「官方 reader 参数 + 桌面 UA」回 12780B / 8 条想法。
        // 微读 review/list 按 User-Agent 区别对待，手机 UA 一律返回空。
        // 所以这里照成功那组原样发：listMode=3 + syncKey=0（去掉 maxIdx/count），桌面 UA。
        let userVid = cookieValue(named: "wr_vid", in: cookie)
        result.hasUserVid = userVid != nil
        var components = URLComponents(string: "\(base)/web/review/list")
        var queryItems = [
            URLQueryItem(name: "bookId", value: bookId),
            URLQueryItem(name: "listType", value: "11"),
            URLQueryItem(name: "listMode", value: "3"),
            URLQueryItem(name: "syncKey", value: "0"),
            URLQueryItem(name: "mine", value: "1"),
        ]
        if let userVid {
            queryItems.append(URLQueryItem(name: "userVid", value: userVid))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return result }

        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let reviews = json["reviews"] as? [[String: Any]] ?? []
            result.reviewCount = reviews.count
            result.totalCount = intValue(json["totalCount"]) ?? reviews.count
            result.hasMore = intValue(json["hasMore"]) == 1
            for (index, item) in reviews.enumerated() {
                // 标准回包把想法放在 `review` 里；个别版本会平铺到条目上，
                // 兜底读外层，避免 totalCount/thoughts 有值却一条都解析不出。
                let review = item["review"] as? [String: Any] ?? item
                guard
                    let chapterUid =
                        intValue(review["chapterUid"]) ?? intValue(item["chapterUid"]),
                    chapterUid > 0
                else {
                    continue
                }
                let type = intValue(review["type"]) ?? intValue(item["type"]) ?? 0
                if type == 1 { result.type1Count += 1 }
                if type == 4 { result.type4Count += 1 }
                guard type == 1 || type == 4 else { continue }
                let content = ((review["content"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let abstract = ((review["abstract"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let range = type == 1 ? stringValue(review["range"]) : ""
                // 服务端可能把 reviewId 序列化成数字或数组；这里必须宽读，
                // 否则 id 变空后会被 `thought-...` 合成 id 替代，列表能显示
                // 但编辑/删除找不到真实想法。
                let nestedReviewId = identifierString(review["reviewId"])
                let rawId =
                    nestedReviewId.isEmpty
                    ? identifierString(item["reviewId"])
                    : nestedReviewId
                let id = rawId.isEmpty ? "thought-\(chapterUid)-\(range)-\(index)" : rawId
                result.thoughts.append(
                    ServerThought(
                        id: id,
                        chapterUid: chapterUid,
                        range: range,
                        abstract: abstract,
                        content: content,
                        createTime: TimeInterval(intValue(review["createTime"]) ?? 0)
                    )
                )
            }
            return result
        } catch WereadError.notLoggedIn {
            result.authRejected = true
            log.notice("weread diag: review/list rejected the session")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "review/list book=\(bookId) 登录态被拒绝，等待会话恢复"
            )
            return result
        } catch {
            result.failed = true
            log.notice(
                "weread diag: review/list failed: \(String(describing: error), privacy: .public)"
            )
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "review/list book=\(bookId) 失败: \(error.localizedDescription)"
            )
            return result
        }
    }

    /// 拉取「我的想法」，给编辑入口定位 `reviewId`。
    ///
    /// 复用 `fetchThoughts`（与笔记合并同一套参数：`listMode=3` + 桌面 UA）。
    /// 返回 `nil` 表示请求失败或登录态被拒，调用方不能把它当成「服务端没有
    /// 这条想法」，否则会把编辑误降级成新建、在官方端留下重复想法。
    func ownReviews(bookId: String, cookie: String) async -> [WereadOwnReview]? {
        guard !bookId.isEmpty, !cookie.isEmpty else { return nil }
        let fetch = await fetchThoughts(bookId: bookId, cookie: cookie)
        if fetch.failed || fetch.authRejected { return nil }
        return fetch.thoughts
            .filter { !$0.id.hasPrefix("thought-") }
            .map {
                WereadOwnReview(
                    reviewId: $0.id,
                    chapterUid: $0.chapterUid,
                    range: $0.range,
                    abstract: $0.abstract,
                    content: $0.content
                )
            }
    }

    // MARK: - 诊断专用：笔记接口参数对照（仅诊断页手动触发）

    /// 从诊断页手动触发：用当前 cookie 对最近阅读的书打多组笔记接口参数，
    /// 把每组的 HTTP 状态 / 字节数 / 解析条数记进通用诊断报告，用于坐实
    /// 「云端笔记拉不下来」到底卡在哪一组参数 / 哪个 UA。
    /// 只读：不改本地状态、不写服务端。正常阅读流程不调用。
    func diagnoseNoteEndpoints(cookie: String, bookIdOverride: String? = nil) async {
        guard !cookie.isEmpty else {
            FlareDiagnostics.shared.record(
                .weread, "ERR", "笔记接口对照：无登录 cookie，请先在微读登录"
            )
            return
        }
        let books = (try? await shelf(cookie: cookie)) ?? []
        var targets: [(id: String, title: String)] = []
        if let override = bookIdOverride, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let id = override.trimmingCharacters(in: .whitespacesAndNewlines)
            targets.append((id, books.first { $0.id == id }?.title ?? "指定书"))
        } else {
            targets = Array(
                books.sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(2)
                    .map { (id: $0.id, title: $0.title) }
            )
        }
        guard !targets.isEmpty else {
            FlareDiagnostics.shared.record(
                .weread, "ERR", "笔记接口对照：书架为空，无法选书"
            )
            return
        }
        for target in targets {
            await diagnoseOneBook(bookId: target.id, title: target.title, cookie: cookie)
        }
    }

    private func diagnoseOneBook(bookId: String, title: String, cookie: String) async {
        FlareDiagnostics.shared.record(
            .weread, "STATE",
            "=== 笔记接口对照开始 book=\(bookId) 《\(title)》（仅诊断，非正常拉取）==="
        )
        let vid = cookieValue(named: "wr_vid", in: cookie)
        let vidItems = vid.map { [URLQueryItem(name: "userVid", value: $0)] } ?? []

        // bookmarklist：wereadx / Flare 都只用 bookId；另外试 syncKey 的两种大小写。
        let bmVariants: [(String, [URLQueryItem])] = [
            ("仅bookId", [URLQueryItem(name: "bookId", value: bookId)]),
            (
                "+syncKey",
                [URLQueryItem(name: "bookId", value: bookId), URLQueryItem(name: "syncKey", value: "0")]
            ),
            (
                "+synckey",
                [URLQueryItem(name: "bookId", value: bookId), URLQueryItem(name: "synckey", value: "0")]
            ),
        ]
        for (label, items) in bmVariants {
            await probeNote(
                api: "bookmarklist", label: label, path: "/web/book/bookmarklist",
                items: items, cookie: cookie, desktopUA: false
            ) { json in
                let updated = (json["updated"] as? [[String: Any]])?.count ?? 0
                let keys = json.keys.sorted().joined(separator: ",")
                return "updated=\(updated) keys={\(keys)}"
            }
        }

        // review/list：Flare 现用参数 / 官方 reader 参数 / wereadx 极简 / 官方参数+桌面 UA。
        let rvFlare: [URLQueryItem] = [
            URLQueryItem(name: "bookId", value: bookId),
            URLQueryItem(name: "listType", value: "11"),
            URLQueryItem(name: "maxIdx", value: "0"),
            URLQueryItem(name: "count", value: "0"),
            URLQueryItem(name: "listMode", value: "2"),
            URLQueryItem(name: "mine", value: "1"),
            URLQueryItem(name: "synckey", value: "0"),
        ] + vidItems
        let rvOfficial: [URLQueryItem] = [
            URLQueryItem(name: "bookId", value: bookId),
            URLQueryItem(name: "listType", value: "11"),
            URLQueryItem(name: "listMode", value: "3"),
            URLQueryItem(name: "syncKey", value: "0"),
            URLQueryItem(name: "mine", value: "1"),
        ] + vidItems
        let rvMinimal: [URLQueryItem] = [
            URLQueryItem(name: "bookId", value: bookId),
            URLQueryItem(name: "listType", value: "11"),
            URLQueryItem(name: "mine", value: "1"),
        ]
        let rvVariants: [(String, [URLQueryItem], Bool)] = [
            ("Flare现用", rvFlare, false),
            ("官方reader", rvOfficial, false),
            ("wereadx极简", rvMinimal, false),
            ("官方reader+桌面UA", rvOfficial, true),
        ]
        for (label, items, desktop) in rvVariants {
            await probeNote(
                api: "review/list", label: label, path: "/web/review/list",
                items: items, cookie: cookie, desktopUA: desktop
            ) { json in
                let reviews = (json["reviews"] as? [[String: Any]])?.count ?? 0
                let total = self.intValue(json["totalCount"]) ?? -1
                let err = self.intValue(json["errCode"]) ?? self.intValue(json["errcode"]) ?? 0
                return "reviews=\(reviews) total=\(total) err=\(err)"
            }
        }
        FlareDiagnostics.shared.record(
            .weread, "STATE", "=== 笔记接口对照结束 book=\(bookId) ==="
        )
    }

    private func probeNote(
        api: String, label: String, path: String,
        items: [URLQueryItem], cookie: String, desktopUA: Bool,
        summarize: ([String: Any]) -> String
    ) async {
        var components = URLComponents(string: "\(base)\(path)")
        components?.queryItems = items
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if desktopUA {
            request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let query = url.query ?? ""
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let head = String(decoding: data.prefix(140), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            let summary = (try? parseObject(data)).map(summarize) ?? "非JSON"
            FlareDiagnostics.shared.record(
                .weread, "PROBE",
                "对照[\(label)\(desktopUA ? "/桌面UA" : "")] \(api)?\(query) → \(status) · \(data.count)B · \(summary) · head=\(head)"
            )
        } catch {
            FlareDiagnostics.shared.record(
                .weread, "ERR", "对照[\(label)] \(api) → 失败 \(error.localizedDescription)"
            )
        }
    }

    // MARK: - 写入服务端笔记

    /// 新增划线要带的书籍版本号，来自 `/web/book/info` 的 `bookInfo.version`。
    ///
    /// 写想法走 `/web/review/add` 时网页并不带这个字段（选区想法路径），
    /// 所以这里只缓存划线需要的版本号。
    private struct BookVersions {
        /// 划线接口的 `bookVersion`。
        let version: Int?
    }

    /// 取划线接口需要的书籍版本号。
    ///
    /// 失败返回 nil，不抛错：上传只是本地保存之后的尽力而为。
    private func bookVersions(bookId: String, cookie: String) async -> BookVersions? {
        guard !bookId.isEmpty, !cookie.isEmpty else { return nil }
        if let cached = cachedBookVersion(for: bookId) { return cached }

        var components = URLComponents(string: "\(base)/web/book/info")
        components?.queryItems = [URLQueryItem(name: "bookId", value: bookId)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let payload = json["data"] as? [String: Any] ?? json
            let info = payload["bookInfo"] as? [String: Any] ?? payload
            let versions = BookVersions(
                version: intValue(info["version"]) ?? intValue(payload["version"])
            )
            guard versions.version != nil else {
                Self.screenDiag("book/info book=\(bookId) 无 version 字段")
                FlareDiagnostics.shared.record(
                    .weread,
                    "ERR",
                    "book/info book=\(bookId) 无 version 字段"
                )
                return nil
            }
            storeBookVersion(versions, for: bookId)
            return versions
        } catch {
            Self.screenDiag("book/info book=\(bookId) 取版本失败: \(error.localizedDescription)")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "book/info book=\(bookId) 取版本失败: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 新增一条划线：`POST /web/book/addBookmark`。
    ///
    /// 对照微读网页 `9.c00d47c2.js` 的 `addBookmark`：payload 为
    /// `bookId / chapterUid / chapterIdx / bookVersion / type / style /
    /// colorStyle / range / markText`，其中 `markText` 上传前要 base64。
    /// `style` 0=直线、1=马克笔、2=波浪线；`colorStyle` 5 是网页默认黄色。
    ///
    /// 官方写接口调用链（`fetchAddBookmark` → `_0x472748` 统一封装）不显式带
    /// `s`；不要照正文接口自行补签名。
    ///
    /// 成功时 `data.bookmarkId` 必须是非空数组。失败只记诊断并返回 false，
    /// 不抛错 —— 本地笔记已经保存，上传失败不能让用户丢笔记。
    func addBookmark(
        bookId: String,
        chapterUid: Int,
        chapterIdx: Int,
        bookVersion: Int,
        range: String,
        markText: String,
        style: Int = 1,
        colorStyle: Int = 5,
        cookie: String
    ) async -> Bool {
        guard !bookId.isEmpty, !range.isEmpty, !markText.isEmpty, !cookie.isEmpty else {
            let line =
                "addBookmark 跳过参数不完整 book=\(bookId) chapter=\(chapterUid) " +
                "idx=\(chapterIdx) ver=\(bookVersion) rangeLen=\(range.count) " +
                "markLen=\(markText.count) cookieEmpty=\(cookie.isEmpty)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        let context =
            "book=\(bookId) chapter=\(chapterUid) idx=\(chapterIdx) " +
            "ver=\(bookVersion) rangeLen=\(range.count) markLen=\(markText.count)"
        Self.screenDiag("addBookmark 请求 \(context)")
        var request = URLRequest(url: URL(string: "\(base)/web/book/addBookmark")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "bookId": bookId,
            "chapterUid": chapterUid,
            "chapterIdx": chapterIdx,
            "bookVersion": bookVersion,
            "type": 1,
            "style": style,
            "colorStyle": colorStyle,
            "range": range,
            "markText": Data(markText.utf8).base64EncodedString(),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let data = try await send(request)
            let json = try parseObject(data)
            if let code = intValue(json["errCode"]) ?? intValue(json["errcode"]), code != 0 {
                let message =
                    (json["errMsg"] as? String)
                    ?? (json["errmsg"] as? String)
                    ?? "请求失败"
                let container = json["data"] as? [String: Any] ?? json
                let succ = intValue(json["succ"]) ?? intValue(container["succ"]) ?? -1
                let busy =
                    intValue(json["isFetching"])
                    ?? intValue(container["isFetching"])
                    ?? 0
                let detail =
                    "errCode=\(code) succ=\(succ) isFetching=\(busy) msg=\(message)"
                let line = "addBookmark \(context) FAIL \(detail)"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let container = json["data"] as? [String: Any] ?? json
            if let id = firstIdentifier(container["bookmarkId"]) {
                Self.screenDiag("addBookmark \(context) OK id=\(id)")
                return true
            }
            let code = intValue(json["errCode"]) ?? intValue(json["errcode"]) ?? 0
            let succ = intValue(json["succ"]) ?? intValue(container["succ"]) ?? -1
            let busy =
                intValue(json["isFetching"])
                ?? intValue(container["isFetching"])
                ?? 0
            let line =
                "addBookmark \(context) FAIL 未返回 bookmarkId " +
                "errCode=\(code) succ=\(succ) isFetching=\(busy)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        } catch {
            let line =
                "addBookmark \(context) FAIL 请求异常: \(error.localizedDescription)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
    }

    /// 新增一条想法：`POST /web/review/add`。
    ///
    /// 对照微读网页 `9.c00d47c2.js` 选区写想法（`getRangeFromObjs(...).toString()`）：
    /// `range` 和划线一样是 `start-end` 的 0 基文本偏移，不是整页浮层那种
    /// 1 基单值；读侧 `formatRange(review.range)` 也按 `start-end` 拆。
    /// `abstract` 是选中的原文。成功时 `data.reviewId` 是非空数组。
    /// 网页 reducer 的默认 payload 带 `bookVersion: 0`，选区想法不传真实
    /// 版本号，这里保持一致。失败同样只记诊断，不抛错。
    /// 官方 `/web/review/add` 调用点也不显式带 `s`，不要自行补签名。
    func addReview(
        bookId: String,
        chapterUid: Int,
        range: String,
        content: String,
        abstract: String,
        cookie: String
    ) async -> Bool {
        guard !bookId.isEmpty, !range.isEmpty, !content.isEmpty, !cookie.isEmpty else {
            let line =
                "addReview 跳过参数不完整 book=\(bookId) chapter=\(chapterUid) " +
                "rangeLen=\(range.count) contentLen=\(content.count) " +
                "abstractLen=\(abstract.count) cookieEmpty=\(cookie.isEmpty)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        let context =
            "book=\(bookId) chapter=\(chapterUid) rangeLen=\(range.count) " +
            "contentLen=\(content.count) abstractLen=\(abstract.count)"
        Self.screenDiag("addReview 请求 \(context)")
        var request = URLRequest(url: URL(string: "\(base)/web/review/add")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "type": 1,
            "bookId": bookId,
            "chapterUid": chapterUid,
            "bookVersion": 0,
            "range": range,
            "content": content,
            "abstract": abstract,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let data = try await send(request)
            let json = try parseObject(data)
            if let code = intValue(json["errCode"]) ?? intValue(json["errcode"]), code != 0 {
                let message =
                    (json["errMsg"] as? String)
                    ?? (json["errmsg"] as? String)
                    ?? "请求失败"
                let container = json["data"] as? [String: Any] ?? json
                let succ = intValue(json["succ"]) ?? intValue(container["succ"]) ?? -1
                let busy =
                    intValue(json["isFetching"])
                    ?? intValue(container["isFetching"])
                    ?? 0
                let detail =
                    "errCode=\(code) succ=\(succ) isFetching=\(busy) msg=\(message)"
                let line = "addReview \(context) FAIL \(detail)"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let container = json["data"] as? [String: Any] ?? json
            if let id = firstIdentifier(container["reviewId"]) {
                Self.screenDiag("addReview \(context) OK id=\(id)")
                return true
            }
            let code = intValue(json["errCode"]) ?? intValue(json["errcode"]) ?? 0
            let succ = intValue(json["succ"]) ?? intValue(container["succ"]) ?? -1
            let busy =
                intValue(json["isFetching"])
                ?? intValue(container["isFetching"])
                ?? 0
            let line =
                "addReview \(context) FAIL 未返回 reviewId " +
                "errCode=\(code) succ=\(succ) isFetching=\(busy)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        } catch {
            let line = "addReview \(context) FAIL 请求异常: \(error.localizedDescription)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
    }

    /// 修改一条已发布的想法：`POST /web/review/edit`。
    ///
    /// 网页端路由实测：`/web/review/useredit` 是 404，`/web/review/edit`
    /// 存在（未登录回 `errCode -2010`）。不要和 E-Ink / 手机端的
    /// `i.weread.qq.com/review/useredit`、`/review/edit`（后者是「简单编辑
    /// 书评基本信息」）混用，那两套需要另一套鉴权和字段。
    ///
    /// 请求体照官方阅读器 webpack action `FETCH_BOOK_REVIEW_EDIT` 的形状
    /// （`js/2.*.js` 里直接 `$http('/web/review/edit', payload)`，payload 由
    /// 编辑页组出来）：`reviewId` + `content` + `htmlContent`（编辑页还会带
    /// `newRatingLevel` / `isPrivate` / `friendship` / `notVisibleToFriends`，
    /// 这些是「点评本书」的评分和可见性设置，这里故意不发，避免把用户已有
    /// 的设置覆盖成默认值）。
    /// 官方编辑页以回包 `data.reviewId` 非空为成功判据，这里保持一致；
    /// 只有 `errCode == 0` 但没回 reviewId 时按失败处理，不谎报已同步。
    /// 失败只记诊断并返回 false，草稿留在输入框里让用户重试。
    func editReview(reviewId: String, content: String, cookie: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewId.isEmpty, !trimmed.isEmpty, !cookie.isEmpty else {
            let line =
                "editReview 跳过参数不完整 reviewIdEmpty=\(reviewId.isEmpty) " +
                "contentLen=\(trimmed.count) cookieEmpty=\(cookie.isEmpty)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        let context = "reviewId=\(reviewId) contentLen=\(trimmed.count)"
        Self.screenDiag("editReview 请求 \(context)")
        var request = URLRequest(url: URL(string: "\(base)/web/review/edit")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "reviewId": reviewId,
            "content": trimmed,
            "htmlContent": trimmed,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let container = json["data"] as? [String: Any] ?? json
            let savedId =
                firstIdentifier(container["reviewId"])
                ?? firstIdentifier(json["reviewId"])
            guard let savedId else {
                let line = "editReview FAIL \(context) 未返回 reviewId"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let line = "editReview OK \(context) id=\(savedId)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "RES", line)
            return true
        } catch {
            let line = "editReview FAIL \(context) \(error.localizedDescription)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
    }

    /// 删除一条已发布的想法：`POST /web/review/delete`。
    ///
    /// 2026-11-25 未登录探测确认路由存在：`/web/review/delete` 回
    /// `errCode -2010`（和已知存在的 `/web/review/edit` 一致），而
    /// `/web/review/del`、`/web/review/remove` 都是 HTTP 404。
    /// 请求体只带 `reviewId`。
    ///
    /// 成功判据：HTTP 2xx + `errCode == 0`/缺省；回包显式带 `succ` 时必须为 1。
    /// 删除会立刻作用到云端，调用方拿到 true 后必须重新拉 `bookmarklist`
    /// 核对条目确实消失，不能只凭 HTTP 200 报「已同步删除」。
    func deleteReview(reviewId: String, cookie: String) async -> Bool {
        let trimmed = reviewId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cookie.isEmpty else {
            let line =
                "deleteReview 跳过参数不完整 reviewIdEmpty=\(trimmed.isEmpty) " +
                "cookieEmpty=\(cookie.isEmpty)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        let context = "reviewId=\(trimmed)"
        Self.screenDiag("deleteReview 请求 \(context)")
        var request = URLRequest(url: URL(string: "\(base)/web/review/delete")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["reviewId": trimmed])

        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let container = json["data"] as? [String: Any] ?? json
            if let succ = intValue(json["succ"]) ?? intValue(container["succ"]), succ != 1 {
                let line = "deleteReview FAIL \(context) succ=\(succ)"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let line = "deleteReview OK \(context)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "RES", line)
            return true
        } catch {
            let line = "deleteReview FAIL \(context) \(error.localizedDescription)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
    }

    /// 删除一条云端划线：`POST /web/book/removeBookmark`。
    ///
    /// 2026-11-25 未登录探测确认路由存在：`/web/book/removeBookmark` 回
    /// `errCode -2010`，而 `deleteBookmark` / `delBookmark` 都是 HTTP 404。
    /// 请求体只带 `bookmarkId`；成功判据与 `deleteReview` 相同，调用方
    /// 删除后要重新拉列表核对。
    func removeBookmark(bookmarkId: String, cookie: String) async -> Bool {
        let trimmed = bookmarkId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cookie.isEmpty else {
            let line =
                "removeBookmark 跳过参数不完整 bookmarkIdEmpty=\(trimmed.isEmpty) " +
                "cookieEmpty=\(cookie.isEmpty)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        let context = "bookmarkId=\(trimmed)"
        Self.screenDiag("removeBookmark 请求 \(context)")
        var request = URLRequest(url: URL(string: "\(base)/web/book/removeBookmark")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.readerUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["bookmarkId": trimmed])

        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let container = json["data"] as? [String: Any] ?? json
            if let succ = intValue(json["succ"]) ?? intValue(container["succ"]), succ != 1 {
                let line = "removeBookmark FAIL \(context) succ=\(succ)"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let line = "removeBookmark OK \(context)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "RES", line)
            return true
        } catch {
            let line = "removeBookmark FAIL \(context) \(error.localizedDescription)"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
    }

    /// 把一条本地划线 / 想法同步到微读服务端。
    ///
    /// 调用方已经完成本地保存，这里只做尽力上传：没有 range、没登录、
    /// 取不到版本号或接口失败都只记诊断，绝不回滚本地笔记。
    ///
    /// 划线（note 为空）只建 bookmark；写想法只建 review。网页写想法时
    /// 不会再调 `addBookmark`，服务端用 review 自带的 range 显示高亮；
    /// 两边都建会在官方端出现同一段文字的两条笔记。
    @discardableResult
    func uploadHighlight(
        bookId: String,
        chapterUid: Int,
        chapterIdx: Int,
        range: String,
        markText: String,
        note: String,
        cookie: String
    ) async -> Bool {
        let context =
            "book=\(bookId) chapter=\(chapterUid) idx=\(chapterIdx) " +
            "rangeLen=\(range.count) markLen=\(markText.count)"
        guard !cookie.isEmpty else {
            let line = "上传笔记跳过 \(context) 未登录"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }
        guard !range.isEmpty, !markText.isEmpty else {
            let line = "上传笔记跳过 \(context) 缺少 range/markText"
            Self.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "ERR", line)
            return false
        }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let version = await bookVersions(bookId: bookId, cookie: cookie)?.version else {
                let line = "上传划线跳过 \(context) 未取到 bookVersion"
                Self.screenDiag(line)
                FlareDiagnostics.shared.record(.weread, "ERR", line)
                return false
            }
            let ok = await addBookmark(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterIdx: chapterIdx,
                bookVersion: version,
                range: range,
                markText: markText,
                cookie: cookie
            )
            let line = "上传划线 \(ok ? "OK" : "FAIL") \(context) ver=\(version)"
            Self.screenDiag(line)
            if !ok {
                FlareDiagnostics.shared.record(.weread, "ERR", line)
            }
            return ok
        }

        let ok = await addReview(
            bookId: bookId,
            chapterUid: chapterUid,
            range: range,
            content: trimmed,
            abstract: markText,
            cookie: cookie
        )
        let line = "上传想法 \(ok ? "OK" : "FAIL") \(context) noteLen=\(trimmed.count)"
        Self.screenDiag(line)
        if !ok {
            FlareDiagnostics.shared.record(.weread, "ERR", line)
        }
        return ok
    }

    /// 服务端标识字段可能是数组，也可能直接是字符串。
    private func firstIdentifier(_ value: Any?) -> String? {
        if let list = value as? [Any] {
            for item in list {
                let id =
                    (item as? String)
                    ?? (item as? NSNumber)?.stringValue
                    ?? ""
                if !id.isEmpty { return id }
            }
            return nil
        }
        if let id = value as? String, !id.isEmpty { return id }
        return nil
    }

    // MARK: - 网页阅读器地址

    /// 网页阅读器地址：`/web/reader/{_e(bookId)}k{_e(chapterUid)}`。
    ///
    /// `_e()` 就是 `WereadCrypto.calcHash`，和正文接口的 `b`/`c` 同一个函数，
    /// 第三方实现（KOReader 插件、weread-exporter）都按这个公式直接拼，
    /// 不需要去网页书架抄 DOM。以前「自己拼一定 404」的结论是错的。
    func readerURL(
        bookId: String,
        chapterUid: Int? = nil,
        jumpType: String? = nil,
        offset: Int? = nil
    ) -> URL? {
        guard !bookId.isEmpty else { return nil }
        var path = "/web/reader/" + WereadCrypto.calcHash(bookId)
        // 对齐官方 `readerURL`：`chapterUid` 为 0 时不拼章节段，但仍会
        // 带上 `jumpType` / `offset`。切换接口回包允许 `chapterUid == 0`，
        // 这时交给阅读器按默认位置打开，不能在本机改写语义。
        if let chapterUid, chapterUid > 0 {
            path += "k" + WereadCrypto.calcHash(String(chapterUid))
        }
        var components = URLComponents(string: base + path)
        var query: [URLQueryItem] = []
        if let jumpType, !jumpType.isEmpty {
            query.append(URLQueryItem(name: "jumpType", value: jumpType))
        }
        if let offset {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        components?.queryItems = query.isEmpty ? nil : query
        return components?.url
    }

    func readerURLString(
        bookId: String,
        chapterUid: Int? = nil,
        jumpType: String? = nil,
        offset: Int? = nil
    ) -> String? {
        readerURL(
            bookId: bookId,
            chapterUid: chapterUid,
            jumpType: jumpType,
            offset: offset
        )?.absoluteString
    }

    /// 这本书是否已在书架数据里标记为 PDF。
    ///
    /// 书架刷新会先把 `shelf/sync` 的原始 `books[]` 交给 `parseBook`，所以用户
    /// 点进书时这里已经有结果，不需要再发一次详情请求。
    func isPDFBook(id: String) -> Bool {
        guard !id.isEmpty else { return false }
        pdfLock.lock()
        defer { pdfLock.unlock() }
        if let format = bookFormatCache[id] {
            return format.current == .pdf
        }
        return pdfBookIDs.contains(id)
    }

    /// 只读已缓存的官方格式信息。
    ///
    /// 界面首开时先用它判断要不要等 `/web/book/info`：普通电子书没有
    /// 切换入口，不该为一个可选功能多阻塞一次网络往返。
    func bookFormatIfCached(bookId: String) -> WereadBookFormatInfo? {
        guard !bookId.isEmpty else { return nil }
        return cachedBookFormat(for: bookId)
    }

    /// 从书架缓存或 `/web/book/info` 取官方格式信息。
    ///
    /// 书架有 `otherType` 时直接命中缓存；没有时补一次详情请求。拿不到
    /// 就返回 nil，界面按原有 PDF 标记兜底，绝不本地猜测可转换。
    func bookFormat(bookId: String, cookie: String) async -> WereadBookFormatInfo? {
        guard !bookId.isEmpty else { return nil }
        if let cached = cachedBookFormat(for: bookId) { return cached }
        guard !cookie.isEmpty else { return nil }

        var components = URLComponents(string: "\(base)/web/book/info")
        components?.queryItems = [URLQueryItem(name: "bookId", value: bookId)]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let payload = json["data"] as? [String: Any] ?? json
            guard let info = bookFormatInfo(from: payload) else { return nil }
            storeBookFormat(info, for: bookId)
            Self.screenDiag(
                "book/info book=\(bookId) format=\(info.current.rawValue) " +
                "other=\(info.hasOtherType)"
            )
            return info
        } catch {
            Self.screenDiag(
                "book/info book=\(bookId) 取格式失败: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// 官方动态格式切换：`POST /web/trans/pdfepub`。
    ///
    /// 只对服务端提供 `otherType` 的书有效；纯 PDF 没有这个入口。成功回包
    /// 必须带目标 `chapterUid`，否则不能假装切换成功。
    func switchBookFormat(
        bookId: String,
        to target: WereadBookFormatKind,
        chapterUid: Int,
        offset: Int,
        cookie: String
    ) async throws -> WereadFormatSwitchResult {
        guard !bookId.isEmpty, !cookie.isEmpty,
              let transFormat = target.transFormat
        else {
            throw WereadError.server("切换参数不完整")
        }
        var request = URLRequest(url: URL(string: "\(base)/web/trans/pdfepub")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "cbid": bookId,
            "transFormat": transFormat,
            "uid": chapterUid,
            "offset": max(offset, 0),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await send(request)
        let json = try parseObject(data)
        try checkError(json)
        let container = json["data"] as? [String: Any] ?? json
        try checkError(container)
        let resultUid =
            intValue(container["chapterUid"])
            ?? intValue(container["chapter_uid"])
            ?? intValue(json["chapterUid"])
        guard let resultUid, resultUid >= 0 else {
            throw WereadError.server("官方未返回目标章节，可能这本书没有可切换的电子书版")
        }
        let resultOffset =
            intValue(container["chapterOffset"])
            ?? intValue(container["chapter_offset"])
            ?? intValue(container["offset"])
            ?? intValue(json["chapterOffset"])
            ?? 0

        if let current = cachedBookFormat(for: bookId) {
            storeBookFormat(current.switching(to: target), for: bookId)
        } else {
            let info = WereadBookFormatInfo(
                current: target,
                alternate: target.opposite,
                hasOtherType: true
            )
            storeBookFormat(info, for: bookId)
        }
        Self.screenDiag(
            "trans/pdfepub book=\(bookId) to=\(transFormat) " +
            "chapter=\(resultUid) offset=\(resultOffset)"
        )
        return WereadFormatSwitchResult(
            chapterUid: resultUid,
            chapterOffset: max(resultOffset, 0)
        )
    }

    /// 公众号（`MP_WXS_` 开头的 bookId）走另一个阅读器路径。
    func mpReaderURL(bookId: String) -> URL? {
        guard !bookId.isEmpty else { return nil }
        return URL(string: base + "/web/mp/reader/" + WereadCrypto.calcHash(bookId))
    }

    // MARK: - 单个正文分片

    /// 发一个正文分片请求。
    ///
    /// `beacon` 是这一章阅读器页面的会话信标。有就用真实 `ps`/`pc` 并带上
    /// `sc = 1`（整章）；没有就发和 reader-session 改动之前完全一样的请求：
    /// 固定 `ps`/`pc`，签名和 body 里都没有 `sc` / `prevChapter`。
    /// 这条回退路径是已购书架书此前一直能取到正文的关键，不能带新字段。
    private func fragment(
        _ path: String,
        bookId: String,
        chapterUid: String,
        st: Int,
        cookie: String,
        beacon: WereadReaderSession?
    ) async throws -> String {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        // 网页端每次都换一个随机数，跟着换，别让服务端看出是固定脚本。
        let random = Int(pow(Double(Int.random(in: 0..<10_000)), 2))
        let timestamp = Int(Date().timeIntervalSince1970)
        let hashedBook = WereadCrypto.calcHash(bookId)
        let hashedChapter = WereadCrypto.calcHash(chapterUid)

        // ps：优先用阅读器页面给的本章信标；没有就用写死值兜底。
        // pc：有信标时用页面给的 pclts，没有就 `_e(ct)` 现算；没有信标时
        // 必须用旧版的固定串 —— 换成 `_e(ct)` 后服务端会回 `{}`。
        let uid = Int(chapterUid) ?? 0
        let livePs = beacon?.ps(for: uid)
        let hasBeacon = livePs != nil
        let ps = livePs ?? Self.placeholderPs
        let pc = hasBeacon
            ? (beacon?.pc(for: timestamp) ?? WereadCrypto.calcHash(String(timestamp)))
            : Self.placeholderPc

        var fields: [(String, String)] = [
            ("b", hashedBook),
            ("c", hashedChapter),
            ("r", String(random)),
            ("st", String(st)),
            ("ct", String(timestamp)),
            ("ps", ps),
            ("pc", pc),
        ]

        var payload: [String: Any] = [
            "b": hashedBook,
            "c": hashedChapter,
            "r": random,
            "st": st,
            "ct": timestamp,
            "ps": ps,
            "pc": pc,
        ]
        if hasBeacon {
            // `sc` / `prevChapter` 只在带阅读器会话时发。旧版请求没有这两项，
            // 补上去会让服务端按另一套字段验签而回 `{}`。
            fields.append(("prevChapter", "false"))
            fields.append(("sc", "1"))
            payload["prevChapter"] = false
            payload["sc"] = 1
        } else {
            log.info(
                "weread: \(path, privacy: .public) no session beacon, using legacy ps/pc without sc"
            )
        }
        payload["s"] = WereadCrypto.sign(fields)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await send(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WereadError.decodeFailed
        }
        // 响应可能是 JSON 字符串（带引号），也可能是裸文本。
        let unwrapped: String
        if text.hasPrefix("\""),
           let value = try? JSONSerialization.jsonObject(with: data) as? String {
            unwrapped = value
        } else {
            unwrapped = text
        }
        let shard = WereadCrypto.chk(unwrapped)
        log.notice(
            "weread diag: shard \(path, privacy: .public) raw=\(unwrapped.count, privacy: .public) decoded=\(shard.count, privacy: .public) rawHead=\(String(unwrapped.prefix(80)).replacingOccurrences(of: "\n", with: " "), privacy: .public)"
        )
        return shard
    }

    /// 拿不到会话信标时的兜底 ps（沿用历史上能过签的占位串）。
    private static let placeholderPs = "a2b325707a19e580g0186a2"
    /// 旧版（reader-session 改动之前）一直随 `placeholderPs` 一起发的固定 pc。
    private static let placeholderPc = "430321207a19e581g013ab0"

    /// `sg = sha256("\(ts)\(rn)\(readerToken)")`，输出小写十六进制。
    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 官方 reader JS 的 `appId`：UA 按空格切前 12 段、每段长度取个位，
    /// 再对整串做 `num = (131 * num + charCode) & 0x7fffffff`，
    /// 最后拼十进制（官方 `'wb'+prefix+'h'+num`，Number 隐式转十进制）。
    private static func readAppId(for userAgent: String) -> String {
        let parts = userAgent.split(separator: " ", omittingEmptySubsequences: false)
        var prefix = ""
        for part in parts.prefix(12) {
            prefix += String(part.count % 10)
        }
        var number: Int64 = 0
        for unit in userAgent.utf16 {
            number = (131 * number + Int64(unit)) & 0x7fff_ffff
        }
        return "wb\(prefix)h\(number)"
    }

    // MARK: - 工具

    // MARK: - 屏幕诊断（无需 Mac / 系统日志，直接在报错页显示）
    // Windows 上 syslog_relay 抓不到 App 自定义 subsystem 的 os_log，
    // 所以把关键请求的状态码和返回体开头同时攒到这里，报错页读出来给用户截图。
    private static let diagLock = NSLock()
    private static var diagLines: [String] = []

    /// 追加一行屏幕诊断（最多留 40 行，自动去掉最旧的）。
    /// 同时写入全局诊断中心，供设置页一键导出的完整报告使用。
    static func screenDiag(_ line: String) {
        diagLock.lock()
        defer { diagLock.unlock() }
        diagLines.append(line)
        if diagLines.count > 40 { diagLines.removeFirst(diagLines.count - 40) }
        FlareDiagnostics.shared.record(.weread, "STATE", line)
    }

    /// 报错页读取当前诊断快照。
    static func takeScreenDiag() -> String {
        diagLock.lock()
        defer { diagLock.unlock() }
        return diagLines.joined(separator: "\n")
    }

    /// 开始一次新的诊断会话（点重试时清掉上一轮）。
    static func resetScreenDiag() {
        diagLock.lock()
        defer { diagLock.unlock() }
        diagLines.removeAll()
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try await sendWithStatus(request).0
    }

    /// `redactBody` 用于翻译相关接口：回包可能有译文片段，
    /// 屏幕诊断只记状态码/字节数，不把响应体开头截进日志。
    private func sendWithStatus(
        _ request: URLRequest,
        redactBody: Bool = false
    ) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let path = request.url?.path ?? ""
        var status = -1
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        // 所有微读请求都记录到屏幕诊断（章节目录、正文分片、阅读器页面），
        // 只截前 180 字节、不含 cookie，避免泄露登录态。
        let head = redactBody
            ? "<响应体可能含译文，已省略>"
            : String(decoding: data.prefix(180), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
        Self.screenDiag("\(path) → \(status) · \(data.count)B · \(head)")
        FlareDiagnostics.shared.record(
            .weread,
            status >= 400 ? "ERR" : "RES",
            "\(request.httpMethod ?? "?") \(path) → \(status) · \(data.count)B · \(head)"
        )
        // 系统日志保留（有 Mac 时仍可用控制台读）。
        log.notice(
            "weread diag: path=\(path, privacy: .public) status=\(status, privacy: .public) bytes=\(data.count, privacy: .public) head=\(head, privacy: .public)"
        )
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WereadError.notLoggedIn
            }
            if !(200..<300).contains(http.statusCode) {
                throw WereadError.http(http.statusCode)
            }
        }
        return (data, status)
    }

    private func parseObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WereadError.decodeFailed
        }
        return json
    }

    private func checkError(_ json: [String: Any]) throws {
        // 微读不同接口的大小写不一致，两种都认。
        guard let code = intValue(json["errCode"]) ?? intValue(json["errcode"]), code != 0 else {
            return
        }
        let message =
            (json["errMsg"] as? String)
            ?? (json["errmsg"] as? String)
            ?? "请求失败"
        if code == -2010 || code == -2012 {
            throw WereadError.notLoggedIn
        }
        throw WereadError.server(message)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// 接口里的 `range` 有时是字符串、有时是数字，统一成去空白的字符串。
    private func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// `reviewId` / `bookmarkId` 可能是字符串、数字，个别回包是数组；统一取首个非空值。
    private func identifierString(_ value: Any?) -> String {
        let raw = firstIdentifier(value) ?? (value as? NSNumber)?.stringValue ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 `name=value; name2=value2` 形式的 Cookie 头里取单个值。
    private func cookieValue(named name: String, in header: String) -> String? {
        for part in header.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == name else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func parseBook(_ item: [String: Any]) -> WereadBook? {
        let bookId =
            (item["bookId"] as? String)
            ?? (item["bookId"] as? NSNumber)?.stringValue
        guard let bookId = bookId, !bookId.isEmpty else { return nil }
        rememberBookFormat(bookId: bookId, item: item)
        let percent = percentValue(item)
        let updated = stampValue(item)

        return WereadBook(
            id: bookId,
            title: item["title"] as? String ?? "",
            author: item["author"] as? String ?? "",
            cover: item["cover"] as? String,
            progress: min(max(percent, 0), 100),
            finished: (intValue(item["finishReading"]) ?? 0) == 1,
            updatedAt: updated
        )
    }

    private func rememberBookFormat(bookId: String, item: [String: Any]) {
        if let info = bookFormatInfo(from: item) {
            // 书架条目可能被裁剪过，没有 `otherType` 不代表详情接口也没有。
            // 已有官方详情缓存时不再用书架数据覆盖，尤其是用户刚切换过
            // 格式、书架数据仍是旧格式的时候。
            pdfLock.lock()
            let hasCached = bookFormatCache[bookId] != nil
            if !hasCached {
                if info.current == .pdf {
                    pdfBookIDs.insert(bookId)
                } else {
                    pdfBookIDs.remove(bookId)
                }
            }
            pdfLock.unlock()
            if info.canSwitch, !hasCached {
                storeBookFormat(info, for: bookId)
            }
            return
        }
        guard containsPDFMarker(item) else { return }
        pdfLock.lock()
        if bookFormatCache[bookId] == nil {
            pdfBookIDs.insert(bookId)
        }
        pdfLock.unlock()
    }

    private func cachedBookFormat(for bookId: String) -> WereadBookFormatInfo? {
        pdfLock.lock()
        defer { pdfLock.unlock() }
        return bookFormatCache[bookId]
    }

    private func storeBookFormat(_ info: WereadBookFormatInfo, for bookId: String) {
        pdfLock.lock()
        bookFormatCache[bookId] = info
        if info.current == .pdf {
            pdfBookIDs.insert(bookId)
        } else {
            pdfBookIDs.remove(bookId)
        }
        pdfLock.unlock()
    }

    /// 从书架条目或 `/web/book/info` 的 `bookInfo` 解析官方格式。
    ///
    /// `otherType` 可能是数组，也见过单个对象的写法；`showType` 为真时
    /// `otherType[0].type` 就是当前格式，否则它是可切换的另一格式。
    private func bookFormatInfo(from item: [String: Any]) -> WereadBookFormatInfo? {
        var info = item
        for key in ["bookInfo", "bookinfo"] {
            if let nested = item[key] as? [String: Any] {
                info = nested
                break
            }
        }

        var otherTypes: [[String: Any]] = []
        if let list = info["otherType"] as? [[String: Any]] {
            otherTypes = list
        } else if let single = info["otherType"] as? [String: Any] {
            otherTypes = [single]
        }
        let first = otherTypes.first
        let hasOtherType = !otherTypes.isEmpty
        let otherKind = formatKind(format: first?["type"], type: nil)
        let showOther = boolValue(first?["showType"]) ?? false
        // 官方 `actualTreatBookFormatAs`：`showType` 为真时当前格式取
        // `otherType[0].type`，否则取 `format`；`type == 11` 只作为
        // `format` 缺失时的 PDF 兜底。
        let declaredKind = formatKind(format: info["format"], type: info["type"])
        var current = declaredKind
        if hasOtherType, showOther, let otherKind {
            current = otherKind
        }

        // 当前格式必须能从 `format` / `type` / `showType` 确认。只有
        // `otherType` 而当前格式不明的书，不能据此猜测它是 PDF 或电子书。
        guard current != .unknown else { return nil }
        // 官方切换逻辑只发 `pdf` / `epub`，目标恒为当前格式的反面；
        // 没有 `otherType` 的书服务端不提供在线切换入口。
        let alternate: WereadBookFormatKind? = hasOtherType ? current.opposite : nil
        return WereadBookFormatInfo(
            current: current,
            alternate: alternate,
            hasOtherType: hasOtherType
        )
    }

    private func formatKind(format: Any?, type: Any?) -> WereadBookFormatKind {
        let rawFormat = stringValue(format).lowercased()
        if rawFormat == "pdf" {
            return .pdf
        }
        if rawFormat == "epub" {
            return .epub
        }
        if intValue(type) == 11 {
            return .pdf
        }
        return .unknown
    }

    /// 兼容书架偶尔把书信息包一层 `bookInfo` 的写法。
    private func containsPDFMarker(_ item: [String: Any]) -> Bool {
        if isPDFBookInfo(item) { return true }
        for key in ["bookInfo", "bookinfo"] {
            if let nested = item[key] as? [String: Any], isPDFBookInfo(nested) {
                return true
            }
        }
        return false
    }

    /// 对齐 wereadx `M278.actualTreatBookFormatAs` / `isPDFBookType`：
    /// `otherType[0].showType` 为真时以 `otherType[0].type` 为准，否则看
    /// `format`；`type == 11` 单独表示 PDF 书。
    private func isPDFBookInfo(_ info: [String: Any]) -> Bool {
        if let other = (info["otherType"] as? [[String: Any]])?.first,
           boolValue(other["showType"]) == true
        {
            // `showType` 为真时服务端以 `otherType[0].type` 覆盖 `format`，
            // 不能再拿原始 `type == 11` 兜底，否则可能把别的格式误判成 PDF。
            if let type = other["type"] as? String, !type.isEmpty {
                let lower = type.lowercased()
                return lower == "pdf" || lower == "11"
            }
            // 少数接口把 `otherType.type` 直接给成数字 11。
            return intValue(other["type"]) == 11
        }
        if let format = info["format"] as? String, format.lowercased() == "pdf" {
            return true
        }
        return intValue(info["type"]) == 11
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    /// 正文里大量 `<img src="data:...">` 占位图会把 HTML 撑到几 MB，
    /// 真正的图在 `data-src` 上，所以先扔掉占位 src 再把 data-src 提上来。
    ///
    /// 两条正则都要**限定在 `<img` 标签内部**：以前第二条是
    /// `(<img[^>]+?)data-src="`，只有前缀约束、没有右边界，
    /// 正文里只要出现一次 `data-src="`（代码块、文学引用、页面源码示例），
    /// 就会一路匹配到下一个 `<img` 并把中间整段正文吞掉 —— 也就是
    /// 「内容不对 / 少了一大截」。
    private func clean(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: "(<img\\b[^>]*?)\\ssrc=\"data:[^\"]*\"",
            with: "$1",
            options: .regularExpression
        )
        // 只有**还没有 src** 的 img 才把 data-src 提上来，避免出现两个 src、
        // 浏览器取到第一个而忽略直链的真实地址。
        result = result.replacingOccurrences(
            of: "(<img\\b(?:(?!\\ssrc=)[^>])*?)\\sdata-src=\"([^\"]*)\"",
            with: "$1 src=\"$2\"",
            options: .regularExpression
        )
        return result
    }
}

/// 同一个源 cookie 的续期请求合并成一次，避免 prefetch / 当前章
/// 同时过期时各发一遍 renewal，拿到不同结果后互相覆盖。
private actor WereadRenewalCoordinator {
    private var flights: [String: (id: UUID, task: Task<WereadRenewalOutcome, Never>)] = [:]

    func renew(
        cookie: String,
        operation: @escaping @Sendable () async -> WereadRenewalOutcome
    ) async -> WereadRenewalOutcome {
        if let flight = flights[cookie] {
            return await flight.task.value
        }
        let id = UUID()
        let task = Task { await operation() }
        flights[cookie] = (id, task)
        let result = await task.value
        if flights[cookie]?.id == id {
            flights[cookie] = nil
        }
        return result
    }
}

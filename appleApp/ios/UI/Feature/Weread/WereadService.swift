import Foundation
import os

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
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.info("weread: reader page HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else {
                log.info("weread: reader page not utf8")
                return nil
            }
            guard let parsed = WereadReaderSessionParser.session(from: html) else {
                log.info("weread: reader page has no session beacon")
                return nil
            }
            // 只解析出 token、没有 `psvts`/`pclts` 的页面没法拿来取正文，
            // 当没信标处理，让调用方直接走旧版请求。
            guard !parsed.isEmpty else {
                log.info("weread: reader page session beacon is empty")
                return nil
            }
            storeSession(parsed, for: cacheKey)
            return parsed
        } catch {
            log.info("weread: reader page fetch failed: \(String(describing: error), privacy: .public)")
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

    func shelf(cookie: String) async throws -> [WereadBook] {
        do {
            return try await fetchShelf(cookie: cookie)
        } catch WereadError.notLoggedIn {
            throw WereadAuthFailure.rejected(failedCookie: cookie)
        }
    }

    private func fetchShelf(cookie: String) async throws -> [WereadBook] {
        // `synckeys=0` 只给第一页，书架大的人会少一截（用户说的「没还原全」）。
        // 接口会在响应里回一个新的 synckey，带着它再要一页，直到没有新书。
        var result: [WereadBook] = []
        var seen = Set<String>()
        var syncKey = "0"
        var pages: [[String: Any]] = []
        for _ in 0..<4 {
            let url = URL(string: "\(base)/web/shelf/sync?synckeys=\(syncKey)&teenmode=0&album=1")!
            var request = URLRequest(url: url)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

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

    private func fetchChapters(bookId: String, cookie: String) async throws -> [WereadChapter] {
        var request = URLRequest(url: URL(string: "\(base)/web/book/publicchapterInfos")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["bookIds": [bookId]])

        let data = try await send(request)
        let json = try parseObject(data)
        try checkError(json)

        let entries = json["data"] as? [[String: Any]] ?? []
        let target = entries.first { ($0["bookId"] as? String) == bookId } ?? entries.first
        let updated = target?["updated"] as? [[String: Any]] ?? []

        return updated.compactMap { item in
            guard let uid = intValue(item["chapterUid"]) else { return nil }
            return WereadChapter(
                uid: uid,
                index: intValue(item["chapterIdx"]) ?? 0,
                title: item["title"] as? String ?? "",
                level: intValue(item["level"]) ?? 1,
                wordCount: intValue(item["wordCount"]) ?? 0
            )
        }
    }

    // MARK: - 正文

    /// 返回一章的 HTML。epub 书要拼 4 个分片，txt 书拼 2 个。
    ///
    /// 取正文的优先级（从「新」到「旧」）：
    /// 1. 阅读器页面信标可用 → 真实 `ps`/`pc` + `sc=1`；
    /// 2. 信标请求回 `{}` → 退回旧版「直接正文请求」：固定 `ps`/`pc`，
    ///    不带 `sc` / `prevChapter`。书架里的已购书走这条老路一直是通的，
    ///    reader-session 改动把这条回退路径漏掉了；
    /// 3. 直接请求也空 → 丢掉缓存信标、重抓一次页面，再试一次；
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

    /// 先按会话信标取正文，失败再退回旧版直接请求。
    ///
    /// 真机上的书架书（已购）以前直接带着固定 `ps`/`pc` 就能取到；
    /// 新版把固定参数换成了 `_e(ct)` 并追加 `prevChapter`，信标又不一定
    /// 抓得到，结果两边都不通。这里保证「信标失败 → 旧版请求」这条退路存在。
    private func fetchChapterWithFallback(
        bookId: String,
        chapterUid: Int,
        cookie: String
    ) async throws -> String {
        var beacon = await readerSession(bookId: bookId, chapterUid: chapterUid, cookie: cookie)
        // 只认能给出本章 ps 的信标；否则和没有一样。
        if beacon?.ps(for: chapterUid) == nil { beacon = nil }
        let usedSession = beacon != nil

        do {
            return try await fetchChapter(
                bookId: bookId,
                chapterUid: chapterUid,
                cookie: cookie,
                beacon: beacon
            )
        } catch WereadError.empty {
            guard usedSession else {
                // 第一遍已经是不依赖会话的旧版请求，先把信标刷新再试。
                return try await fetchWithRefreshedSession(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    previous: nil
                )
            }
            log.info("weread: content empty with reader session, retrying legacy direct request")
            do {
                return try await fetchChapter(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    beacon: nil
                )
            } catch WereadError.empty {
                return try await fetchWithRefreshedSession(
                    bookId: bookId,
                    chapterUid: chapterUid,
                    cookie: cookie,
                    previous: beacon
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

    // MARK: - 进度

    func progress(bookId: String, cookie: String) async throws -> WereadProgress? {
        let url = URL(string: "\(base)/web/book/getProgress?bookId=\(bookId)")!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let data = try await send(request)
        let json = try parseObject(data)
        // 没读过时接口会给 errCode，当作「没有进度」处理，不弹错误。
        if let code = intValue(json["errCode"]), code != 0 { return nil }

        guard let book = json["book"] as? [String: Any] else { return nil }
        return WereadProgress(
            chapterUid: intValue(book["chapterUid"]) ?? 0,
            chapterOffset: intValue(book["chapterOffset"]) ?? 0,
            percent: intValue(book["progress"]) ?? 0
        )
    }

    /// 上报阅读进度。失败不抛错 —— 进度丢一次不影响读书。
    ///
    /// 以前这里发 `ci/pc/ps` 三个假值（`pc`/`ps` 是别的设备的固定串），
    /// 接口能收下但不认，进度等于没同步。现在只发不依赖阅读器会话的字段：
    /// 章节偏移 + 章节序号 + 起始时间。
    ///
    /// 完整上报（`rt` 阅读时长、`sg` 签名、`ps/pc` 会话）要等拿到
    /// `reader.psvts` / `reader.token` 后才可信，见根因文档 Step 2。
    func reportProgress(
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

    // MARK: - 网页阅读器地址

    /// 网页阅读器地址：`/web/reader/{_e(bookId)}k{_e(chapterUid)}`。
    ///
    /// `_e()` 就是 `WereadCrypto.calcHash`，和正文接口的 `b`/`c` 同一个函数，
    /// 第三方实现（KOReader 插件、weread-exporter）都按这个公式直接拼，
    /// 不需要去网页书架抄 DOM。以前「自己拼一定 404」的结论是错的。
    func readerURL(bookId: String, chapterUid: Int? = nil) -> URL? {
        guard !bookId.isEmpty else { return nil }
        var path = "/web/reader/" + WereadCrypto.calcHash(bookId)
        if let chapterUid {
            path += "k" + WereadCrypto.calcHash(String(chapterUid))
        }
        return URL(string: base + path)
    }

    func readerURLString(bookId: String, chapterUid: Int? = nil) -> String? {
        readerURL(bookId: bookId, chapterUid: chapterUid)?.absoluteString
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
        return WereadCrypto.chk(unwrapped)
    }

    /// 拿不到会话信标时的兜底 ps（沿用历史上能过签的占位串）。
    private static let placeholderPs = "a2b325707a19e580g0186a2"
    /// 旧版（reader-session 改动之前）一直随 `placeholderPs` 一起发的固定 pc。
    private static let placeholderPc = "430321207a19e581g013ab0"

    // MARK: - 工具

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WereadError.notLoggedIn
            }
            if !(200..<300).contains(http.statusCode) {
                throw WereadError.http(http.statusCode)
            }
        }
        return data
    }

    private func parseObject(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WereadError.decodeFailed
        }
        return json
    }

    private func checkError(_ json: [String: Any]) throws {
        guard let code = intValue(json["errCode"]), code != 0 else { return }
        let message = json["errMsg"] as? String ?? "请求失败"
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

    private func parseBook(_ item: [String: Any]) -> WereadBook? {
        let bookId =
            (item["bookId"] as? String)
            ?? (item["bookId"] as? NSNumber)?.stringValue
        guard let bookId = bookId, !bookId.isEmpty else { return nil }
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

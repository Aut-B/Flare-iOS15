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
    /// `shelf/sync` 解析时见过的 PDF 书。原生阅读器只认 epub/txt 的章节分片，
    /// PDF 要在读正文前分流到网页版，不能等 chapter 接口返回空 HTML 再补救。
    private let pdfLock = NSLock()
    private var pdfBookIDs = Set<String>()
    /// 新增划线必填 `bookVersion`，按书缓存，避免每划一次都多拉一次详情。
    /// 取不到时不缓存，下次划线会重试。
    private let bookVersionLock = NSLock()
    private var bookVersionCache: [String: BookVersions] = [:]
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
                wordCount: intValue(item["wordCount"]) ?? 0
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

    // MARK: - 服务端笔记

    /// 一条「想法」。接口返回的是 review 列表，和划线按 `range` 关联。
    private struct ServerThought {
        let id: String
        let chapterUid: Int
        let range: String
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
        let thoughts = await fetchThoughts(bookId: bookId, cookie: cookie)
        // `range` 是章内字符偏移，不同章节会重复，必须带上 chapterUid 才能对齐。
        var thoughtsByLocation: [String: [ServerThought]] = [:]
        var usedThoughtIds = Set<String>()
        for thought in thoughts where !thought.range.isEmpty {
            let key = thoughtLocation(chapterUid: thought.chapterUid, range: thought.range)
            thoughtsByLocation[key, default: []].append(thought)
        }

        var result: [WereadBookmark] = []
        var seen = Set<String>()
        for (index, item) in updated.enumerated() {
            guard let chapterUid = intValue(item["chapterUid"]) else { continue }
            let markText = ((item["markText"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markText.isEmpty else { continue }

            let range = (item["range"] as? String) ?? ""
            let rawId = ((item["bookmarkId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = rawId.isEmpty ? "bookmark-\(chapterUid)-\(range)-\(index)" : rawId
            guard seen.insert(id).inserted else { continue }

            var notes: [String] = []
            if let inlineNote = item["note"] as? String, !inlineNote.isEmpty {
                notes.append(inlineNote)
            }
            let location = thoughtLocation(chapterUid: chapterUid, range: range)
            if let matched = thoughtsByLocation[location] {
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
                    markText: "",
                    note: thought.content,
                    range: thought.range,
                    createTime: thought.createTime
                )
            )
        }

        let summary =
            "bookmarklist book=\(bookId) updated=\(updated.count) thoughts=\(thoughts.count) parsed=\(result.count)"
        Self.screenDiag(summary)
        FlareDiagnostics.shared.record(.weread, "RES", summary)
        return result
    }

    private func thoughtLocation(chapterUid: Int, range: String) -> String {
        "\(chapterUid)|\(range)"
    }

    /// 拉取自己的「想法」。失败只记日志并返回空数组，不影响划线。
    private func fetchThoughts(bookId: String, cookie: String) async -> [ServerThought] {
        var components = URLComponents(string: "\(base)/web/review/list")
        components?.queryItems = [
            URLQueryItem(name: "bookId", value: bookId),
            URLQueryItem(name: "listType", value: "11"),
            URLQueryItem(name: "mine", value: "1"),
            URLQueryItem(name: "synckey", value: "0"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        do {
            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)
            let reviews = json["reviews"] as? [[String: Any]] ?? []
            var result: [ServerThought] = []
            for (index, item) in reviews.enumerated() {
                guard
                    let review = item["review"] as? [String: Any],
                    intValue(review["type"]) == 1,
                    let chapterUid = intValue(review["chapterUid"])
                else {
                    continue
                }
                let content = ((review["content"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let range =
                    (review["range"] as? String)
                    ?? (review["range"] as? NSNumber)?.stringValue
                    ?? ""
                let rawId = ((review["reviewId"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let id = rawId.isEmpty ? "thought-\(chapterUid)-\(range)-\(index)" : rawId
                result.append(
                    ServerThought(
                        id: id,
                        chapterUid: chapterUid,
                        range: range,
                        content: content,
                        createTime: TimeInterval(intValue(review["createTime"]) ?? 0)
                    )
                )
            }
            return result
        } catch {
            log.notice(
                "weread diag: review/list failed: \(String(describing: error), privacy: .public)"
            )
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "review/list book=\(bookId) 失败: \(error.localizedDescription)"
            )
            return []
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
        bookVersionLock.lock()
        let cached = bookVersionCache[bookId]
        bookVersionLock.unlock()
        if let cached { return cached }

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
            bookVersionLock.lock()
            bookVersionCache[bookId] = versions
            bookVersionLock.unlock()
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
    /// 成功时 `data.bookmarkId` 是非空数组。失败只记诊断并返回 false，
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
            return false
        }
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
                Self.screenDiag("addBookmark book=\(bookId) 失败 errCode=\(code) \(message)")
                FlareDiagnostics.shared.record(
                    .weread,
                    "ERR",
                    "addBookmark book=\(bookId) errCode=\(code) \(message)"
                )
                return false
            }
            let container = json["data"] as? [String: Any] ?? json
            if let id = firstIdentifier(container["bookmarkId"]) {
                Self.screenDiag("addBookmark book=\(bookId) ok id=\(id)")
                return true
            }
            if intValue(json["succ"]) == 1 || intValue(container["succ"]) == 1 {
                Self.screenDiag("addBookmark book=\(bookId) succ=1（未返回 bookmarkId）")
                return true
            }
            let busy = intValue(json["isFetching"]) == 1 || intValue(container["isFetching"]) == 1
            Self.screenDiag(
                "addBookmark book=\(bookId) 未返回 bookmarkId\(busy ? "（操作频繁）" : "")"
            )
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "addBookmark book=\(bookId) 未返回 bookmarkId\(busy ? "（操作频繁）" : "")"
            )
            return false
        } catch {
            Self.screenDiag("addBookmark book=\(bookId) 请求失败: \(error.localizedDescription)")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "addBookmark book=\(bookId) 请求失败: \(error.localizedDescription)"
            )
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
    func addReview(
        bookId: String,
        chapterUid: Int,
        range: String,
        content: String,
        abstract: String,
        cookie: String
    ) async -> Bool {
        guard !bookId.isEmpty, !range.isEmpty, !content.isEmpty, !cookie.isEmpty else {
            return false
        }
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
                Self.screenDiag("addReview book=\(bookId) 失败 errCode=\(code) \(message)")
                FlareDiagnostics.shared.record(
                    .weread,
                    "ERR",
                    "addReview book=\(bookId) errCode=\(code) \(message)"
                )
                return false
            }
            let container = json["data"] as? [String: Any] ?? json
            if let id = firstIdentifier(container["reviewId"]) {
                Self.screenDiag("addReview book=\(bookId) ok id=\(id)")
                return true
            }
            Self.screenDiag("addReview book=\(bookId) 未返回 reviewId")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "addReview book=\(bookId) 未返回 reviewId"
            )
            return false
        } catch {
            Self.screenDiag("addReview book=\(bookId) 请求失败: \(error.localizedDescription)")
            FlareDiagnostics.shared.record(
                .weread,
                "ERR",
                "addReview book=\(bookId) 请求失败: \(error.localizedDescription)"
            )
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
    func uploadHighlight(
        bookId: String,
        chapterUid: Int,
        chapterIdx: Int,
        range: String,
        markText: String,
        note: String,
        cookie: String
    ) async {
        guard !cookie.isEmpty else { return }
        guard !range.isEmpty, !markText.isEmpty else {
            Self.screenDiag(
                "上传笔记跳过 book=\(bookId) chapter=\(chapterUid) 缺少 range"
            )
            return
        }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let version = await bookVersions(bookId: bookId, cookie: cookie)?.version else {
                Self.screenDiag(
                    "上传划线跳过 book=\(bookId) chapter=\(chapterUid) 未取到 bookVersion"
                )
                return
            }
            _ = await addBookmark(
                bookId: bookId,
                chapterUid: chapterUid,
                chapterIdx: chapterIdx,
                bookVersion: version,
                range: range,
                markText: markText,
                cookie: cookie
            )
            return
        }

        _ = await addReview(
            bookId: bookId,
            chapterUid: chapterUid,
            range: range,
            content: trimmed,
            abstract: markText,
            cookie: cookie
        )
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

    /// 这本书是否已在书架数据里标记为 PDF。
    ///
    /// 书架刷新会先把 `shelf/sync` 的原始 `books[]` 交给 `parseBook`，所以用户
    /// 点进书时这里已经有结果，不需要再发一次详情请求。
    func isPDFBook(id: String) -> Bool {
        guard !id.isEmpty else { return false }
        pdfLock.lock()
        defer { pdfLock.unlock() }
        return pdfBookIDs.contains(id)
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

    private func sendWithStatus(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let path = request.url?.path ?? ""
        var status = -1
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        // 所有微读请求都记录到屏幕诊断（章节目录、正文分片、阅读器页面），
        // 只截前 180 字节、不含 cookie，避免泄露登录态。
        let head = String(decoding: data.prefix(180), as: UTF8.self)
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
        guard containsPDFMarker(item) else { return }
        pdfLock.lock()
        pdfBookIDs.insert(bookId)
        pdfLock.unlock()
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

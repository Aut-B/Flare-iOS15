import Foundation

/// 微信读书 Web 接口封装。
///
/// 全部走 `weread.qq.com` 的网页接口，登录态就是浏览器那套 cookie
/// （`wr_vid` / `wr_skey` / `wr_rt`）。正文接口带签名，响应还要解密，
/// 算法在 `WereadCrypto` 里。
final class WereadService: @unchecked Sendable {
    static let shared = WereadService()

    private let base = "https://weread.qq.com"
    private let session: URLSession

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

    // MARK: - 书架

    func shelf(cookie: String) async throws -> [WereadBook] {
        // `synckeys=0` 只给第一页，书架大的人会少一截（用户说的「没还原全」）。
        // 接口会在响应里回一个新的 synckey，带着它再要一页，直到没有新书。
        var result: [WereadBook] = []
        var seen = Set<String>()
        var syncKey = "0"
        for _ in 0..<4 {
            let url = URL(string: "\(base)/web/shelf/sync?synckeys=\(syncKey)&teenmode=0&album=1")!
            var request = URLRequest(url: url)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")

            let data = try await send(request)
            let json = try parseObject(data)
            try checkError(json)

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
        return result
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
            let percent = min(max(intValue(item["progress"]) ?? 0, 0), 100)
            var stamp = TimeInterval(max(intValue(item["updateTime"]) ?? 0, 0))
            if stamp == 0 {
                stamp = TimeInterval(max(intValue(item["readUpdateTime"]) ?? 0, 0))
            }
            if stamp > 10_000_000_000 { stamp /= 1000 }
            map[bookId] = (percent, stamp)
        }
        return map
    }

    // MARK: - 目录

    func chapters(bookId: String, cookie: String) async throws -> [WereadChapter] {
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
    func content(bookId: String, chapterUid: Int, cookie: String) async throws -> String {
        let uid = String(chapterUid)

        async let epub0 = fragment("/web/book/chapter/e_0", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)
        async let epub1 = fragment("/web/book/chapter/e_1", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)
        async let epub2 = fragment("/web/book/chapter/e_2", bookId: bookId, chapterUid: uid, st: 1, cookie: cookie)
        async let epub3 = fragment("/web/book/chapter/e_3", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)

        let (part0, part1, part2, part3) = try await (epub0, epub1, epub2, epub3)

        if !part0.isEmpty, !part1.isEmpty, !part3.isEmpty {
            let style = WereadCrypto.decrypt(part2)
            var html = WereadCrypto.decrypt(part0 + part1 + part3)
            guard !html.isEmpty else { throw WereadError.empty }
            html = clean(html)
            if !style.isEmpty {
                html = "<style>\(style)</style>\(html)"
            }
            return html
        }

        // 老 txt 书走 t_0 / t_1。
        async let txt0 = fragment("/web/book/chapter/t_0", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)
        async let txt1 = fragment("/web/book/chapter/t_1", bookId: bookId, chapterUid: uid, st: 1, cookie: cookie)
        let (text0, text1) = try await (txt0, txt1)
        let text = WereadCrypto.decrypt(text0 + text1)
        guard !text.isEmpty else { throw WereadError.empty }
        return text
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
    func reportProgress(
        bookId: String,
        chapterUid: Int,
        chapterOffset: Int,
        cookie: String
    ) async {
        var request = URLRequest(url: URL(string: "\(base)/web/book/read")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let payload: [String: Any] = [
            "bookId": bookId,
            "chapterUid": chapterUid,
            "chapterOffset": chapterOffset,
            "ci": chapterUid,
            "pc": "430321207a19e581g013ab0",
            "ps": "a2b325707a19e580g0186a2",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await send(request)
    }

    // MARK: - 单个正文分片

    private func fragment(
        _ path: String,
        bookId: String,
        chapterUid: String,
        st: Int,
        cookie: String
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
        let devicePs = "a2b325707a19e580g0186a2"
        let devicePc = "430321207a19e581g013ab0"

        let signed = WereadCrypto.sign([
            ("b", hashedBook),
            ("c", hashedChapter),
            ("r", String(random)),
            ("st", String(st)),
            ("ct", String(timestamp)),
            ("ps", devicePs),
            ("pc", devicePc),
        ])

        let payload: [String: Any] = [
            "b": hashedBook,
            "c": hashedChapter,
            "r": random,
            "st": st,
            "ct": timestamp,
            "ps": devicePs,
            "pc": devicePc,
            "s": signed,
        ]
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

    // MARK: - 工具

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WereadError.http(http.statusCode)
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
        // 进度有时是数组（shelf/sync），有时是单个对象。
        let percent: Int
        if let list = item["progress"] as? [[String: Any]] {
            percent = intValue(list.first?["progress"]) ?? 0
        } else if let dict = item["progress"] as? [String: Any] {
            percent = intValue(dict["progress"]) ?? 0
        } else {
            percent = 0
        }
        // 最近阅读时间：`readUpdateTime` 是书架级的，`progress[].updateTime`
        // 是每本书自己的；有的一版只给毫秒，所以大于 1e10 就除 1000。
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
        var updated = TimeInterval(max(stamp, 0))
        if updated > 10_000_000_000 { updated /= 1000 }

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
    private func clean(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: "(<img[^>]+?)(src=\"data:[^\"]+\")",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(<img[^>]+?)data-src=\"",
            with: "$1src=\"",
            options: .regularExpression
        )
        return result
    }
}

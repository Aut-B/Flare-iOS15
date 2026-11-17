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
        return books(fromShelfJSON: merged)
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

        // 四种分片用 `try?`：txt 书请求 `e_*` 会 404，以前这里 `try await`
        // 一抛错就整章失败，下面的 `t_*` 兜底根本走不到 —— 表现就是
        // 「点开一直白屏 / 一直转圈」。
        async let epub0 = try? fragment("/web/book/chapter/e_0", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)
        async let epub1 = try? fragment("/web/book/chapter/e_1", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)
        async let epub2 = try? fragment("/web/book/chapter/e_2", bookId: bookId, chapterUid: uid, st: 1, cookie: cookie)
        async let epub3 = try? fragment("/web/book/chapter/e_3", bookId: bookId, chapterUid: uid, st: 0, cookie: cookie)

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
            return try await textChapter(bookId: bookId, chapterUid: uid, cookie: cookie)
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
    private func textChapter(bookId: String, chapterUid: String, cookie: String) async throws -> String {
        async let txt0 = try? fragment("/web/book/chapter/t_0", bookId: bookId, chapterUid: chapterUid, st: 0, cookie: cookie)
        async let txt1 = try? fragment("/web/book/chapter/t_1", bookId: bookId, chapterUid: chapterUid, st: 1, cookie: cookie)
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
        // ⚠️ 这两个是**占位值，不是正确实现**（见 .fleet/weread-rootcause.md E1）。
        // 正确来源：
        //   ps = 这本书这一章 `/web/reader/{_e(bookId)}k{_e(chapterUid)}` 页面里
        //        `window.__INITIAL_STATE__.reader.psvts`
        //   pc = `_e(ct)`，也就是 WereadCrypto.calcHash(String(timestamp))
        // 另外还缺 `sc = 1`（整章）与 `prevChapter = false`。
        // 在这些补齐之前，epub 书的正文接口仍可能返回 `{}`。
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

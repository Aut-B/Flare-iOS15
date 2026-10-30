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
        let url = URL(string: "\(base)/web/shelf/sync?synckeys=0&teenmode=0&album=1")!
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let data = try await send(request)
        let json = try parseObject(data)
        try checkError(json)

        let books = json["books"] as? [[String: Any]] ?? []
        return books.compactMap(parseBook)
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
        guard let bookId = item["bookId"] as? String else { return nil }
        let progressList = item["progress"] as? [[String: Any]]
        let percent = intValue(progressList?.first?["progress"]) ?? 0
        return WereadBook(
            id: bookId,
            title: item["title"] as? String ?? "",
            author: item["author"] as? String ?? "",
            cover: item["cover"] as? String,
            progress: min(max(percent, 0), 100),
            finished: (intValue(item["finishReading"]) ?? 0) == 1
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

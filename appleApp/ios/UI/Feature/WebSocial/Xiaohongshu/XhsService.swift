import Foundation

/// 小红书的 Web 接口。
///
/// 域名是 `edith.xiaohongshu.com`，每个请求都要 `X-S` / `X-T` / `X-S-Common`。
/// 前两个由隐藏网页里的 `_webmsxyw` 算（见 `XhsSigner`），`X-S-Common` 是一段
/// base64 过的设备信息，本地拼就行。
final class XhsService {
    static let shared = XhsService()

    private let session: URLSession
    private let host = "https://edith.xiaohongshu.com"
    private let referer = "https://www.xiaohongshu.com/"

    /// 由 `XhsStore` 每次请求前写入。
    var cookie: String = ""

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    // MARK: - 首页

    /// `follow == true` 时取关注流，否则是推荐流。
    func homeFeed(cursor: String?, follow: Bool) async throws -> (notes: [XhsNote], next: String?) {
        var payload: [String: Any] = [
            "cursor_score": cursor ?? "",
            "num": 20,
            "refresh_type": 1,
            "note_index": 0,
            "unread_begin_note_id": "",
            "unread_end_note_id": "",
            "unread_note_count": 0,
            "category": follow ? "homefeed.follow" : "homefeed_recommend",
            "search_key": "",
            "need_num": 20,
            "image_formats": ["jpg", "webp", "avif"],
            "need_filter_image": false,
        ]
        if cursor == nil {
            payload["refresh_type"] = 1
        }

        let json = try await post("/api/sns/web/v1/homefeed", payload: payload)
        let data = XhsJSON.object(json["data"]) ?? [:]
        var notes: [XhsNote] = []
        for item in XhsJSON.array(data["items"]) {
            // 首页流里混着 `model_type != note` 的推荐位，跳过。
            if let type = XhsJSON.string(item["model_type"]), type != "note" { continue }
            if let note = XhsJSON.note(item) { notes.append(note) }
        }
        let next = XhsJSON.string(data["cursor_score"])
        return (notes, next)
    }

    // MARK: - 笔记详情

    func note(id: String) async throws -> XhsNote {
        let payload: [String: Any] = [
            "source_note_id": id,
            "image_formats": ["jpg", "webp", "avif"],
            "extra": ["need_body_topic": "1"],
        ]
        let json = try await post("/api/sns/web/v1/feed", payload: payload)
        let data = XhsJSON.object(json["data"]) ?? [:]
        guard let note = XhsJSON.array(data["items"]).compactMap({ XhsJSON.note($0) }).first else {
            throw XhsError(message: "笔记已删除或不可见", needLogin: false)
        }
        return note
    }

    // MARK: - 用户笔记

    func userNotes(userId: String, cursor: String?) async throws -> (notes: [XhsNote], next: String?) {
        let payload: [String: Any] = [
            "num": 30,
            "cursor": cursor ?? "",
            "user_id": userId,
            "image_formats": ["jpg", "webp", "avif"],
        ]
        let json = try await post("/api/sns/web/v1/user_posted", payload: payload)
        let data = XhsJSON.object(json["data"]) ?? [:]
        let notes = XhsJSON.array(data["notes"]).compactMap { XhsJSON.note($0) }
        return (notes, XhsJSON.string(data["cursor"]))
    }

    // MARK: - 底层

    private func post(_ path: String, payload: [String: Any]) async throws -> [String: Any] {
        let signature = try await XhsSigner.shared.sign(path: path, payload: payload)

        guard let url = URL(string: host + path) else {
            throw XhsError(message: "请求地址非法", needLogin: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = signature.body.data(using: .utf8)
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(XhsSigner.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(signature.xs, forHTTPHeaderField: "X-S")
        request.setValue(signature.xt, forHTTPHeaderField: "X-T")
        let common = commonHeader()
        if !common.isEmpty {
            request.setValue(common, forHTTPHeaderField: "X-S-Common")
        }
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw XhsError.notLoggedIn
        }
        guard (200..<300).contains(status) else {
            throw XhsError(message: "请求失败（HTTP \(status)）", needLogin: false)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw XhsError(message: "接口返回格式异常", needLogin: false)
        }
        try check(json)
        return json
    }

    private func check(_ json: [String: Any]) throws {
        let code = XhsJSON.int(json["code"])
        if code == 0 { return }
        let message = XhsJSON.string(json["msg"]) ?? "请求失败（code \(code)）"
        // -100 = 未登录，461 = 需要验证码，300013 = 签名错误。
        if code == -100 || code == 300013 {
            throw XhsError.notLoggedIn
        }
        if code == 461 {
            throw XhsError(
                message: "小红书要求人机验证，去网页版刷一下再回来",
                needLogin: false
            )
        }
        throw XhsError(message: message, needLogin: false)
    }

    /// `X-S-Common` 是一段 base64 的设备指纹，服务端只做风控打分，缺了也能过。
    private func commonHeader() -> String {
        let a1 = CookieJar.value(inHeader: cookie, named: "a1") ?? ""
        let webId = CookieJar.value(inHeader: cookie, named: "webId") ?? ""
        let payload: [String: Any] = [
            "s0": 5,
            "s1": "",
            "s2": "",
            "s3": "",
            "s4": "",
            "s5": a1,
            "s6": "",
            "s7": "",
            "s8": "",
            "s9": Int(Date().timeIntervalSince1970 * 1000),
            "s10": 154,
            "s11": "normal",
            "s12": "",
            "s13": "",
            "s14": webId,
            "s15": "",
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        else {
            return ""
        }
        return data.base64EncodedString()
    }
}

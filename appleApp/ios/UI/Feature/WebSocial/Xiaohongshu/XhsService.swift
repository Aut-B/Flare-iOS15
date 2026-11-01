import Foundation

/// 小红书的 Web 接口。
///
/// 域名是 `edith.xiaohongshu.com`，每个请求都要 `X-S` / `X-T` / `X-S-Common`。
/// 前两个由隐藏网页里的 `_webmsxyw` 算（见 `XhsSigner`），`X-S-Common` 是一段
/// base64 过的设备信息，本地拼就行。
///
/// 请求本身也交给那个网页去发（`XhsSigner.pageRequest`）：从 `URLSession` 发
/// 出去，签名再对也会被判 `code -1`，因为 TLS 指纹和浏览器不是一回事。
final class XhsService {
    static let shared = XhsService()

    private let host = "https://edith.xiaohongshu.com"

    /// 由 `XhsStore` 每次请求前写入。
    var cookie: String = ""

    private init() {}

    // MARK: - 首页

    /// `follow == true` 时取关注流，否则是推荐流。
    func homeFeed(cursor: String?, follow: Bool) async throws -> (notes: [XhsNote], next: String?) {
        let payload: [String: Any] = [
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

    func note(id: String, xsecToken: String = "") async throws -> XhsNote {
        var payload: [String: Any] = [
            "source_note_id": id,
            "image_formats": ["jpg", "webp", "avif"],
            "extra": ["need_body_topic": "1"],
        ]
        if !xsecToken.isEmpty {
            payload["xsec_token"] = xsecToken
            payload["xsec_source"] = "pc_feed"
        }
        let json = try await post("/api/sns/web/v1/feed", payload: payload)
        let data = XhsJSON.object(json["data"]) ?? [:]
        guard let note = XhsJSON.array(data["items"]).compactMap({ XhsJSON.note($0) }).first else {
            throw XhsError(message: "笔记已删除或不可见", needLogin: false)
        }
        return note
    }

    // MARK: - 互动

    /// 点赞 / 取消点赞。网页版这两个接口要的是 `note_oid`（收藏才是
    /// `note_id`），两个都带上，省得再猜一次。
    func like(noteId: String) async throws {
        _ = try await post("/api/sns/web/v1/note/like", payload: Self.noteKeys(noteId))
    }

    func unlike(noteId: String) async throws {
        _ = try await post("/api/sns/web/v1/note/unlike", payload: Self.noteKeys(noteId))
    }

    func collect(noteId: String) async throws {
        _ = try await post("/api/sns/web/v1/note/collect", payload: Self.noteKeys(noteId))
    }

    func uncollect(noteId: String) async throws {
        _ = try await post("/api/sns/web/v1/note/uncollect", payload: Self.noteKeys(noteId))
    }

    private static func noteKeys(_ noteId: String) -> [String: Any] {
        ["note_id": noteId, "note_oid": noteId]
    }

    // MARK: - 评论

    func comments(
        noteId: String,
        xsecToken: String,
        cursor: String?
    ) async throws -> (items: [XhsComment], next: String?) {
        var parts = [
            "note_id=" + Self.encode(noteId),
            "cursor=" + Self.encode(cursor ?? ""),
            "top_comment_id=",
            "image_formats=jpg,webp,avif",
        ]
        if !xsecToken.isEmpty {
            parts.append("xsec_token=" + Self.encode(xsecToken))
        }
        // 网页版评论区请求固定带 xsec_source；少了它服务端会认为「来源不明」，
        // 一律回「当前笔记暂时无法浏览」。
        parts.append("xsec_source=pc_feed")
        let json = try await get(
            "/api/sns/web/v2/comment/page",
            query: parts.joined(separator: "&")
        )
        let data = XhsJSON.object(json["data"]) ?? [:]
        let items = XhsJSON.array(data["comments"]).compactMap { XhsJSON.comment($0) }
        return (items, XhsJSON.string(data["cursor"]))
    }

    @discardableResult
    func postComment(noteId: String, content: String) async throws -> XhsComment? {
        let json = try await post(
            "/api/sns/web/v1/comment/post",
            payload: [
                "note_id": noteId,
                "content": content,
                "at_users": [String](),
            ]
        )
        let data = XhsJSON.object(json["data"]) ?? [:]
        return XhsJSON.comment(data["comment"])
    }

    // MARK: - 用户

    /// 某个用户公开的笔记。网页版是 GET + query，老版本也见过 POST，
    /// 两种都试一遍，免得一个接口改版就整页空白。
    func userNotes(userId: String, cursor: String?) async throws -> (notes: [XhsNote], next: String?) {
        let query = [
            "num=30",
            "cursor=" + Self.encode(cursor ?? ""),
            "user_id=" + Self.encode(userId),
            "image_formats=jpg,webp,avif",
        ].joined(separator: "&")
        let json: [String: Any]
        do {
            json = try await get("/api/sns/web/v1/user_posted", query: query)
        } catch {
            json = try await post(
                "/api/sns/web/v1/user_posted",
                payload: [
                    "num": 30,
                    "cursor": cursor ?? "",
                    "user_id": userId,
                    "image_formats": ["jpg", "webp", "avif"],
                ]
            )
        }
        let data = XhsJSON.object(json["data"]) ?? [:]
        let notes = XhsJSON.array(data["notes"]).compactMap { XhsJSON.note($0) }
        return (notes, XhsJSON.string(data["cursor"]))
    }

    func profile(userId: String) async throws -> XhsProfile {
        let json = try await get(
            "/api/sns/web/v1/user/otherinfo",
            query: "target_user_id=" + Self.encode(userId)
        )
        let data = XhsJSON.object(json["data"]) ?? json
        guard let profile = XhsJSON.profile(data) else {
            throw XhsError(message: "没拿到用户资料，稍后重试", needLogin: false)
        }
        return profile
    }

    func selfProfile() async throws -> XhsProfile {
        let json = try await get("/api/sns/web/v1/user/selfinfo", query: nil)
        let data = XhsJSON.object(json["data"]) ?? json
        guard let profile = XhsJSON.profile(data) else {
            throw XhsError(message: "没拿到账号资料，稍后重试", needLogin: false)
        }
        return profile
    }

    // MARK: - 底层

    private func post(_ path: String, payload: [String: Any]) async throws -> [String: Any] {
        try await send(path: path, method: "POST", query: nil, payload: payload)
    }

    private func get(_ path: String, query: String?) async throws -> [String: Any] {
        try await send(path: path, method: "GET", query: query, payload: nil)
    }

    private func send(
        path: String,
        method: String,
        query: String?,
        payload: [String: Any]?
    ) async throws -> [String: Any] {
        var attempt = 0
        while true {
            let result: XhsSigner.PageResult
            do {
                result = try await XhsSigner.shared.pageRequest(
                    path: path,
                    method: method,
                    host: host,
                    query: query,
                    payload: payload,
                    commonHeader: commonHeader()
                )
            } catch let error as XhsError {
                throw error
            } catch {
                throw XhsError.signFailed
            }

            if result.status == 401 {
                throw XhsError.notLoggedIn
            }
            guard
                let data = result.text.data(using: .utf8),
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                if result.status == 403 || result.status == 461 {
                    throw XhsError(
                        message: "小红书风控拦截（HTTP \(result.status)），请稍后重试；一直失败就重新登录一次",
                        needLogin: false
                    )
                }
                throw XhsError(
                    message: "接口返回格式异常（HTTP \(result.status)）",
                    needLogin: false
                )
            }

            // 300013 = 签名过期。重算一次通常就好，别把用户踢回登录页。
            if XhsJSON.int(json["code"]) == 300013, attempt == 0 {
                attempt += 1
                XhsSigner.shared.reset()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            try check(json)
            guard (200..<300).contains(result.status) else {
                throw XhsError(message: "请求失败（HTTP \(result.status)）", needLogin: false)
            }
            return json
        }
    }

    private func check(_ json: [String: Any]) throws {
        let code = XhsJSON.int(json["code"])
        if code == 0 { return }
        let message = XhsJSON.string(json["msg"]) ?? "请求失败（code \(code)）"
        // 评论区最常见的拒绝就是这句：note_id 对、xsec_token 过期 / 来源对不上。
        // 原样抛给用户等于什么也没说，换成能指导下一步的话。
        if message.contains("当前笔记") || message.contains("无法浏览") || message.contains("笔记不存在") {
            throw XhsError(
                message: "小红书说这条笔记现在打不开（\(message)）。多半是 xsec_token 过期或被限流：回首页刷新一次再点进来；一直这样就用右上角「网页版」看。",
                needLogin: false
            )
        }
        // -100 = 未登录，461 = 需要验证码，300013 = 签名错误。
        if code == -100 {
            throw XhsError.notLoggedIn
        }
        if code == 300013 {
            XhsSigner.shared.reset()
            throw XhsError(message: "小红书签名失效，已自动刷新，请再点一次重试", needLogin: false)
        }
        if code == 461 {
            throw XhsError(
                message: "小红书要求人机验证，去网页版刷一下再回来",
                needLogin: false
            )
        }
        if code == -1 {
            throw XhsError(
                message: "小红书拒绝了这次请求（code -1），多半是风控。稍后再试，或点右上角切到网页版操作",
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

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
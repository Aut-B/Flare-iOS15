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
    func homeFeed(
        cursor: String?,
        follow: Bool,
        refreshType: Int = 1,
        noteIndex: Int = 0
    ) async throws -> (notes: [XhsNote], next: String?) {
        let payload: [String: Any] = [
            "cursor_score": cursor ?? "",
            "num": 20,
            "refresh_type": refreshType,
            "note_index": noteIndex,
            "unread_begin_note_id": "",
            "unread_end_note_id": "",
            "unread_note_count": 0,
            "category": follow ? "homefeed.follow" : "homefeed_recommend",
            "search_key": "",
            "need_num": 20,
            "image_formats": ["jpg", "webp"],
            "need_filter_image": false,
        ]

        let json = try await post("/api/sns/web/v1/homefeed", payload: payload)
        let data = XhsJSON.object(json["data"]) ?? [:]
        var notes: [XhsNote] = []
        for item in XhsJSON.array(data["items"]) {
            // 首页流里混着 `model_type != note` 的推荐位，跳过。
            if let type = XhsJSON.string(item["model_type"]), type != "note" { continue }
            if let note = XhsJSON.note(item, defaultSource: follow ? "pc_homefeed_follow" : "pc_feed") {
                notes.append(note)
            }
        }
        let next = XhsJSON.string(data["cursor_score"])
        return (notes, next)
    }

    // MARK: - 笔记详情

    func note(
        id: String,
        xsecToken: String = "",
        xsecSource: String = "pc_feed",
        timeout: TimeInterval = 12,
        attempts: Int = 2
    ) async throws -> XhsNote {
        var payload: [String: Any] = [
            "source_note_id": id,
            "image_formats": ["jpg", "webp"],
            "extra": ["need_body_topic": "1"],
        ]
        // `xsec_source` 和 `xsec_token` 是两回事：公开笔记的 token 可以为空，
        // 但详情接口仍需要来源，否则服务端会按「来源不明」拒绝，
        // 评论刷新 token 的那一步也会跟着失败。
        if !xsecSource.isEmpty {
            payload["xsec_source"] = xsecSource
        }
        if !xsecToken.isEmpty {
            payload["xsec_token"] = xsecToken
        }
        let json = try await post("/api/sns/web/v1/feed", payload: payload, timeout: timeout, attempts: attempts)
        let data = XhsJSON.object(json["data"]) ?? [:]
        guard var note = XhsJSON.array(data["items"]).compactMap({ XhsJSON.note($0, defaultSource: xsecSource) }).first else {
            throw XhsError(message: "笔记已删除或不可见", needLogin: false)
        }
        // 详情接口把**刷新后**的 xsec_token / xsec_source 放在响应 `data` 层
        // （与 `items` 同级），而 `items[0]` 里通常没有。以前这里只取 items[0]，
        // 新 token 直接被丢掉，评论区下一次仍然拿旧 token -> 反复「暂时无法浏览」。
        if let freshToken = XhsJSON.string(data["xsec_token"]), !freshToken.isEmpty {
            note.xsecToken = freshToken
        }
        if let freshSource = XhsJSON.string(data["xsec_source"]), !freshSource.isEmpty {
            note.xsecSource = freshSource
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

    /// 评论区请求的 query 串。
    ///
    /// 真正的实现在 `XhsQuery`：那份不依赖 UIKit/WebKit，能被纯逻辑测试
    /// （`LogicTests`）直接编译进去断言。这里只是转一层，避免逻辑分叉。
    static func commentQuery(
        noteId: String,
        xsecToken: String,
        cursor: String?,
        xsecSource: String
    ) -> String {
        XhsQuery.commentQuery(
            noteId: noteId,
            xsecToken: xsecToken,
            cursor: cursor,
            xsecSource: xsecSource
        )
    }

    func comments(
        noteId: String,
        xsecToken: String,
        cursor: String?,
        xsecSource: String = "pc_feed"
    ) async throws -> (items: [XhsComment], next: String?) {
        // 评论是用户点了就要看的，但 5 秒对 6s 上的签名页太短：页面还在
        // 初始化时会连续失败。给到 10 秒、两次尝试，仍然比默认 12 秒短。
        let json = try await get(
            "/api/sns/web/v2/comment/page",
            query: Self.commentQuery(
                noteId: noteId,
                xsecToken: xsecToken,
                cursor: cursor,
                xsecSource: xsecSource
            ),
            timeout: 10,
            attempts: 2
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
        // 走 `XhsQuery.userPostedQuery`：`image_formats` 的逗号必须编码成
        // `%2C`，理由同评论区 —— 这条 query 也原样参与 `_webmsxyw` 签名。
        let query = XhsQuery.userPostedQuery(userId: userId, cursor: cursor)
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
                    "image_formats": ["jpg", "webp"],
                ]
            )
        }
        let data = XhsJSON.object(json["data"]) ?? [:]
        let notes = XhsJSON.array(data["notes"]).compactMap { XhsJSON.note($0, defaultSource: "pc_user") }
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

    /// 冷启动时从系统 cookie 仓库捡回的会话只能当候选。
    ///
    /// 登录页在 `clearCookies` 后会先种一个游客 `web_session`，非空不代表
    /// 已登录。必须用它真的问一次「我是谁」，`selfProfile()` 成功才算
    /// 有效会话，否则用户会被卡在「假登录态」里，首页一直 -100。
    ///
    /// 校验期间会临时改写共享的 `cookie` / 签名页；结束后只在没有新登录
    /// 插队时恢复 `XhsService.cookie`。签名页不回写旧 cookie：登录页可能
    /// 已经清空并开始新的扫码会话，回写旧会话会把刚清掉的 cookie 又种回去。
    func validateSession(cookie candidate: String) async -> Bool {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let previous = cookie
        cookie = normalized
        XhsSigner.shared.applyCookies(normalized, force: true)
        defer {
            // 校验期间用户可能已经扫码登录，别把新 cookie 覆盖掉。
            if cookie == normalized {
                cookie = previous
            }
        }
        do {
            _ = try await selfProfile()
            return true
        } catch {
            return false
        }
    }

    // MARK: - 底层

    private func post(
        _ path: String,
        payload: [String: Any],
        timeout: TimeInterval = 12,
        attempts: Int = 2
    ) async throws -> [String: Any] {
        try await send(
            path: path,
            method: "POST",
            query: nil,
            payload: payload,
            timeout: timeout,
            attempts: attempts
        )
    }

    private func get(
        _ path: String,
        query: String?,
        timeout: TimeInterval = 12,
        attempts: Int = 2
    ) async throws -> [String: Any] {
        try await send(
            path: path,
            method: "GET",
            query: query,
            payload: nil,
            timeout: timeout,
            attempts: attempts
        )
    }

    private func send(
        path: String,
        method: String,
        query: String?,
        payload: [String: Any]?,
        timeout: TimeInterval = 12,
        attempts: Int = 2
    ) async throws -> [String: Any] {
        var attempt = 0
        var authRetried = false
        while true {
            // 冷启动后签名页可能还是匿名会话。首页流以前在 `XhsStore.refresh`
            // 里单独灌过 cookie，但详情 / 评论 / 点赞 / 用户资料都走这里，
            // 不灌就会拿匿名 cookie 去请求，直接被判 `-100`，看起来像掉登录。
            if !cookie.isEmpty {
                XhsSigner.shared.applyCookies(cookie)
            }
            let result: XhsSigner.PageResult
            do {
                result = try await XhsSigner.shared.pageRequest(
                    path: path,
                    method: method,
                    host: host,
                    query: query,
                    payload: payload,
                    commonHeader: commonHeader(),
                    timeout: timeout,
                    attempts: attempts
                )
            } catch let error as XhsError {
                FlareDiagnostics.shared.record(
                    .xhs, "ERR",
                    "\(method) \(path) 签名/网络失败: \(error.message) · cookie=\(cookie.isEmpty ? "空" : "\(cookie.count)字符")"
                )
                throw error
            } catch {
                FlareDiagnostics.shared.record(.xhs, "ERR", "\(method) \(path) 签名异常: \(error.localizedDescription)")
                throw XhsError.signFailed
            }

            let head = String(result.text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            FlareDiagnostics.shared.record(
                .xhs,
                result.status >= 400 ? "ERR" : "RES",
                "\(method) \(path) → \(result.status) · \(result.text.count)字符 · \(head)"
            )
            // 把这次请求实际用的登录态指纹记下来：cookie 为空 / xsec 缺失都能看出来。
            let hasXsec = result.text.contains("xsec") || query?.contains("xsec") == true
            FlareDiagnostics.shared.record(
                .xhs, "STATE",
                "cookie=\(cookie.isEmpty ? "空" : "\(cookie.count)字符") · xsec=\(hasXsec ? "有" : "无")"
            )

            if result.status == 401 {
                if !authRetried {
                    authRetried = true
                    await recoverSession()
                    continue
                }
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
                XhsSigner.shared.reset(cookie: cookie)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            do {
                try check(json)
            } catch let error as XhsError where error.needLogin {
                // 第一次 -100 可能只是隐藏页还拿着旧 cookie / 刚重建完。
                // 先把当前登录态重新灌进去再试一次，第二次才认定真的掉登录。
                if !authRetried {
                    authRetried = true
                    await recoverSession()
                    continue
                }
                throw error
            }
            guard (200..<300).contains(result.status) else {
                throw XhsError(message: "请求失败（HTTP \(result.status)）", needLogin: false)
            }
            return json
        }
    }

    /// 401 / code -100 的恢复：把最新 cookie 写回隐藏页并重载一次。
    private func recoverSession() async {
        XhsSigner.shared.reset(cookie: cookie)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
            XhsSigner.shared.reset(cookie: cookie)
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

    /// query 值编码。
    ///
    /// 实现在 `XhsQuery.encode`，那份能被纯逻辑测试直接断言。
    static func encode(_ value: String) -> String {
        XhsQuery.encode(value)
    }
}

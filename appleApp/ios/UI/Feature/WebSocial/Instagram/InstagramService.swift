import Foundation
import os

/// Instagram 网页版 v1 接口。
///
/// 登录态只需要 cookie 加上固定的 `X-IG-App-ID`，没有别的签名 —— 这也是
/// 它比小红书省事的地方。cookie 掉线时接口返回 401 或 `login_required`，
/// 统一翻译成 `IGError.needLogin`。
final class InstagramService {
    static let shared = InstagramService()
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.instagram",
        category: "profile"
    )

    private let session: URLSession

    /// 由 `InstagramStore` 在每次请求前写入。
    var cookie: String = ""
    var csrfToken: String = ""
    var userId: String = ""

    private let base = "https://www.instagram.com"
    private let appID = "936619743392459"
    private let asbdID = "129477"
    /// 必须用桌面 Chrome 的 UA：`X-IG-App-ID` 是桌面网页版那一份，UA 自称 iPhone
    /// 时 `/api/v1/accounts/...` 会判定「客户端与 app id 不匹配」，回一个空 body 的 400。
    private let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        // cookie 自己带，别让 URLSession 再叠一份。
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    // MARK: - 首页时间线

    func homeFeed(cursor: String?) async throws -> (items: [IGMedia], next: String?) {
        let params = Self.feedParams(cursor: cursor)
        let query = params.map { "\($0.0)=\(Self.percentEncode($0.1))" }.joined(separator: "&")

        var json: [String: Any]
        do {
            // 网页端首页实际走 POST + 表单体；先按网页端的姿势来。
            json = try await request(
                "\(base)/api/v1/feed/timeline/",
                method: "POST",
                formBody: query
            )
        } catch let error as IGError {
            // 还有一批账号只认 GET 的 query 参数，POST 被拒时换一种姿势再试一次。
            // 登录失效不重试，那是真的没登录。
            if error.needLogin { throw error }
            json = try await request("\(base)/api/v1/feed/timeline/?\(query)")
        } catch {
            throw error
        }

        var items: [IGMedia] = []
        for entry in IGJSON.array(json["feed_items"]) {
            // 时间线里混着「推荐关注」「故事」这类非帖子条目，只取有媒体的。
            if let media = IGJSON.media(entry["media_or_ad"]) {
                items.append(media)
            }
        }
        return (items, IGJSON.string(json["next_max_id"]))
    }

    private static func feedParams(cursor: String?) -> [(String, String)] {
        // 这是 App 的接口，参数照抄一份；少一个 `reason` 就可能 400。
        var params: [(String, String)] = [
            ("is_prefetch", "false"),
            ("feed_view_info", "[]"),
            ("phone_id", deviceUUID),
            ("battery_level", "100"),
            ("timezone_offset", "28800"),
            ("is_pull_to_refresh", "false"),
            ("is_charging", "0"),
            ("will_sound_on", "1"),
            ("is_dark_mode", "0"),
            ("reason", "pull_to_refresh"),
        ]
        if let cursor = cursor {
            params.append(("max_id", cursor))
        }
        return params
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    // MARK: - 用户主页

    /// 用户名 → 用户信息 + 前 12 条帖子。这个接口在网页端一直在用，比较稳。
    func profile(userName: String) async throws -> (user: IGUser, media: [IGMedia], next: String?) {
        let encoded = userName.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? userName
        let url = "\(base)/api/v1/users/web_profile_info/?username=\(encoded)"
        let json = try await request(url)

        guard let data = IGJSON.object(json["data"]), let rawUser = IGJSON.object(data["user"]) else {
            throw IGError(message: "没有找到 @\(userName) 这个账号", needLogin: false)
        }
        guard let user = IGJSON.user(rawUser) else {
            throw IGError(message: "账号信息解析失败", needLogin: false)
        }
        let connection = IGJSON.object(rawUser["edge_owner_to_timeline_media"])
        let edges = IGJSON.array(connection?["edges"])
        let media = edges.compactMap { edge -> IGMedia? in
            guard let node = IGJSON.object(edge["node"]) else { return nil }
            return Self.profileMedia(node: node, user: user)
        }
        let next = IGJSON.string(IGJSON.object(connection?["page_info"])?["end_cursor"])
        Self.profileLog.info(
            "profile \(userName, privacy: .public): \(edges.count) edges, \(media.count) parsed"
        )
        if !edges.isEmpty, media.isEmpty {
            Self.profileLog.error(
                "profile \(userName, privacy: .public): all grid nodes failed to parse"
            )
        }
        return (user, media, next)
    }

    /// `web_profile_info` 的九宫格节点和首页/详情不是同一套字段：
    /// 帖子 id 叫 `id` 而不是 `pk`，作者在 `owner` 而不是 `user`，
    /// 图片只有 `display_url`，点赞/评论数是 `edge_*` 结构。
    /// 直接丢给 `IGJSON.media` 会全部返回 nil，主页看起来就是「一条帖子都没有」。
    private static func profileMedia(node: [String: Any], user: IGUser) -> IGMedia? {
        var normalized = node
        if IGJSON.identifier(normalized["pk"]) == nil {
            if let id = IGJSON.identifier(normalized["id"]) {
                normalized["pk"] = id
            } else if let code = IGJSON.string(normalized["shortcode"]) {
                normalized["pk"] = code
            }
        }
        if IGJSON.user(normalized["user"]) == nil {
            if let owner = IGJSON.object(normalized["owner"]),
               IGJSON.user(owner) != nil {
                normalized["user"] = owner
            } else {
                var synthesized: [String: Any] = [
                    "pk": user.id,
                    "username": user.userName,
                ]
                if let avatar = user.avatar { synthesized["profile_pic_url"] = avatar }
                normalized["user"] = synthesized
            }
        }
        if normalized["code"] == nil,
           let shortcode = IGJSON.string(normalized["shortcode"]) {
            normalized["code"] = shortcode
        }
        if normalized["taken_at"] == nil,
           let stamp = normalized["taken_at_timestamp"] {
            normalized["taken_at"] = stamp
        }
        if normalized["like_count"] == nil {
            if let count = IGJSON.object(normalized["edge_liked_by"])?["count"] {
                normalized["like_count"] = count
            } else if let count = IGJSON.object(
                normalized["edge_media_preview_like"]
            )?["count"] {
                normalized["like_count"] = count
            }
        }
        if normalized["comment_count"] == nil {
            normalized["comment_count"] =
                IGJSON.object(normalized["edge_media_to_comment"])?["count"]
        }
        if normalized["caption"] == nil,
           let edges = IGJSON.object(normalized["edge_media_to_caption"])?["edges"],
           let first = IGJSON.array(edges).first,
           let text = IGJSON.object(first["node"])?["text"] {
            normalized["caption"] = ["text": text]
        }
        if normalized["media_type"] == nil {
            normalized["media_type"] = (normalized["is_video"] as? Bool == true) ? 2 : 1
        }
        if normalized["video_versions"] == nil,
           let video = IGJSON.string(normalized["video_url"]) {
            normalized["video_versions"] = [["url": video]]
        }
        if normalized["carousel_media"] == nil,
           let edges = IGJSON.object(normalized["edge_sidecar_to_children"])?["edges"] {
            let children = IGJSON.array(edges).compactMap { IGJSON.object($0["node"]) }
            if !children.isEmpty {
                normalized["carousel_media"] = children
            }
        }
        return IGJSON.media(normalized)
    }

    func userFeed(userId: String, cursor: String?) async throws -> (items: [IGMedia], next: String?) {
        var url = "\(base)/api/v1/feed/user/\(userId)/?count=12"
        if let cursor = cursor {
            url += "&max_id=\(cursor)"
        }
        let json = try await request(url)
        let items = IGJSON.array(json["items"]).compactMap { IGJSON.media($0) }
        return (items, IGJSON.string(json["next_max_id"]))
    }

    // MARK: - 当前账号

    /// 用 cookie 里已有的登录态问一次「我是谁」。
    ///
    /// 登录页只保证 cookie 拿到了，用户名要另外补；原生页的「我」和侧边栏
    /// 账号行都靠它显示，不再把 `ds_user_id` 的数字当名字。
    func currentUser() async throws -> (id: String, userName: String)? {
        let endpoints = [
            "\(base)/api/v1/accounts/edit/web_form_data/",
            "\(base)/api/v1/users/\(userId)/info/",
        ]
        for endpoint in endpoints {
            guard let json = try? await request(endpoint) else { continue }
            if let form = IGJSON.object(json["form_data"]) ?? IGJSON.object(json["user"]) {
                if let userName = IGJSON.string(form["username"]) ?? IGJSON.string(form["user_name"]) {
                    let id = IGJSON.identifier(form["pk"]) ?? IGJSON.identifier(form["id"]) ?? userId
                    return (id, userName)
                }
            }
            if let user = IGJSON.user(json["user"]) {
                return (user.id, user.userName)
            }
        }
        return nil
    }

    // MARK: - 单条帖子

    func media(pk: String) async throws -> IGMedia {
        let json = try await request("\(base)/api/v1/media/\(Self.mediaID(pk))/info/")
        let items = IGJSON.array(json["items"])
        guard let media = items.compactMap({ IGJSON.media($0) }).first else {
            throw IGError(message: "帖子已删除或不可见", needLogin: false)
        }
        return media
    }

    // MARK: - 互动

    /// 点赞。网页版实际请求的是
    /// `POST /api/v1/web/likes/{media_id}/like/`（复数 `likes` + media id）。
    func like(mediaId: String) async throws {
        try await setLiked(mediaId, action: "like")
    }

    /// 取消点赞。网页版实际请求的是
    /// `POST /api/v1/web/likes/{media_id}/unlike/`。
    func unlike(mediaId: String) async throws {
        try await setLiked(mediaId, action: "unlike")
    }

    /// 点赞 / 取消点赞共用一套请求：cookie、`X-CSRFToken`（cookie 里的
    /// `csrftoken`）、桌面 UA、`X-IG-App-ID` 都跟读接口完全一致，不需要额外签名。
    private func setLiked(_ mediaId: String, action: String) async throws {
        let id = Self.mediaID(mediaId)
        _ = try await request(
            "\(base)/api/v1/web/likes/\(id)/\(action)/",
            method: "POST",
            formBody: "media_id=\(id)",
            interaction: true
        )
    }

    func comments(mediaId: String) async throws -> [IGComment] {
        let json = try await request(
            "\(base)/api/v1/media/\(Self.mediaID(mediaId))/comments/?can_support_threading=true&permalink_enabled=false"
        )
        return IGJSON.array(json["comments"]).compactMap { IGJSON.comment($0) }
    }

    @discardableResult
    func addComment(mediaId: String, text: String) async throws -> IGComment? {
        let id = Self.mediaID(mediaId)
        let json = try await request(
            "\(base)/api/v1/web/comments/add/\(id)/",
            method: "POST",
            formBody: "comment_text=\(Self.percentEncode(text))",
            interaction: true
        )
        return IGJSON.comment(json["comment"])
    }

    /// Instagram 部分入口返回的是 `<media pk>_<user pk>` 复合 id，而媒体、评论
    /// 和点赞接口的路径只认前半段数字 pk。统一在这里收口，避免某个入口漏掉。
    static func mediaID(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = value.firstIndex(of: "_") else { return value }
        let prefix = value[..<separator]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return value }
        return String(prefix)
    }

    // MARK: - 底层

    private func request(
        _ url: String,
        method: String = "GET",
        formBody: String? = nil,
        /// 「写」操作（点赞 / 评论）被拒时不要报「登录失效」：
        /// 首页还能刷就说明登录是好的，那是风控。
        interaction: Bool = false
    ) async throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw IGError(message: "请求地址非法", needLogin: false)
        }
        var urlRequest = URLRequest(url: target)
        urlRequest.httpMethod = method
        if let formBody = formBody {
            urlRequest.httpBody = formBody.data(using: .utf8)
            urlRequest.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
        }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(appID, forHTTPHeaderField: "X-IG-App-ID")
        urlRequest.setValue(asbdID, forHTTPHeaderField: "X-ASBD-ID")
        // 网页版只有拿到真实 claim 才带这个头。以前这里缺省填 `"0"`，
        // 等于主动告诉服务端「这个会话没有 claim」，点赞 / 评论更容易被判
        // feedback_required。没有就不发，让服务端按 cookie 自己判断。
        if let claim = IGSession.value(inHeader: cookie, named: "x-ig-www-claim"),
           !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlRequest.setValue(
                Self.sanitizeHeader(claim),
                forHTTPHeaderField: "X-IG-WWW-Claim"
            )
        }
        urlRequest.setValue("1", forHTTPHeaderField: "X-Instagram-AJAX")
        urlRequest.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        urlRequest.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        urlRequest.setValue("https://www.instagram.com/", forHTTPHeaderField: "Origin")
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        urlRequest.setValue("zh_CN", forHTTPHeaderField: "X-IG-App-Locale")
        urlRequest.setValue("zh_CN", forHTTPHeaderField: "X-IG-Device-Locale")
        urlRequest.setValue("zh_CN", forHTTPHeaderField: "X-IG-Mapped-Locale")
        urlRequest.setValue("28800", forHTTPHeaderField: "X-IG-Time-Zone-Offset")
        urlRequest.setValue("3brTvw==", forHTTPHeaderField: "X-IG-Capabilities")
        urlRequest.setValue("WIFI", forHTTPHeaderField: "X-IG-Connection-Type")
        urlRequest.setValue("Liger", forHTTPHeaderField: "X-FB-HTTP-Engine")
        let safeCookie = IGSession.normalizeCookieHeader(cookie)
        if !safeCookie.isEmpty {
            urlRequest.setValue(safeCookie, forHTTPHeaderField: "Cookie")
        }
        // csrf 以 Store 灌进来的值为准；没灌时直接回退到 cookie 里的
        // `csrftoken`，避免写操作因为漏了一次 `pushCredentials()` 就 403。
        let rawCSRF =
            csrfToken.isEmpty
                ? (IGSession.value(inHeader: cookie, named: "csrftoken") ?? "")
                : csrfToken
        let safeCSRF = Self.sanitizeHeader(rawCSRF)
        if !safeCSRF.isEmpty {
            urlRequest.setValue(safeCSRF, forHTTPHeaderField: "X-CSRFToken")
        }

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeHTML = trimmed.hasPrefix("<")

        let shortURL = url.split(separator: "?").first.map(String.init) ?? url
        let head = String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        FlareDiagnostics.shared.record(
            .instagram,
            status >= 400 ? "ERR" : "RES",
            "\(method) \(shortURL) → \(status) · \(data.count)B · interaction=\(interaction) · \(head)"
        )
        FlareDiagnostics.shared.record(
            .instagram, "STATE",
            "cookie=\(cookie.isEmpty ? "空" : "\(cookie.count)字符") · csrf=\(csrfToken.isEmpty ? "空" : "有")"
        )

        // 401 才是明确的未登录；403 不一定是掉登录 —— POST 少了 csrftoken、
        // 或者被风控拦一下都会 403。先看 body，只有登录页 / login_required
        // 才判定失效，其它 403 交给上层重试 GET。
        if status == 401 {
            throw interaction ? IGError.interactionDenied : IGError.notLoggedIn
        }
        // Instagram 出错时也给 JSON，先把 message 捞出来再判断。
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = IGJSON.string(json["message"]) ?? ""
        if message == "login_required" || message == "checkpoint_required" {
            throw interaction ? IGError.interactionDenied : IGError.notLoggedIn
        }
        // 风控最常见的是 HTTP 200 + `feedback_required`。以前这里当成成功
        // 直接返回，用户看到的就是「点了赞没反应，也不报错」。
        if message == "feedback_required" || message == "spam" {
            throw interaction
                ? IGError.interactionDenied
                : IGError(
                    message: "Instagram 触发了风控（feedback_required），请稍后再试或切换网络",
                    needLogin: false
                )
        }
        if looksLikeHTML {
            // 只有真的是登录 / 验证码页才算掉登录；其它 HTML 多半是风控页，
            // 不要把用户踢回登录界面。
            let lower = trimmed.lowercased()
            if lower.contains("/accounts/login") || lower.contains("loginform") || lower.contains("checkpoint") {
                throw interaction ? IGError.interactionDenied : IGError.notLoggedIn
            }
            throw IGError(
                message: "Instagram 返回了网页而不是数据（HTTP \(status)），可能被风控拦截，请稍后再试或切换网络",
                needLogin: false
            )
        }
        guard (200..<300).contains(status) else {
            throw IGError(
                message: message.isEmpty ? "请求失败（HTTP \(status)）" : message,
                needLogin: false
            )
        }
        if interaction, json.isEmpty {
            // 点赞 / 取消点赞在部分网页会话里就是 204 或空 body；HTTP 2xx 已经
            // 成功，不能因为「没 JSON 可解析」再把用户刚点亮的爱心回滚。
            return [:]
        }
        guard !json.isEmpty else {
            throw IGError(message: "接口返回格式异常", needLogin: false)
        }
        // 写操作即使 200 也可能 `status: fail`，别让它静默成功。
        if interaction, IGJSON.string(json["status"]) == "fail" {
            throw IGError(
                message: message.isEmpty ? "Instagram 拒绝了这次操作，稍后再试" : message,
                needLogin: false
            )
        }
        return json
    }

    /// HTTP 头只能放可见 ASCII。换行 / 中文 / 控制字符会让 `setValue` 抛
    /// ObjC 异常 —— 那是 SIGABRT，Kotlin 那边也接不住，表现就是登录成功后闪退。
    static func sanitizeHeader(_ value: String) -> String {
        IGSession.sanitizeHeader(value)
    }

    /// 接口要一个稳定的设备 id，随便造一个存下来就行。
    private static let deviceUUID: String = {
        let key = "instagram.device_uuid"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()
}

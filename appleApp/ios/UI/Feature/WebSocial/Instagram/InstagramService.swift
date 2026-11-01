import Foundation

/// Instagram 网页版 v1 接口。
///
/// 登录态只需要 cookie 加上固定的 `X-IG-App-ID`，没有别的签名 —— 这也是
/// 它比小红书省事的地方。cookie 掉线时接口返回 401 或 `login_required`，
/// 统一翻译成 `IGError.needLogin`。
final class InstagramService {
    static let shared = InstagramService()

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
        let media = edges.compactMap { IGJSON.media($0["node"]) }
        let next = IGJSON.string(IGJSON.object(connection?["page_info"])?["end_cursor"])
        return (user, media, next)
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
        let json = try await request("\(base)/api/v1/media/\(pk)/info/")
        let items = IGJSON.array(json["items"])
        guard let media = items.compactMap({ IGJSON.media($0) }).first else {
            throw IGError(message: "帖子已删除或不可见", needLogin: false)
        }
        return media
    }

    // MARK: - 互动

    /// 点赞 / 取消点赞。
    ///
    /// 网页版走的就是这两个接口，只要 `X-CSRFToken`（cookie 里的 `csrftoken`）
    /// 和 `X-Instagram-AJAX`，不需要额外的签名。
    func setLiked(_ liked: Bool, mediaId: String) async throws {
        let action = liked ? "like" : "unlike"
        _ = try await request(
            "\(base)/api/v1/web/likes/\(mediaId)/\(action)/",
            method: "POST",
            formBody: "media_id=\(mediaId)",
            interaction: true
        )
    }

    func comments(mediaId: String) async throws -> [IGComment] {
        let json = try await request(
            "\(base)/api/v1/media/\(mediaId)/comments/?can_support_threading=true&permalink_enabled=false"
        )
        return IGJSON.array(json["comments"]).compactMap { IGJSON.comment($0) }
    }

    @discardableResult
    func addComment(mediaId: String, text: String) async throws -> IGComment? {
        let json = try await request(
            "\(base)/api/v1/web/comments/add/\(mediaId)/",
            method: "POST",
            formBody: "comment_text=\(Self.percentEncode(text))",
            interaction: true
        )
        return IGJSON.comment(json["comment"])
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
        // 网页版会把这个 claim 带上；缺了的时候点赞容易被当成未登录。
        urlRequest.setValue(
            Self.sanitizeHeader(CookieJar.value(inHeader: cookie, named: "x-ig-www-claim") ?? "0"),
            forHTTPHeaderField: "X-IG-WWW-Claim"
        )
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
        let safeCookie = Self.sanitizeHeader(cookie)
        if !safeCookie.isEmpty {
            urlRequest.setValue(safeCookie, forHTTPHeaderField: "Cookie")
        }
        let safeCSRF = Self.sanitizeHeader(csrfToken)
        if !safeCSRF.isEmpty {
            urlRequest.setValue(safeCSRF, forHTTPHeaderField: "X-CSRFToken")
        }

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeHTML = trimmed.hasPrefix("<")

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
        guard !json.isEmpty else {
            throw IGError(message: "接口返回格式异常", needLogin: false)
        }
        return json
    }

    /// HTTP 头只能放可见 ASCII。换行 / 中文 / 控制字符会让 `setValue` 抛
    /// ObjC 异常 —— 那是 SIGABRT，Kotlin 那边也接不住，表现就是登录成功后闪退。
    static func sanitizeHeader(_ value: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars
        where scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F {
            result.unicodeScalars.append(scalar)
        }
        return result
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

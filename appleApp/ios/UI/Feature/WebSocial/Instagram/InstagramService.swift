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
    private let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"

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
        // 这是 App 的接口，参数照抄一份；少一个 `reason` 就可能 400。
        var query: [String] = [
            "is_prefetch=false",
            "feed_view_info=[]",
            "phone_id=\(Self.deviceUUID)",
            "battery_level=100",
            "timezone_offset=28800",
            "is_pull_to_refresh=false",
            "is_charging=0",
            "will_sound_on=1",
            "is_dark_mode=0",
            "reason=pull_to_refresh",
        ]
        if let cursor = cursor {
            query.append("max_id=\(cursor)")
        }
        let url = "\(base)/api/v1/feed/timeline/?\(query.joined(separator: "&"))"
        let json = try await request(url)

        var items: [IGMedia] = []
        for entry in IGJSON.array(json["feed_items"]) {
            // 时间线里混着「推荐关注」「故事」这类非帖子条目，只取有媒体的。
            if let media = IGJSON.media(entry["media_or_ad"]) {
                items.append(media)
            }
        }
        return (items, IGJSON.string(json["next_max_id"]))
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

    // MARK: - 单条帖子

    func media(pk: String) async throws -> IGMedia {
        let json = try await request("\(base)/api/v1/media/\(pk)/info/")
        let items = IGJSON.array(json["items"])
        guard let media = items.compactMap({ IGJSON.media($0) }).first else {
            throw IGError(message: "帖子已删除或不可见", needLogin: false)
        }
        return media
    }

    // MARK: - 底层

    private func request(_ url: String) async throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw IGError(message: "请求地址非法", needLogin: false)
        }
        var request = URLRequest(url: target)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(appID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(asbdID, forHTTPHeaderField: "X-ASBD-ID")
        request.setValue("0", forHTTPHeaderField: "X-IG-WWW-Claim")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFToken")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 {
            throw IGError.notLoggedIn
        }
        // Instagram 出错时也给 JSON，先把 message 捞出来再判断。
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = IGJSON.string(json["message"]) ?? ""
        if message == "login_required" || message == "checkpoint_required" {
            throw IGError.notLoggedIn
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

    /// 接口要一个稳定的设备 id，随便造一个存下来就行。
    private static let deviceUUID: String = {
        let key = "instagram.device_uuid"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()
}

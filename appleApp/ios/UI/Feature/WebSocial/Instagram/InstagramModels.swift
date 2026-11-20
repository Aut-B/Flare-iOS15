import Foundation
import CoreGraphics

/// 登录态相关的纯字符串 / cookie 工具。
///
/// 放在 Models 里是刻意的：`LogicTests` 只编译 Models + StateIsolator，
/// 不编译 `InstagramService`。隔离器和 Store 都要判断「这段 cookie 还能不能
/// 当登录态用」，逻辑必须放在两边都能看到的地方，否则测试目标直接编不过。
nonisolated enum IGSession {
    static let loggedOutKey = "instagram.loggedOut"

    /// HTTP 头只能放可见 ASCII。换行 / 中文 / 控制字符会让 `setValue` 抛
    /// ObjC 异常 —— 那是 SIGABRT，Kotlin 那边也接不住。
    static func sanitizeHeader(_ value: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars
        where scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// 去掉换行并清洗成可安全放进请求头的形式。
    static func normalizeCookieHeader(_ raw: String) -> String {
        let flattened =
            raw
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
        return sanitizeHeader(flattened)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func value(inHeader header: String, named name: String) -> String? {
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let index = piece.firstIndex(of: "=") else { continue }
            if String(piece[piece.startIndex..<index]) == name {
                return String(piece[piece.index(after: index)...])
            }
        }
        return nil
    }

    /// 有非空 `sessionid` 才算一条可用的 Instagram 登录态。
    static func hasUsableSession(_ header: String) -> Bool {
        let safe = sanitizeHeader(header)
        guard let value = value(inHeader: safe, named: "sessionid") else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 从系统 cookie 仓库拼请求头。过期的 cookie 不要，否则会把一个早就
    /// 失效的 `sessionid` 当成「已登录」重新捡回来。
    static func header(from cookies: [HTTPCookie], domainSuffix: String) -> String {
        let now = Date()
        return cookies
            .filter { cookie in
                cookie.domain.contains(domainSuffix)
                    && !cookie.value.isEmpty
                    && (cookie.expiresDate == nil || cookie.expiresDate! > now)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

/// Instagram 的一个用户。
struct IGUser: Identifiable, Hashable {
    let id: String
    let userName: String
    let fullName: String
    let avatar: String?
    /// 粉丝数 / 帖子数，主页头部要用；首页时间线里拿不到就是 nil。
    let followerCount: Int?
    let postCount: Int?
    let biography: String?

    var displayName: String {
        fullName.isEmpty ? userName : fullName
    }
}

/// 轮播里的一项：可能是一张图，也可能是一段视频（视频也带封面）。
struct IGMediaItem: Identifiable, Hashable {
    let id: String
    let image: String?
    let video: String?
    let aspect: CGFloat

    var isVideo: Bool { video != nil }
}

/// Instagram 的一条帖子。轮播（carousel）已经把子项摊平成 `items`，
/// `images` 仍然保留全部图片地址，`videoURL` 指向第一条视频。
struct IGMedia: Identifiable, Hashable {
    let id: String
    /// 短码，用来拼 `https://www.instagram.com/p/<code>/`。
    let shortcode: String
    let user: IGUser
    /// 逐项媒体，顺序和网页一致；多图 / 视频混排靠它。
    let items: [IGMediaItem]
    let images: [String]
    let videoURL: String?
    let caption: String
    let takenAt: Date
    let likeCount: Int
    let commentCount: Int
    let isVideo: Bool
    let isCarousel: Bool
    /// 当前账号有没有点过赞。网页版接口里叫 `has_liked`。
    let hasLiked: Bool
    /// 首图宽高比（宽 / 高）。接口给了尺寸，拿来定版式高度，
    /// 免得图片加载前后列表跳动。
    let aspect: CGFloat

    var cover: String? { images.first }

    /// 帖子链接，长按/分享时用。
    var webURL: String { "https://www.instagram.com/p/\(shortcode)/" }
}

/// 一条评论。
struct IGComment: Identifiable, Hashable {
    let id: String
    let userName: String
    let avatar: String?
    let text: String
    let createdAt: Date

    var displayName: String { userName.isEmpty ? "instagram" : userName }
}

/// Instagram 接口出错。
struct IGError: LocalizedError {
    let message: String
    /// 登录失效（`login_required` / `checkpoint_required` / 401）时置 true，
    /// 上层据此把界面切回「重新登录」。
    let needLogin: Bool

    var errorDescription: String? { message }

    static let notLoggedIn = IGError(
        message: "Instagram 登录已失效，请在「Instagram」页面重新登录",
        needLogin: true
    )

    /// 点赞 / 评论这类「写」操作被拒。
    ///
    /// 首页还能刷就说明 cookie 是好的，`login_required` 多半是风控或者少了
    /// 某个头部，这时候**不能**把用户踢回登录页 —— 那只会让能刷的首页也没了。
    static let interactionDenied = IGError(
        message: "Instagram 拒绝了这次操作（首页还能刷，说明登录没掉，多半是风控）。稍后再试，或点「网页版」在网页里操作。",
        needLogin: false
    )
}

// MARK: - JSON 解析

/// Instagram 的 v1 接口返回的是没有 schema 的大对象，用 `JSONSerialization`
/// 逐字段读比硬套 Codable 稳 —— 字段经常增删，Codable 一崩整页就空了。
enum IGJSON {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    static func date(_ value: Any?) -> Date {
        let seconds = int(value)
        guard seconds > 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// 字段不存在时给 nil，而不是 0 —— 「0 粉丝」和「不知道」是两回事。
    static func optionalInt(_ value: Any?) -> Int? {
        guard value != nil else { return nil }
        return int(value)
    }

    /// `image_versions2.candidates` 里挑最宽的那张。
    static func bestImage(_ media: [String: Any]) -> String? {
        bestImageInfo(media)?.url
    }

    /// 顺手把宽高比也带出来，版式高度要用。
    static func bestImageInfo(_ media: [String: Any]) -> (url: String, aspect: CGFloat)? {
        let candidates = array(object(media["image_versions2"])?["candidates"])
        // 以前取「最宽」的那张，等于永远拿原图（往往 1440~2160 宽）。6S 解码
        // 一张就几百毫秒，首页十几张图叠起来就是「照片要很久很久才出来」。
        // 改成在宽度 <= 1080 的候选里取最大的一张，清晰度够用、解码量砍一半以上；
        // 全都比 1080 大时才退回最窄的一张。
        let byWidth = candidates.sorted { int($0["width"]) < int($1["width"]) }
        let preferred =
            byWidth.last(where: { int($0["width"]) <= 1080 })
                ?? byWidth.first
        if let url = string(preferred?["url"]) {
            let width = CGFloat(int(preferred?["width"]))
            let height = CGFloat(int(preferred?["height"]))
            let aspect = (width > 0 && height > 0) ? width / height : 1
            return (url, min(max(aspect, 0.5), 2.0))
        }
        // 少数接口只给 `display_url` / `thumbnail_url`。
        if let url = string(media["display_url"]) ?? string(media["thumbnail_url"]) {
            return (url, 1)
        }
        return nil
    }

    /// 6S 等老机型拉 1080p/更高码率容易一直转圈或只播开头。
    /// 按短边取 720p 以内最大的一档，全都更大时才退回最小的一档；
    /// 只要存在渐进式 mp4 就不用 HLS 分片，避免老机型分片缓冲不动。
    static func videoURL(_ media: [String: Any]) -> String? {
        let versions = array(media["video_versions"]).compactMap { version -> (url: String, shortEdge: Int, isStreaming: Bool)? in
            guard let url = string(version["url"]) else { return nil }
            let width = int(version["width"])
            let height = int(version["height"])
            let shortEdge = width > 0 && height > 0 ? min(width, height) : 0
            let lowercased = url.lowercased()
            let isStreaming = lowercased.contains(".m3u8") || lowercased.contains(".mpd")
            return (url, shortEdge, isStreaming)
        }
        guard !versions.isEmpty else { return nil }
        let progressive = versions.filter { !$0.isStreaming }
        let pool = progressive.isEmpty ? versions : progressive
        let sized = pool.filter { $0.shortEdge > 0 }
        let preferred =
            sized.filter { $0.shortEdge <= 720 }.max { $0.shortEdge < $1.shortEdge }
                ?? sized.min { $0.shortEdge < $1.shortEdge }
        return preferred?.url ?? pool[0].url
    }

    static func user(_ value: Any?) -> IGUser? {
        guard let object = object(value) else { return nil }
        // 时间线里 `pk` 是数字，主页接口里叫 `id`。
        guard let id = identifier(object["pk"]) ?? identifier(object["id"]) else { return nil }
        let userName = string(object["username"]) ?? string(object["user_name"]) ?? ""
        guard !userName.isEmpty else { return nil }
        return IGUser(
            id: id,
            userName: userName,
            fullName: string(object["full_name"]) ?? "",
            avatar: string(object["profile_pic_url"]) ?? string(object["profile_pic_url_hd"]),
            followerCount: optionalInt(object["follower_count"]),
            postCount: optionalInt(object["media_count"]),
            biography: string(object["biography"])
        )
    }

    static func media(_ value: Any?) -> IGMedia? {
        guard let object = object(value) else { return nil }
        // 广告、推荐位里没有 `pk`，直接丢掉。
        guard let pk = identifier(object["pk"]) else { return nil }
        guard let user = user(object["user"]) else { return nil }

        let carousel = array(object["carousel_media"])
        var items: [IGMediaItem] = []
        for (offset, child) in carousel.enumerated() {
            let info = bestImageInfo(child)
            let video = IGJSON.videoURL(child)
            guard info != nil || video != nil else { continue }
            items.append(
                IGMediaItem(
                    id: identifier(child["pk"]) ?? "\(pk)-\(offset)",
                    image: info?.url,
                    video: video,
                    aspect: info?.aspect ?? 1
                )
            )
        }
        if items.isEmpty {
            // 单帖：图片可能没有（纯视频帖只给 `video_versions` + 封面），
            // 所以不能拿 `bestImageInfo` 当门槛 —— 以前写成
            // `if items.isEmpty, let info = bestImageInfo(object)`，
            // 没有 `image_versions2` 的视频帖会整条被丢进 `guard` 返回 nil，
            // 表现就是「视频帖在时间线里消失」。
            let video = IGJSON.videoURL(object)
            let info = bestImageInfo(object)
            if info != nil || video != nil {
                items.append(
                    IGMediaItem(
                        id: pk,
                        image: info?.url,
                        video: video,
                        // 没有封面时用 1:1 兜底，`aspectRatio` 才不会算出 0。
                        aspect: info?.aspect ?? 1
                    )
                )
            }
        }
        let images = items.compactMap(\.image)
        let videoURL = items.compactMap(\.video).first
        guard !images.isEmpty || videoURL != nil else { return nil }
        let aspect = items.first?.aspect ?? 1

        let mediaType = int(object["media_type"])
        return IGMedia(
            id: string(object["id"]) ?? pk,
            shortcode: string(object["code"]) ?? "",
            user: user,
            items: items,
            images: images,
            videoURL: videoURL,
            caption: string(IGJSON.object(object["caption"])?["text"]) ?? "",
            takenAt: date(object["taken_at"]),
            likeCount: int(object["like_count"]),
            commentCount: int(object["comment_count"]),
            isVideo: mediaType == 2 || videoURL != nil,
            isCarousel: mediaType == 8 || !carousel.isEmpty || items.count > 1,
            hasLiked: (object["has_liked"] as? Bool) ?? (int(object["has_liked"]) == 1),
            aspect: aspect
        )
    }

    static func comment(_ value: Any?) -> IGComment? {
        guard let object = object(value) else { return nil }
        guard let text = string(object["text"]) else { return nil }
        let user = IGJSON.object(object["user"]) ?? [:]
        let id = identifier(object["pk"]) ?? identifier(object["id"]) ?? UUID().uuidString
        return IGComment(
            id: id,
            userName: string(user["username"]) ?? "",
            avatar: string(user["profile_pic_url"]),
            text: text,
            createdAt: date(object["created_at"])
        )
    }

    /// `pk` 有时是数字有时是字符串，统一成字符串；0 或缺失算无效。
    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty, text != "0" { return text }
        if value is NSNumber {
            let number = int(value)
            return number > 0 ? String(number) : nil
        }
        return nil
    }
}

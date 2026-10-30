import Foundation
import CoreGraphics

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

/// Instagram 的一条帖子。轮播（carousel）已经把子图摊平成 `images`，
/// 视频帖的 `videoURL` 有值，封面仍在 `images` 里。
struct IGMedia: Identifiable, Hashable {
    let id: String
    /// 短码，用来拼 `https://www.instagram.com/p/<code>/`。
    let shortcode: String
    let user: IGUser
    let images: [String]
    let videoURL: String?
    let caption: String
    let takenAt: Date
    let likeCount: Int
    let commentCount: Int
    let isVideo: Bool
    let isCarousel: Bool
    /// 首图宽高比（宽 / 高）。接口给了尺寸，拿来定版式高度，
    /// 免得图片加载前后列表跳动。
    let aspect: CGFloat

    var cover: String? { images.first }

    /// 帖子链接，长按/分享时用。
    var webURL: String { "https://www.instagram.com/p/\(shortcode)/" }
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
        let widest =
            candidates.max { lhs, rhs in
                int(lhs["width"]) < int(rhs["width"])
            }
        if let url = string(widest?["url"]) {
            let width = CGFloat(int(widest?["width"]))
            let height = CGFloat(int(widest?["height"]))
            let aspect = (width > 0 && height > 0) ? width / height : 1
            return (url, min(max(aspect, 0.5), 2.0))
        }
        // 少数接口只给 `display_url` / `thumbnail_url`。
        if let url = string(media["display_url"]) ?? string(media["thumbnail_url"]) {
            return (url, 1)
        }
        return nil
    }

    static func videoURL(_ media: [String: Any]) -> String? {
        let versions = array(media["video_versions"])
        let best = versions.max { lhs, rhs in
            int(lhs["width"]) < int(rhs["width"])
        }
        return string(best?["url"])
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
        var images: [String] = []
        var aspect: CGFloat = 1
        var videoURL = IGJSON.videoURL(object)
        for child in carousel {
            if let info = bestImageInfo(child) {
                if images.isEmpty { aspect = info.aspect }
                images.append(info.url)
            }
            if videoURL == nil { videoURL = IGJSON.videoURL(child) }
        }
        if images.isEmpty, let info = bestImageInfo(object) {
            aspect = info.aspect
            images.append(info.url)
        }
        guard !images.isEmpty else { return nil }

        let mediaType = int(object["media_type"])
        return IGMedia(
            id: string(object["id"]) ?? pk,
            shortcode: string(object["code"]) ?? "",
            user: user,
            images: images,
            videoURL: videoURL,
            caption: string(IGJSON.object(object["caption"])?["text"]) ?? "",
            takenAt: date(object["taken_at"]),
            likeCount: int(object["like_count"]),
            commentCount: int(object["comment_count"]),
            isVideo: mediaType == 2 || videoURL != nil,
            isCarousel: mediaType == 8 || !carousel.isEmpty,
            aspect: aspect
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

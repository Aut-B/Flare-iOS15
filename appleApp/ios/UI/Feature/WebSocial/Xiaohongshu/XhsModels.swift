import Foundation
import CoreGraphics

/// 小红书的一个用户。
struct XhsUser: Hashable {
    let id: String
    let name: String
    let avatar: String?

    static let empty = XhsUser(id: "", name: "", avatar: nil)
}

/// 用户主页资料。
struct XhsProfile: Hashable {
    let id: String
    let name: String
    let avatar: String?
    let desc: String
    let redId: String
    let location: String
    let follows: String
    let fans: String
    let liked: String

    var user: XhsUser { XhsUser(id: id, name: name, avatar: avatar) }
}

/// 小红书的一条笔记。
struct XhsNote: Identifiable, Hashable {
    let id: String
    let title: String
    let desc: String
    let user: XhsUser
    let images: [String]
    var likedCount: String
    let isVideo: Bool
    /// 首图宽高比（宽 / 高），用来定版式高度。
    let aspect: CGFloat
    /// 图片地址统一成 https。
    ///
    /// 小红书偶尔会下发 `http://sns-webpic...`：iOS 的 ATS 直接拦掉，
    /// 表现就是「第一张能看、第二张一片灰」。`//` 开头的协议相对地址同理。
    static func normalizedImageURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        return value
    }
    /// 视频直链。首页流里就带着，有它就能原生播放，不用再请求详情。
    var videoURL: String? = nil
    /// 当前账号有没有点过赞 / 收藏。
    var liked: Bool = false
    var collected: Bool = false
    var commentCount: String = ""
    var shareCount: String = ""
    /// 小红书 2023 年之后给笔记加了 `xsec_token`，评论、用户主页这些接口
    /// 都要带上它，否则会被当成「来源不明」直接拒掉。
    var xsecToken: String = ""

    var cover: String? { images.first }

    var displayTitle: String {
        if !title.isEmpty { return title }
        // 很多笔记没有标题，用正文第一行顶上。
        return desc.split(separator: "\n").first.map(String.init) ?? ""
    }

    var webURL: String {
        "https://www.xiaohongshu.com/explore/\(id)"
    }
}

/// 一条评论（`subComments` 是楼中楼，接口只给前几条）。
struct XhsComment: Identifiable, Hashable {
    let id: String
    let content: String
    let user: XhsUser
    let likeCount: String
    let time: String
    var liked: Bool = false
    var subComments: [XhsComment] = []
    var subCount: Int = 0
}

struct XhsError: LocalizedError {
    let message: String
    let needLogin: Bool

    var errorDescription: String? { message }

    static let notLoggedIn = XhsError(
        message: "小红书登录已失效，请在「小红书」页面重新登录",
        needLogin: true
    )
    static let signFailed = XhsError(
        message: "签名没拿到，网页可能还没加载完。再点一次；连续失败就点「重新登录」重新灌一次 cookie",
        needLogin: false
    )
    static let signerUnavailable = XhsError(
        message: "网页签名脚本没加载出来，可能是小红书改了页面结构",
        needLogin: false
    )
}

// MARK: - JSON 解析

enum XhsJSON {
    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber, number.intValue != 0 { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return text == "true" || text == "1"
        }
        return false
    }

    /// 互动数在接口里是「1.2万」这种字符串，原样显示最省事。
    static func countText(_ value: Any?) -> String {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.intValue > 0 ? number.stringValue : "" }
        let number = int(value)
        return number > 0 ? "\(number)" : ""
    }

    static func user(_ value: Any?) -> XhsUser? {
        guard let object = object(value) else { return nil }
        guard let id = string(object["userId"]) ?? string(object["user_id"]) ?? string(object["id"]) else {
            return nil
        }
        return XhsUser(
            id: id,
            name: string(object["nickname"]) ?? string(object["nick_name"]) ?? string(object["name"]) ?? "",
            avatar: string(object["avatar"]) ?? string(object["image"]) ?? string(object["images"])
        )
    }

    /// 图片地址藏在好几层里，挨个试。
    static func imageURL(_ value: Any?) -> (url: String, aspect: CGFloat)? {
        guard let object = object(value) else {
            if let text = string(value) { return (text, 0) }
            return nil
        }
        var candidates: [String] = []
        for key in ["url_default", "urlDefault", "url_pre", "urlPre", "url"] {
            if let value = string(object[key]), !value.isEmpty { candidates.append(value) }
        }
        for info in array(object["info_list"]) {
            if let value = string(info["url"]), !value.isEmpty { candidates.append(value) }
        }
        // iOS 15 的 UIImage 解不了 avif。服务端偶尔还是会先给 avif，
        // 这里优先挑 jpg / 非 avif 的地址，实在没有才用第一个。
        let url = candidates.first(where: { $0.lowercased().contains(".jpg") || $0.lowercased().contains(".jpeg") })
            ?? candidates.first(where: { !$0.lowercased().contains("avif") })
            ?? candidates.first
        var aspect: CGFloat = 0
        let width = CGFloat(int(object["width"]))
        let height = CGFloat(int(object["height"]))
        if width > 0, height > 0 {
            aspect = width / height
        }
        guard let resolved = url else { return nil }
        return (normalizedImageURL(resolved), aspect)
    }

    /// 视频直链。`video.media.stream` 里按编码分了 h264 / h265 / av1 三档，
    /// 挑第一个有 `master_url` 的；老设备上 h264 最稳，所以放最前面。
    static func videoURL(_ value: Any?) -> String? {
        guard let video = object(value), let media = object(video["media"]) else { return nil }
        guard let stream = object(media["stream"]) else { return nil }
        for codec in ["h264", "h265", "av1"] {
            let list = array(stream[codec])
            guard let first = list.first else { continue }
            if let url = string(first["master_url"]) {
                return url
            }
            if let backups = first["backup_urls"] as? [String], let url = backups.first {
                return url
            }
        }
        return nil
    }

    static func note(_ value: Any?) -> XhsNote? {
        guard let raw = object(value) else { return nil }
        // 首页流里是 `{id, model_type, note_card}`，详情接口里也是这个形状。
        let card = object(raw["note_card"]) ?? raw
        guard let id = string(raw["id"]) ?? string(card["note_id"]) ?? string(card["id"]) else { return nil }
        let user = self.user(card["user"]) ?? self.user(card["user_info"]) ?? XhsUser.empty

        var images: [String] = []
        var aspect: CGFloat = 0
        for item in array(card["image_list"]) {
            if let info = imageURL(item) {
                if images.isEmpty { aspect = info.aspect }
                images.append(info.url)
            }
        }
        if images.isEmpty, let info = imageURL(card["cover"]) {
            aspect = info.aspect
            images.append(info.url)
        }
        guard !images.isEmpty else { return nil }
        if aspect <= 0 { aspect = 0.75 }

        let isVideo = string(card["type"]) == "video" || object(card["video"]) != nil
        let interact = object(card["interact_info"])

        return XhsNote(
            id: id,
            title: string(card["title"]) ?? string(card["display_title"]) ?? "",
            desc: string(card["desc"]) ?? "",
            user: user,
            images: images.filter { !$0.isEmpty },
            likedCount: countText(interact?["liked_count"]),
            isVideo: isVideo,
            aspect: min(max(aspect, 0.5), 2.0),
            videoURL: isVideo ? videoURL(card["video"]) : nil,
            liked: bool(interact?["liked"]),
            collected: bool(interact?["collected"]),
            commentCount: countText(interact?["comment_count"]),
            shareCount: countText(interact?["share_count"]),
            xsecToken: string(raw["xsec_token"]) ?? string(card["xsec_token"]) ?? ""
        )
    }

    static func comment(_ value: Any?) -> XhsComment? {
        guard let raw = object(value) else { return nil }
        guard let id = string(raw["id"]) ?? string(raw["comment_id"]) else { return nil }
        let user = self.user(raw["user_info"]) ?? self.user(raw["user"]) ?? XhsUser.empty
        let subs = array(raw["sub_comments"]).compactMap { comment($0) }
        return XhsComment(
            id: id,
            content: string(raw["content"]) ?? "",
            user: user,
            likeCount: countText(raw["like_count"]),
            time: timeText(raw["create_time"]),
            liked: bool(raw["liked"]),
            subComments: subs,
            subCount: max(int(raw["sub_comment_count"]), subs.count)
        )
    }

    /// `create_time` 是毫秒时间戳，转成「3 分钟前」这种。
    static func timeText(_ value: Any?) -> String {
        var stamp = int(value)
        if stamp <= 0 { return "" }
        if stamp > 10_000_000_000 { stamp /= 1000 }
        let date = Date(timeIntervalSince1970: TimeInterval(stamp))
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60))分钟前" }
        if delta < 86_400 { return "\(Int(delta / 3600))小时前" }
        if delta < 86_400 * 7 { return "\(Int(delta / 86_400))天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 用户资料。`otherinfo` 把资料放在 `data.basic_info`，`selfinfo` 的
    /// 形状换过好几次，所以这里层层往下找。
    static func profile(_ value: Any?) -> XhsProfile? {
        guard let raw = object(value) else { return nil }
        let candidates: [Any?] = [
            raw["basic_info"],
            raw["basicInfo"],
            raw["user_info"],
            raw["userInfo"],
            raw["user"],
            raw["data"],
            raw,
        ]
        for candidate in candidates {
            if let profile = directProfile(candidate) { return profile }
        }
        return deepProfile(raw, depth: 0)
    }

    private static func directProfile(_ value: Any?) -> XhsProfile? {
        guard let object = object(value) else { return nil }
        guard let id = string(object["user_id"]) ?? string(object["userId"]) ?? string(object["userid"]) else {
            return nil
        }
        let name = string(object["nickname"]) ?? string(object["nick_name"]) ?? string(object["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        var stats: [String: String] = [:]
        for item in array(object["interactions"]) {
            if let type = string(item["type"]), let count = string(item["count"]) {
                stats[type] = count
            }
        }
        return XhsProfile(
            id: id,
            name: name,
            avatar: string(object["image"]) ?? string(object["avatar"]),
            desc: string(object["desc"]) ?? string(object["description"]) ?? "",
            redId: string(object["red_id"]) ?? string(object["redId"]) ?? "",
            location: string(object["ip_location"]) ?? string(object["location"]) ?? "",
            follows: stats["follows"] ?? countText(object["follows"]),
            fans: stats["fans"] ?? countText(object["fans"]),
            liked: stats["liked"] ?? countText(object["liked"])
        )
    }

    private static func deepProfile(_ value: Any, depth: Int) -> XhsProfile? {
        guard depth < 4 else { return nil }
        if let profile = directProfile(value) { return profile }
        guard let object = object(value) else { return nil }
        for key in object.keys {
            if let child = object[key] as? [String: Any], let profile = deepProfile(child, depth: depth + 1) {
                return profile
            }
        }
        return nil
    }
}

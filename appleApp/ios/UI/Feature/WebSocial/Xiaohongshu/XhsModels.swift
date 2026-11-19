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
    /// 详情接口偶尔只回一张图，这里允许把首页卡片上更完整的图片列表补回来。
    var images: [String]
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
    /// 这个 `xsec_token` 是从哪儿拿的（`pc_feed` / `pc_note` / `pc_user` / `pc_search` ...）。
    ///
    /// 服务端会校验 token 和 `xsec_source` 是否配对：首页卡片发的 token 拿
    /// `xsec_source=pc_user` 去请求评论会回「当前笔记暂时无法浏览」。以前这里
    /// 硬编码只试 `pc_feed` / `pc_note` 两种，从用户主页或搜索点进来的笔记就
    /// 永远对不上，表现为「详情能看、评论打不开」。
    var xsecSource: String = "pc_feed"

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
        // 顺序就是清晰度优先级：`url` 是原图，`url_pre` 是中等预览，`url_default`
        // 是最小的缩略图。以前把 `url_default` 放最前面，首页卡片和详情页拿到的
        // 全是缩略图，用户看到的就是「图片好糊」。info_list 里的地址通常是原图，
        // 作为补充放在最后，避免它抢在 url 前面挑了低分辨率那条。
        for key in ["url", "urlRaw", "url_raw", "url_pre", "urlPre", "url_default", "urlDefault"] {
            if let value = string(object[key]), !value.isEmpty { candidates.append(value) }
        }
        for info in array(object["info_list"]) {
            if let value = string(info["url"]), !value.isEmpty { candidates.append(value) }
        }
        // iOS 15 的 UIImage 解不了 avif（webp 能解）。按上面的清晰度顺序，取第一条
        // 非 avif 的地址；只有全都 avif 时才退回第一条。
        let url = candidates.first(where: { !$0.lowercased().contains("avif") })
            ?? candidates.first
        var aspect: CGFloat = 0
        let width = CGFloat(int(object["width"]))
        let height = CGFloat(int(object["height"]))
        if width > 0, height > 0 {
            aspect = width / height
        }
        guard let resolved = url else { return nil }
        return (XhsNote.normalizedImageURL(resolved), aspect)
    }

    /// 视频直链。`video.media.stream` 里按编码分了 h264 / h265 / av1 三档，
    /// 老设备上 h264 最稳，所以编码顺序不变。
    /// 同一编码可能有多档清晰度：优先短边 <= 720 的最大一档，避免 6S 先拉 1080p/4K
    /// 后缓冲不动；只要存在渐进式 mp4 就不用 HLS 分片，全都没有时才退回分片。
    static func videoURL(_ value: Any?) -> String? {
        guard let video = object(value), let media = object(video["media"]) else { return nil }
        guard let stream = object(media["stream"]) else { return nil }
        for codec in ["h264", "h265", "av1"] {
            let candidates = array(stream[codec]).compactMap { item -> (url: String, shortEdge: Int, isStreaming: Bool)? in
                let url =
                    string(item["master_url"])
                        ?? (item["backup_urls"] as? [String])?.first(where: { !$0.isEmpty })
                guard let url else { return nil }
                let width = int(item["width"])
                let height = int(item["height"])
                let shortEdge = width > 0 && height > 0 ? min(width, height) : 0
                let lowercased = url.lowercased()
                let isStreaming = lowercased.contains(".m3u8") || lowercased.contains(".mpd")
                return (url, shortEdge, isStreaming)
            }
            guard !candidates.isEmpty else { continue }
            let progressive = candidates.filter { !$0.isStreaming }
            let pool = progressive.isEmpty ? candidates : progressive
            let sized = pool.filter { $0.shortEdge > 0 }
            let preferred =
                sized.filter { $0.shortEdge <= 720 }.max { $0.shortEdge < $1.shortEdge }
                    ?? sized.min { $0.shortEdge < $1.shortEdge }
            return preferred?.url ?? pool[0].url
        }
        return nil
    }

    static func note(_ value: Any?, defaultSource: String = "pc_feed") -> XhsNote? {
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

        let data = object(raw["data"]) ?? [:]
        let source = object(raw["note_card"]) ?? object(data["note_card"]) ?? card

        return XhsNote(
            id: id,
            title: string(source["title"]) ?? string(source["display_title"]) ?? "",
            desc: string(source["desc"]) ?? "",
            user: user,
            images: images.filter { !$0.isEmpty },
            likedCount: countText(interact?["liked_count"]),
            isVideo: isVideo,
            // 详情页要按原比例展示长图（截图、竖版海报），下限不能卡在 0.5，
            // 否则 1:5 的长图会被裁成 1:2 的「短图」。瀑布流另有 0.4 的裁剪，
            // 不受这里影响。
            aspect: min(max(aspect, 0.28), 2.0),
            videoURL: isVideo ? videoURL(source["video"]) : nil,
            liked: bool(interact?["liked"]),
            collected: bool(interact?["collected"]),
            commentCount: countText(interact?["comment_count"]),
            shareCount: countText(interact?["share_count"]),
            // 详情接口（`/api/sns/web/v1/feed`）把 xsec_token 放在 `data` 这一层，
            // 不在 `note_card` 里。以前只从卡片和顶层找，刷出来的新 token 永远是空，
            // 评论区就一直拿到旧 token -> 反复「当前笔记暂时无法浏览」。
            xsecToken: string(raw["xsec_token"])
                ?? string(source["xsec_token"])
                ?? string(data["xsec_token"])
                ?? "",
            // 卡片上有时会回 `xsec_source`，有就照抄；没有的话由调用方
            // （首页 = pc_feed、用户主页 = pc_user、搜索 = pc_search）自己填。
            // 详情接口同样可能把它放在 `data` 层，跟 xsec_token 一样三级回退。
            xsecSource: string(raw["xsec_source"])
                ?? string(source["xsec_source"])
                ?? string(data["xsec_source"])
                ?? defaultSource
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

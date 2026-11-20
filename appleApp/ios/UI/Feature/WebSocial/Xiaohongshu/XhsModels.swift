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
    /// 首页 DOM 兜底先回来时经常只有作者名、没有 id；详情/接口后到时要能补上。
    var user: XhsUser
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
        var value = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        return value
    }

    /// 小红书图床把原图 token 放在 `!` 前，`!nd_dft_wlteh_webp_3` 只是 CDN
    /// 生成的有损 WebP 展示变体；`!nd_prv...` 更是缩略预览。首页半屏卡片把它
    /// 放大后就会出现块状「碎图」，所以下载前要按 token 换回原图地址。
    ///
    /// `sns-webpic-*` 的路径是 `/<时间戳>/<hash>/[spectrum/]<token>!nd_dft...`，
    /// 原图 CDN 只认最后的 token；带 `spectrum/` 的图要把这个前缀一起保留。
    /// DOM/HTML 里的 `!` 可能被写成 `%21`，两种都要能截断。
    static func imageToken(_ raw: String) -> String? {
        let value = normalizedImageURL(raw)
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              (host.hasSuffix(".xhscdn.com") || host == "ci.xiaohongshu.com"),
              !host.hasPrefix("sns-avatar")
        else { return nil }
        var path = components.percentEncodedPath
        for marker in ["!", "%21"] {
            if let range = path.range(of: marker, options: .caseInsensitive) {
                path = String(path[..<range.lowerBound])
            }
        }
        path = path.replacingOccurrences(of: "/wmwatermark/", with: "/")
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let spectrum = parts.firstIndex(where: { $0.lowercased() == "spectrum" }) {
            parts = Array(parts[spectrum...])
        } else if parts.count > 1 {
            parts = [parts[parts.count - 1]]
        }
        let token = parts.joined(separator: "/")
        guard token.count >= 8 else { return nil }
        return token
    }

    /// `sns-webpic-*` 域名只提供压缩/加水印变体；只删 `!` 后缀、域名不变时
    /// 经常 403/404，于是又退回模糊的展示图。原图要走 `sns-img-bd`。
    static func originalImageURL(_ raw: String) -> String? {
        guard let token = imageToken(raw) else { return nil }
        return "https://sns-img-bd.xhscdn.com/\(token)"
    }

    /// 去掉 `!nd_dft...` 之类处理后缀；query 是裁剪/缩放命令时也一并去掉。
    static func strippedImageURL(_ raw: String) -> String? {
        let source = normalizedImageURL(raw)
        var value = source
        for marker in ["!", "%21"] {
            if let range = value.range(of: marker, options: .caseInsensitive) {
                value = String(value[..<range.lowerBound])
            }
        }
        if let components = URLComponents(string: value),
           let query = components.percentEncodedQuery?.lowercased(),
           query.contains("imageview") || query.contains("x-oss-process") || query.contains("format/") {
            var clean = components
            clean.percentEncodedQuery = nil
            value = clean.string ?? value
        }
        guard value != source else { return nil }
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

    /// 图片列表在接口和 SSR 里出现过三种写法，元素既可能是字典，也可能是纯地址；
    /// 只按 `[[String: Any]]` 转会把字符串数组和混合数组整段转成空数组。
    static func imageList(_ value: Any?) -> [Any] {
        if let list = value as? [Any] { return list }
        if let object = value as? [String: Any] { return [object] }
        if let text = value as? String, !text.isEmpty { return [text] }
        return []
    }

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
        // 不少首页卡片只给昵称/头像，没有 userId。以前这里直接返回 nil，
        // 整个作者被降级成 `XhsUser.empty`，作者名就再也点不进去了。
        // id 先留空，等详情接口回来后再补；只要还有名字或头像就保留。
        let id = string(object["userId"]) ?? string(object["user_id"]) ?? string(object["id"]) ?? ""
        let name = string(object["nickname"]) ?? string(object["nick_name"]) ?? string(object["name"]) ?? ""
        let avatar = string(object["avatar"]) ?? string(object["image"]) ?? string(object["images"])
        guard !id.isEmpty || !name.isEmpty || avatar != nil else { return nil }
        return XhsUser(id: id, name: name, avatar: avatar)
    }

    /// 图片地址藏在好几层里，挨个试。
    static func imageURL(_ value: Any?) -> (url: String, aspect: CGFloat)? {
        guard let object = object(value) else {
            // 字符串形态同样要走 https 归一化：小红书会下发 `http://sns-webpic...`，
            // 原样返回会被 ATS 拦掉，最后就是一块灰。
            if let text = string(value) { return (XhsNote.normalizedImageURL(text), 0) }
            return nil
        }
        var candidates: [(url: String, score: Int)] = []
        // `url` 仍是完整展示图，`url_pre` 是预览，`url_default` 是缩略图。
        // 旧顺序把 `url_pre` 放在 `url_default` 前面，url 缺失时会先挑到更小的
        // `!nd_prv` 预览图；现在按清晰度打分，不让 preview 抢到 default 前面。
        for (key, score) in [
            ("url", 100), ("urlRaw", 110), ("url_raw", 110),
            ("url_default", 90), ("urlDefault", 90),
            ("url_pre", 20), ("urlPre", 20),
        ] {
            if let value = string(object[key]), !value.isEmpty {
                candidates.append((XhsNote.normalizedImageURL(value), score))
            }
        }
        let infoList = imageList(object["info_list"]) + imageList(object["infoList"])
        for item in infoList {
            if let info = XhsJSON.object(item) {
                guard let value = string(info["url"]), !value.isEmpty else { continue }
                let scene = (string(info["image_scene"]) ?? string(info["imageScene"]) ?? "").uppercased()
                // info_list 常同时给 WB_PRV 和 WB_DFT；取前者会拿到预览图。
                let score = scene == "WB_DFT" ? 95 : (scene == "WB_PRV" ? 10 : 60)
                candidates.append((XhsNote.normalizedImageURL(value), score))
            } else if let value = string(item), !value.isEmpty {
                candidates.append((XhsNote.normalizedImageURL(value), 60))
            }
        }
        // iOS 15 的 UIImage 解不了 avif（webp 能解）。先排除 avif，再按清晰度取
        // 最高分；只有全都 avif 时才保留原顺序。
        let usable = candidates.filter { !$0.url.lowercased().contains("avif") }
        let pool = usable.isEmpty ? candidates : usable
        var resolved: (url: String, score: Int)?
        for candidate in pool {
            var score = candidate.score
            let lower = (candidate.url.removingPercentEncoding ?? candidate.url).lowercased()
            if lower.contains("!nd_prv") || lower.contains("nd_prv_") || lower.contains("!nc_") {
                score -= 80
            }
            if let current = resolved {
                if score > current.score { resolved = (url: candidate.url, score: score) }
            } else {
                resolved = (url: candidate.url, score: score)
            }
        }
        var aspect: CGFloat = 0
        let width = CGFloat(int(object["width"]))
        let height = CGFloat(int(object["height"]))
        if width > 0, height > 0 {
            aspect = width / height
        } else if let info = XhsJSON.object(infoList.first) {
            let infoWidth = CGFloat(int(info["width"]))
            let infoHeight = CGFloat(int(info["height"]))
            if infoWidth > 0, infoHeight > 0 { aspect = infoWidth / infoHeight }
        }
        guard let url = resolved?.url else { return nil }
        return (url, aspect)
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
        // 接口/SSR 混用过 `image_list`、`imageList`、`images` 三种键；
        // 以前只认第一种，遇到后两种就只剩 cover，一张图。
        for list in [card["image_list"], card["imageList"], card["images"]] {
            for item in imageList(list) {
                guard let info = imageURL(item) else { continue }
                if images.isEmpty { aspect = info.aspect }
                if !images.contains(info.url) { images.append(info.url) }
            }
        }
        if images.isEmpty {
            for key in ["cover", "image", "cover_url", "coverUrl"] {
                if let info = imageURL(card[key]) {
                    aspect = info.aspect
                    images.append(info.url)
                    break
                }
            }
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

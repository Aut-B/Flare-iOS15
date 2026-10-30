import Foundation
import CoreGraphics

/// 小红书的一个用户。
struct XhsUser: Hashable {
    let id: String
    let name: String
    let avatar: String?
}

/// 小红书的一条笔记。
struct XhsNote: Identifiable, Hashable {
    let id: String
    let title: String
    let desc: String
    let user: XhsUser
    let images: [String]
    let likedCount: String
    let isVideo: Bool
    /// 首图宽高比（宽 / 高），用来定版式高度。
    let aspect: CGFloat

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

struct XhsError: LocalizedError {
    let message: String
    let needLogin: Bool

    var errorDescription: String? { message }

    static let notLoggedIn = XhsError(
        message: "小红书登录已失效，请在「小红书」页面重新登录",
        needLogin: true
    )
    static let signFailed = XhsError(
        message: "签名没拿到，网页可能没加载完，稍后重试",
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
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }

    /// 互动数在接口里是「1.2万」这种字符串，原样显示最省事。
    static func countText(_ value: Any?) -> String {
        if let text = value as? String, !text.isEmpty { return text }
        let number = int(value)
        return number > 0 ? "\(number)" : ""
    }

    static func user(_ value: Any?) -> XhsUser? {
        guard let object = object(value) else { return nil }
        guard let id = string(object["userId"]) ?? string(object["user_id"]) else { return nil }
        return XhsUser(
            id: id,
            name: string(object["nickname"]) ?? string(object["nick_name"]) ?? "",
            avatar: string(object["avatar"]) ?? string(object["image"])
        )
    }

    /// 图片地址藏在好几层里，挨个试。
    static func imageURL(_ value: Any?) -> (url: String, aspect: CGFloat)? {
        guard let object = object(value) else { return nil }
        var url = string(object["url_default"])
            ?? string(object["urlDefault"])
            ?? string(object["url_pre"])
            ?? string(object["url"])
        var aspect: CGFloat = 0
        if url == nil {
            for info in array(object["info_list"]) {
                if let candidate = string(info["url"]) {
                    url = candidate
                    break
                }
            }
        }
        let width = CGFloat(int(object["width"]))
        let height = CGFloat(int(object["height"]))
        if width > 0, height > 0 {
            aspect = width / height
        }
        guard let resolved = url else { return nil }
        return (resolved, aspect)
    }

    static func note(_ value: Any?) -> XhsNote? {
        guard let raw = object(value) else { return nil }
        // 首页流里是 `{id, model_type, note_card}`，详情接口里也是这个形状。
        let card = object(raw["note_card"]) ?? raw
        guard let id = string(raw["id"]) ?? string(card["note_id"]) else { return nil }
        guard let user = user(card["user"]) else { return nil }

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

        return XhsNote(
            id: id,
            title: string(card["title"]) ?? string(card["display_title"]) ?? "",
            desc: string(card["desc"]) ?? "",
            user: user,
            images: images,
            likedCount: countText(object(card["interact_info"])?["liked_count"]),
            isVideo: string(card["type"]) == "video" || object(card["video"]) != nil,
            aspect: min(max(aspect, 0.5), 2.0)
        )
    }
}

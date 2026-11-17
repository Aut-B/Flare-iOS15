import Foundation

/// 小红书 Web 接口的 query 值编码。
///
/// 单独成文件、不 import UIKit/WebKit，是为了能被 `LogicTests` 直接编译进来做
/// 回归断言 —— `XhsService` 依赖隐藏网页（`WKWebView` / `_webmsxyw`），
/// 纯逻辑测试目标里拉不动它。
///
/// 这里的每一条规则都由一条测试钉住（见 `XhsQueryEncodingTests`）：
/// 评论打不开时界面上只会显示服务端那句「当前笔记暂时无法浏览」，从错误信息
/// 看不出究竟是 token 过期、来源不匹配还是编码不对，只能靠测试把编码这一项锁死。
enum XhsQuery {
    /// query 值编码。
    ///
    /// 逗号必须手动移出白名单：`CharacterSet.urlQueryAllowed` 本身包含 `,` 和 `;`，
    /// 不动它们 `encode("jpg,webp")` 会原样返回。小红书网页版的 `image_formats`
    /// 走的是 `encodeURIComponent`，出来是 `jpg%2Cwebp`，而签名用的正是这条
    /// query 原文 —— 两者不一致，`X-S` 就对不上。
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+,;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 评论区请求的 query 串。
    ///
    /// 整条 query 会原样进入 `_webmsxyw` 参与签名，任何一处编码不一致都只会
    /// 表现成「评论打不开」，从错误信息里看不出是哪个字段。
    static func commentQuery(
        noteId: String,
        xsecToken: String,
        cursor: String?,
        xsecSource: String
    ) -> String {
        var parts = [
            "note_id=" + encode(noteId),
            "cursor=" + encode(cursor ?? ""),
            "top_comment_id=",
            "image_formats=" + encode("jpg,webp"),
        ]
        // 公开笔记的 token 可能本来就是空的：空 token 是合法请求，
        // 不能拼出一个 `xsec_token=` 空参数。
        if !xsecToken.isEmpty {
            parts.append("xsec_token=" + encode(xsecToken))
        }
        // 网页版评论区请求固定带 xsec_source；少了它服务端会认为「来源不明」，
        // 一律回「当前笔记暂时无法浏览」。
        parts.append("xsec_source=" + encode(xsecSource))
        return parts.joined(separator: "&")
    }
}

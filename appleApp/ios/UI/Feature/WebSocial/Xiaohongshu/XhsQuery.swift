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

    /// 用户主页笔记列表（`/api/sns/web/v1/user_posted`）的 query 串。
    ///
    /// 和评论同一个病根：`image_formats` 以前是直接拼字面量 `jpg,webp`，
    /// 逗号没走编码。这条 query 同样原样进 `_webmsxyw`，所以一样会让 `X-S`
    /// 对不上。用户主页整页空白 / 一直转圈就是它的表现之一。
    static func userPostedQuery(
        userId: String,
        cursor: String?,
        num: Int = 30
    ) -> String {
        let parts = [
            "num=" + String(num),
            "cursor=" + encode(cursor ?? ""),
            "user_id=" + encode(userId),
            "image_formats=" + encode("jpg,webp"),
        ]
        return parts.joined(separator: "&")
    }
}

/// 首页流一页的判定。
///
/// build131 的 461 响应体是 `{"code":0,"success":true,"msg":"成功","data":{}}`：
/// 只看业务 code 会把「服务端拒绝」误判成「这一页没有内容」，于是界面停在
/// 0 条、`hasMore` 还留着 true，看起来像一次成功的空列表。这里只做纯判定，
/// 不发请求、也不改任何请求参数，供 `XhsStore` 和纯逻辑测试共用。
nonisolated enum XhsFeedState: Equatable {
    /// 这一页拿到了笔记。
    case content
    /// 服务端返回成功，但一条都没有（461 的响应体也会长成这样）。
    case empty
    /// 服务端明确拒绝。
    case rejected(code: Int)

    /// 这一页之后还能不能继续翻页：只有真拿到内容才算「还有」。
    static func hasMore(after state: XhsFeedState) -> Bool {
        if case .content = state { return true }
        return false
    }

    /// 首屏拿不到内容时给用户的文案。
    ///
    /// `restriction` 是接口层已经生成的 461 / 403 / 登录态不完整文案，必须
    /// 原样保留，不能被网页兜底的通用文案盖掉；`fallback` 只在既没有拒绝
    /// 原因、也不是「成功但空」时才用。
    static func message(
        for state: XhsFeedState,
        restriction: String?,
        detail: String?,
        fallback: String
    ) -> String {
        if let restriction, !restriction.isEmpty { return restriction }
        switch state {
        case .content:
            return fallback
        case .empty:
            return "小红书接口返回了「成功」但首页是 0 条（服务端没给内容，可能与风控或登录态不完整有关）。点「重试」；持续这样就去网页版完成验证再回来"
        case .rejected(let code):
            if let detail, !detail.isEmpty {
                return "小红书返回 code \(code)：\(detail)"
            }
            return "小红书返回 code \(code)，稍后点「重试」"
        }
    }
}

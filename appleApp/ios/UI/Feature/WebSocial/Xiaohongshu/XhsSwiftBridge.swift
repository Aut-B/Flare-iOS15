import Foundation
import KotlinSharedUI

/// 把小红书的取数能力交给 Kotlin 侧用。
///
/// 小红书的接口要 `X-S` / `X-T`，这两个值只能在网页里用 `window._webmsxyw` 算，
/// Kotlin 侧没法复现。所以 Kotlin 那边只定义协议（`XhsBridge`），真正的请求
/// 还是走这里已经跑通的 `XhsService`（内部是隐藏 WKWebView + 签名）。
///
/// 数据以 JSON 字符串回传，字段见 Kotlin 侧的 `XhsJsonContract`。
///
/// 注意方法名：Kotlin 的 `suspend fun` 导出到 Swift 会带 `__` 前缀，并且是
/// `async throws` 形式（Kotlin/Native 同时生成了 completionHandler 版本）。
final class XhsSwiftBridge: NSObject, XhsBridge {
    func __homeFeed(
        cookie: String,
        cursor: String?,
        follow: Bool
    ) async throws -> String {
        XhsService.shared.cookie = cookie
        do {
            let page = try await XhsService.shared.homeFeed(cursor: cursor, follow: follow)
            return Self.encode(notes: page.notes, next: page.next)
        } catch {
            return Self.encode(error: error)
        }
    }

    func __note(
        cookie: String,
        id: String
    ) async throws -> String {
        XhsService.shared.cookie = cookie
        do {
            let note = try await XhsService.shared.note(id: id)
            return Self.encode(notes: [note], next: nil)
        } catch {
            return Self.encode(error: error)
        }
    }

    func __userNotes(
        cookie: String,
        userId: String,
        cursor: String?
    ) async throws -> String {
        XhsService.shared.cookie = cookie
        do {
            let page = try await XhsService.shared.userNotes(userId: userId, cursor: cursor)
            return Self.encode(notes: page.notes, next: page.next)
        } catch {
            return Self.encode(error: error)
        }
    }

    // MARK: - JSON

    private static func encode(notes: [XhsNote], next: String?) -> String {
        var payload: [String: Any] = ["items": notes.map(encode(note:))]
        if let next, !next.isEmpty {
            payload["next"] = next
        }
        return stringify(payload) ?? "{\"items\":[]}"
    }

    private static func encode(note: XhsNote) -> [String: Any] {
        [
            "id": note.id,
            "title": note.title,
            "desc": note.desc,
            "user": [
                "id": note.user.id,
                "name": note.user.name,
                "avatar": note.user.avatar ?? "",
            ],
            "images": note.images,
            "likedCount": note.likedCount,
            "isVideo": note.isVideo,
            "aspect": Double(note.aspect),
        ]
    }

    /// 出错时不抛异常（Kotlin 的 suspend 函数没标 `@Throws`，错误穿过边界
    /// 会变成未捕获异常），改成把 message 塞进 JSON，由 Kotlin 侧转成正常异常。
    private static func encode(error: Error) -> String {
        let message = (error as? XhsError)?.message ?? error.localizedDescription
        return stringify(["error": message]) ?? "{\"error\":\"小红书请求失败\"}"
    }

    private static func stringify(_ payload: [String: Any]) -> String? {
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

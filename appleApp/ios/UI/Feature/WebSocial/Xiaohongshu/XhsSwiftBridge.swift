import Foundation
import KotlinSharedUI

/// 把小红书的取数能力交给 Kotlin 侧用。
///
/// 小红书的接口要 `X-S` / `X-T`，这两个值只能在网页里用 `window._webmsxyw` 算，
/// Kotlin 侧没法复现。所以 Kotlin 那边只定义协议（`XhsBridge`），真正的请求
/// 还是走这里已经跑通的 `XhsService`（内部是隐藏 WKWebView + 签名）。
///
/// 数据以 JSON 字符串回传，字段见 Kotlin 侧的 `XhsJsonContract`。
final class XhsSwiftBridge: NSObject, XhsBridge {
    func homeFeed(
        cookie: String,
        cursor: String?,
        follow: Bool,
        completionHandler: @escaping (String?, Error?) -> Void
    ) {
        Task {
            XhsService.shared.cookie = cookie
            do {
                let page = try await XhsService.shared.homeFeed(cursor: cursor, follow: follow)
                completionHandler(Self.encode(notes: page.notes, next: page.next), nil)
            } catch {
                completionHandler(Self.encode(error: error), nil)
            }
        }
    }

    func note(
        cookie: String,
        id: String,
        completionHandler: @escaping (String?, Error?) -> Void
    ) {
        Task {
            XhsService.shared.cookie = cookie
            do {
                let note = try await XhsService.shared.note(id: id)
                completionHandler(Self.encode(notes: [note], next: nil), nil)
            } catch {
                completionHandler(Self.encode(error: error), nil)
            }
        }
    }

    func userNotes(
        cookie: String,
        userId: String,
        cursor: String?,
        completionHandler: @escaping (String?, Error?) -> Void
    ) {
        Task {
            XhsService.shared.cookie = cookie
            do {
                let page = try await XhsService.shared.userNotes(userId: userId, cursor: cursor)
                completionHandler(Self.encode(notes: page.notes, next: page.next), nil)
            } catch {
                completionHandler(Self.encode(error: error), nil)
            }
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

    /// 出错时不抛异常（Kotlin 的 suspend 函数没标 `@Throws`，错误传不过去），
    /// 改成把 message 塞进 JSON，由 Kotlin 侧转成正常的异常。
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

import Foundation
import os

/// 阅读器页面里的会话信标（`window.__INITIAL_STATE__.reader`）。
///
/// 正文接口要的 `ps`/`pc` 不是自己造的：`ps` 来自当前这一章阅读器页面的
/// `reader.psvts`，`pc` 来自 `reader.pclts`（没有就用 `_e(ct)` 现算）。
/// 拿不到就只能退回写死值，那时候接口大概率回 `{}` —— 也就是白屏。
struct WereadReaderSession: Sendable, Equatable {
    /// 章节 uid → ps 值。真实页面给的是对象，也见过单字符串的形态。
    var psvts: [String: String]
    /// 默认 ps（单字符串形态，或映射里认不出当前章时的兜底）。
    var defaultPs: String
    /// ct → pc 值。页面没给就留空，由调用方用 `_e(ct)` 补。
    var pclts: [String: String]
    /// 上报进度要用的 reader token。
    var token: String

    var isEmpty: Bool { defaultPs.isEmpty && psvts.isEmpty && pclts.isEmpty }

    /// 取当前章可用的 ps。
    func ps(for chapterUid: Int) -> String? {
        if let value = psvts[String(chapterUid)], !value.isEmpty { return value }
        // 有些页面用 `_e(chapterUid)` 当 key。
        let hashed = WereadCrypto.calcHash(String(chapterUid))
        if let value = psvts[hashed], !value.isEmpty { return value }
        return defaultPs.isEmpty ? nil : defaultPs
    }

    /// 取 ct 对应的 pc。
    func pc(for timestamp: Int) -> String? {
        let key = String(timestamp)
        if let value = pclts[key], !value.isEmpty { return value }
        // `readPclts` 把单字符串形态放在 `""` 下：整本书一个 pc。
        if let value = pclts[""], !value.isEmpty { return value }
        return nil
    }
}

/// 从阅读器页面 HTML 里抠出会话信标。
///
/// 页面结构会变，所以这里是「多路尝试 + 每个字段独立容错」：
/// 任何一步失败都不抛错，只是把对应字段留空交给上层决定。
enum WereadReaderSessionParser {
    static let log = Logger(subsystem: "dev.dimension.flare.weread", category: "session")

    /// 找 `window.__INITIAL_STATE__ = {...}` 并解析成字典。
    ///
    /// 不能用贪婪的 `(\{.*\})`：页面后面还有别的脚本，贪婪会把尾巴一起吃进来。
    /// 这里从 `{` 开始做花括号配平扫描，同时跳过字符串里的括号和转义。
    static func initialState(from html: String) -> [String: Any]? {
        guard let anchor = html.range(of: "__INITIAL_STATE__") else { return nil }
        let tail = html[anchor.upperBound...]
        guard let braceStart = tail.firstIndex(of: "{") else { return nil }
        guard let objectText = balancedObject(in: tail[braceStart...]) else { return nil }
        guard let data = objectText.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 从 `{` 开始配平到匹配的 `}`，返回这段子串（含两端花括号）。
    private static func balancedObject(in text: Substring) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        endIndex = text.index(after: index)
                        break
                    }
                default:
                    break
                }
            }
            if endIndex != nil { break }
            index = text.index(after: index)
        }

        guard let end = endIndex else { return nil }
        return String(text[text.startIndex..<end])
    }

    /// 解析出会话信标。拿不到返回 nil，调用方走回退。
    static func session(from html: String) -> WereadReaderSession? {
        guard let state = initialState(from: html) else {
            log.debug("weread: __INITIAL_STATE__ not found in reader html")
            return nil
        }
        // `reader` 有可能被包在 `data` 之类的外层里，先按常见位置找。
        let reader = state["reader"] as? [String: Any]
            ?? ((state["data"] as? [String: Any])?["reader"] as? [String: Any])
        guard let reader else {
            log.debug("weread: reader node missing in __INITIAL_STATE__")
            return nil
        }

        var session = WereadReaderSession(
            psvts: [:],
            defaultPs: "",
            pclts: [:],
            token: stringValue(reader["token"]) ?? ""
        )
        readPsVts(reader["psvts"], into: &session)
        readPclts(reader["pclts"], into: &session)
        if session.token.isEmpty {
            // token 也可能放在别处。
            session.token = stringValue(reader["wr_skey"]) ?? ""
        }
        log.debug(
            "weread: session parsed psvtsEntries=\(session.psvts.count, privacy: .public) defaultPs=\(!session.defaultPs.isEmpty, privacy: .public) pcltsEntries=\(session.pclts.count, privacy: .public) token=\(!session.token.isEmpty, privacy: .public)"
        )
        return session
    }

    private static func readPsVts(_ raw: Any?, into session: inout WereadReaderSession) {
        if let text = raw as? String, !text.isEmpty {
            // 单字符串形态：整本书一个 ps。
            session.defaultPs = text
            return
        }
        guard let map = raw as? [String: Any] else { return }
        for (key, value) in map {
            if let text = stringValue(value), !text.isEmpty {
                session.psvts[key] = text
            }
        }
    }

    private static func readPclts(_ raw: Any?, into session: inout WereadReaderSession) {
        if let text = raw as? String, !text.isEmpty {
            session.pclts[""] = text
            return
        }
        guard let map = raw as? [String: Any] else { return }
        for (key, value) in map {
            if let text = stringValue(value), !text.isEmpty {
                session.pclts[key] = text
            }
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}

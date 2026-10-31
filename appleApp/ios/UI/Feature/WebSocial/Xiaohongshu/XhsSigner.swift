import Foundation
import WebKit

/// 小红书的接口签名。
///
/// `edith.xiaohongshu.com` 的每个请求都要带 `X-S` / `X-T`，这对值由网页里的
/// `window._webmsxyw(path, data)` 算出来 —— 是混淆过的 JS，硬啃不划算。
/// 所以这里常驻一个**隐藏的 WKWebView** 打开小红书网页版，需要签名时直接在
/// 页面上下文里调用它，拿回签名和 body 字符串。
///
/// body 必须和参与签名的字符串逐字节一致，所以 JSON 也交给页面 `JSON.stringify`
/// 生成，原样发出去 —— 自己再序列化一次，key 顺序一变签名就白搭。
final class XhsSigner {
    static let shared = XhsSigner()

    private var webView: WKWebView?
    /// 当前登录 cookie；隐藏页面加载 / 重载时先灌进 WKWebsiteDataStore。
    private var cookieHeader: String = ""
    /// 已经灌进签名页的 cookie，避免每次取数都 reload。
    private var appliedCookieHeader: String = ""

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 签名结果：两个 header 加真正要发出去的 body。
    struct Signature {
        let xs: String
        let xt: String
        let body: String
    }

    // MARK: - 对外

    func sign(path: String, payload: [String: Any]) async throws -> Signature {
        try await prepareIfNeeded()

        let payloadJSON = try Self.jsonLiteral(payload)
        let script = """
        (function(){
          try {
            if (typeof window._webmsxyw !== 'function') {
              return JSON.stringify({error: 'missing'});
            }
            var data = \(payloadJSON);
            var body = JSON.stringify(data);
            var result = window._webmsxyw("\(path)", data);
            if (!result) { return JSON.stringify({error: 'empty'}); }
            return JSON.stringify({xs: result['X-s'], xt: result['X-t'], body: body});
          } catch (e) {
            return JSON.stringify({error: String(e)});
          }
        })()
        """

        let raw = try await evaluate(script)
        guard
            let data = raw.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw XhsError.signFailed
        }
        if let error = json["error"] as? String {
            throw error == "missing" ? XhsError.signerUnavailable : XhsError.signFailed
        }
        guard
            let xs = json["xs"] as? String,
            let xt = json["xt"] as? String,
            let body = json["body"] as? String,
            !xs.isEmpty
        else {
            throw XhsError.signFailed
        }
        return Signature(xs: xs, xt: xt, body: body)
    }

    /// 重新加载页面，签名脚本崩了的时候用。
    func reset() {
        DispatchQueue.main.async {
            let view = self.ensureWebView()
            let cookies = Self.cookies(fromHeader: self.cookieHeader)
            if cookies.isEmpty {
                view.reload()
            } else {
                self.write(cookies) { view.reload() }
            }
        }
    }

    /// 把登录 cookie 灌进签名页。
    ///
    /// `_webmsxyw` 会读页面里的 `a1` / `webId`，只在请求头里带 cookie 时，
    /// 隐藏页面仍然是匿名会话，算出来的签名会被服务端判无效。cookie 没变
    /// 就什么都不做，翻页时不会反复 reload。
    func applyCookies(_ header: String) {
        let normalized = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        DispatchQueue.main.async {
            guard self.appliedCookieHeader != normalized else { return }
            self.appliedCookieHeader = normalized
            self.cookieHeader = normalized
            let cookies = Self.cookies(fromHeader: normalized)
            guard !cookies.isEmpty else { return }
            self.write(cookies) {
                self.webView?.reload()
            }
        }
    }

    // MARK: - 页面准备

    private func prepareIfNeeded() async throws {
        // `webView` 是懒创建的：之前这里只轮询 `isSignerReady()`，
        // 但 `ensureWebView()` 从来没被调用过，`webView` 永远是 nil，
        // 每次请求都白等 16 秒再报「网页签名脚本没加载出来」。
        // 必须先在主线程把隐藏页面建出来。
        await MainActor.run {
            _ = self.ensureWebView()
        }
        // 最多等 16 秒，小红书首屏要跑完一大坨 bundle 才会有 `_webmsxyw`。
        for _ in 0..<40 {
            if await isSignerReady() { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw XhsError.signerUnavailable
    }

    private func isSignerReady() async -> Bool {
        let ready = try? await evaluate("typeof window._webmsxyw === 'function'")
        if let text = ready {
            return text == "true" || text == "1"
        }
        return false
    }

    /// 在页面里跑一段脚本，返回值统一转成字符串（布尔会变成 `"true"`）。
    private func evaluate(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let webView = self.webView else {
                    continuation.resume(throwing: XhsError.signerUnavailable)
                    return
                }
                webView.evaluateJavaScript(script) { value, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let text = value as? String {
                        continuation.resume(returning: text)
                        return
                    }
                    if let number = value as? NSNumber {
                        continuation.resume(returning: number.boolValue ? "true" : "false")
                        return
                    }
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// 把字典转成能直接塞进 JS 源码的对象字面量。
    private static func jsonLiteral(_ payload: [String: Any]) throws -> String {
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else {
            throw XhsError.signFailed
        }
        return text
    }

    /// 必须在主线程调用。
    private func ensureWebView() -> WKWebView {
        if let webView = webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        view.customUserAgent = Self.desktopUserAgent
        view.isHidden = true
        webView = view
        let load = {
            view.load(URLRequest(url: URL(string: "https://www.xiaohongshu.com/explore")!))
        }
        let cookies = Self.cookies(fromHeader: cookieHeader)
        if cookies.isEmpty {
            load()
        } else {
            write(cookies, completion: load)
        }
        return view
    }

    /// `Cookie:` 头 → `HTTPCookie`。域名统一写成 `.xiaohongshu.com`，
    /// 这样 www 和 edith 两个子域都能带上。
    private static func cookies(fromHeader header: String) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let index = piece.firstIndex(of: "=") else { continue }
            let name = String(piece[piece.startIndex..<index])
            let value = String(piece[piece.index(after: index)...])
            guard !name.isEmpty else { continue }
            if let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".xiaohongshu.com",
                .path: "/",
            ]) {
                result.append(cookie)
            }
        }
        return result
    }

    /// 把 cookie 写进默认 WKWebsiteDataStore，全部写完后回调。
    private func write(_ cookies: [HTTPCookie], completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}

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
            self.webView?.reload()
        }
    }

    // MARK: - 页面准备

    private func prepareIfNeeded() async throws {
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
        view.load(URLRequest(url: URL(string: "https://www.xiaohongshu.com/explore")!))
        webView = view
        return view
    }
}

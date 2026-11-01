import Foundation
import UIKit
import WebKit

/// 小红书的接口签名。
///
/// `edith.xiaohongshu.com` 的每个请求都要带 `X-S` / `X-T`，这对值由网页里的
/// `window._webmsxyw(path, data)` 算出来 —— 是混淆过的 JS，硬啃不划算。
/// 所以这里常驻一个隐藏的 WKWebView 打开小红书网页版，需要签名时直接在
/// 页面上下文里调用它，拿回签名和 body 字符串。
///
/// body 必须和参与签名的字符串逐字节一致，所以 JSON 也交给页面 `JSON.stringify`
/// 生成，原样发出去 —— 自己再序列化一次，key 顺序一变签名就白搭。
final class XhsSigner {
    static let shared = XhsSigner()

    private var webView: WKWebView?
    /// 承载隐藏页面的容器，挂在 key window 上（不可见、不吃点击）。
    ///
    /// 不挂在窗口上的 WKWebView 会被当成不可见页面：`requestAnimationFrame`
    /// 不跑、定时器被降频，页面里的签名脚本可能一直算不出结果。
    private var host: UIView?
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

    /// 内部失败原因，最后统一翻译成 `XhsError`。
    private enum Failure: Error {
        /// `_webmsxyw` 还没出现（页面没跑完 / 被跳去登录页）。
        case notReady
        /// 脚本在，但调用返回空 / 抛异常。
        case call(String)
        /// 返回值形状不认识。
        case shape(String)
    }

    // MARK: - 对外

    func sign(path: String, payload: [String: Any]) async throws -> Signature {
        let payloadJSON = try Self.jsonLiteral(payload)
        var lastFailure: Failure = .notReady

        // 页面偶尔会卡在「脚本在、算不出来」的半死状态，重载一次基本都能恢复。
        for attempt in 0..<3 {
            if attempt > 0 {
                await reloadPage()
            }
            do {
                try await waitUntilReady(timeout: attempt == 0 ? 16 : 14)
                return try await signOnce(path: path, payloadJSON: payloadJSON)
            } catch let failure as Failure {
                lastFailure = failure
                if case .notReady = failure {
                    continue
                }
                // 算签名失败：给页面一点时间（可能是 cookie 刚写进去还没生效）。
                try? await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                lastFailure = .call(error.localizedDescription)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        if case .notReady = lastFailure {
            throw XhsError.signerUnavailable
        }
        throw XhsError.signFailed
    }

    /// 重新加载页面，签名脚本崩了的时候用。
    func reset() {
        DispatchQueue.main.async {
            guard let view = self.webView else { return }
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
    func applyCookies(_ header: String, force: Bool = false) {
        let normalized = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        DispatchQueue.main.async {
            if !force, self.appliedCookieHeader == normalized { return }
            self.appliedCookieHeader = normalized
            self.cookieHeader = normalized
            let cookies = Self.cookies(fromHeader: normalized)
            guard !cookies.isEmpty else { return }
            self.write(cookies) {
                guard let view = self.webView else { return }
                // 页面正在加载时别 reload，否则会把 bundle 打断，签名永远好不了。
                if view.isLoading { return }
                view.reload()
            }
        }
    }

    // MARK: - 页面准备

    private func waitUntilReady(timeout: TimeInterval) async throws {
        await MainActor.run {
            _ = self.ensureWebView()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isSignerReady() { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw Failure.notReady
    }

    private func reloadPage() async {
        await MainActor.run {
            let view = self.ensureWebView()
            let cookies = Self.cookies(fromHeader: self.cookieHeader)
            if cookies.isEmpty {
                view.reload()
            } else {
                self.write(cookies) { view.reload() }
            }
        }
        // 等新页面开始跑 bundle，避免刚 reload 就判定「没准备好」。
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private func isSignerReady() async -> Bool {
        let ready = try? await evaluate("typeof window._webmsxyw === 'function'")
        if let text = ready {
            return text == "true" || text == "1"
        }
        return false
    }

    private func signOnce(path: String, payloadJSON: String) async throws -> Signature {
        let script = """
        (function(){
          try {
            if (typeof window._webmsxyw !== 'function') {
              return JSON.stringify({error: 'missing'});
            }
            var data = \(payloadJSON);
            var body = JSON.stringify(data);
            var result = window._webmsxyw("\(path)", data);
            if (typeof result === 'string') {
              try { result = JSON.parse(result); } catch (e) {}
            }
            if (!result) { return JSON.stringify({error: 'empty'}); }
            function pick(obj, names) {
              for (var i = 0; i < names.length; i++) {
                var value = obj[names[i]];
                if (typeof value === 'string' && value.length > 0) { return value; }
              }
              return null;
            }
            var xs = null;
            var xt = null;
            if (typeof result === 'object') {
              xs = pick(result, ['X-s', 'x-s', 'xs', 'X-S']);
              xt = pick(result, ['X-t', 'x-t', 'xt', 'X-T']);
              if (!xs && Object.prototype.toString.call(result) === '[object Array]') {
                xs = result[0];
                xt = result[1];
              }
            }
            if (!xs) {
              return JSON.stringify({error: 'shape:' + Object.prototype.toString.call(result)});
            }
            return JSON.stringify({xs: xs, xt: xt || '', body: body});
          } catch (e) {
            return JSON.stringify({error: 'exception:' + String(e)});
          }
        })()
        """

        let raw = try await evaluate(script)
        guard
            let data = raw.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw Failure.shape(String(raw.prefix(120)))
        }
        if let error = json["error"] as? String {
            if error == "missing" {
                throw Failure.notReady
            }
            throw Failure.call(error)
        }
        guard
            let xs = json["xs"] as? String,
            !xs.isEmpty,
            let body = json["body"] as? String
        else {
            throw Failure.shape(String(raw.prefix(120)))
        }
        let xt = json["xt"] as? String ?? ""
        return Signature(xs: xs, xt: xt, body: body)
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
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 1600),
            configuration: configuration
        )
        view.customUserAgent = Self.desktopUserAgent
        view.isUserInteractionEnabled = false
        webView = view
        attachToWindow(view)
        // `load` 会作为 `() -> Void` 传出去；不写类型会被推断成 `() -> WKNavigation?`。
        let load: () -> Void = {
            guard let url = URL(string: "https://www.xiaohongshu.com/explore") else { return }
            _ = view.load(URLRequest(url: url))
        }
        let cookies = Self.cookies(fromHeader: cookieHeader)
        if cookies.isEmpty {
            load()
        } else {
            write(cookies, completion: load)
        }
        return view
    }

    /// 把隐藏页面塞进当前窗口的最底层。
    ///
    /// 尺寸保持 390x844（页面按桌面版渲染），但外层容器只有 2x2 且几乎透明，
    /// 用户看不到也点不到；窗口切到后台再回来时，JS 也不会被系统冻住。
    private func attachToWindow(_ view: WKWebView) {
        guard host == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard
            let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        else {
            return
        }
        let container = UIView(frame: CGRect(x: -4, y: -4, width: 2, height: 2))
        container.clipsToBounds = true
        container.alpha = 0.02
        container.isUserInteractionEnabled = false
        view.frame = CGRect(x: 0, y: 0, width: 1280, height: 1600)
        container.addSubview(view)
        window.addSubview(container)
        window.sendSubviewToBack(container)
        host = container
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

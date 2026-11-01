import Foundation
import UIKit
import WebKit

/// 在一个「真的」网页里跑请求，把接口返回的 JSON 偷出来。
///
/// 小红书和微信读书的 web 接口都要签名 + 浏览器指纹。用 `URLSession` 从原生
/// 发出去，签名算得再对也会被判 `code -1`：TLS 指纹、`X-S-Common`、
/// `a1` 会话这些东西对不上。所以换个思路 —— 让真正的网页自己去请求，
/// 我们在 `fetch` / `XMLHttpRequest` 上挂个钩子，把响应原样搬回原生。
///
/// 请求是页面发的，签名、cookie、TLS、指纹天然全对，风控无从下手。
///
/// 页面挂在一个 1x1、几乎透明的容器里贴在 key window 最底层。必须挂在窗口上：
/// 不在视图层级里的 WKWebView 会被系统当成不可见页面，`requestAnimationFrame`
/// 和滚动监听都被降频，懒加载永远不触发。
final class WebPageHarvester: NSObject, WKNavigationDelegate {
    struct Message {
        let url: String
        let body: String
    }

    private static let handlerName = "flareharvest"

    private var webView: WKWebView?
    private var host: UIView?
    private var handler: Handler?
    private var onMessage: ((Message) -> Void)?
    private var onFinish: (() -> Void)?

    private var startURL = ""
    private var userAgent = ""
    private var cookieHeader = ""
    private var cookieDomain = ""

    var isRunning: Bool { webView != nil }

    // MARK: - 对外

    func start(
        url: String,
        userAgent: String,
        cookie: String,
        cookieDomain: String,
        patterns: [String],
        onFinish: (() -> Void)? = nil,
        onMessage: @escaping (Message) -> Void
    ) {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.teardown()
            self.startURL = url
            self.userAgent = userAgent
            self.cookieHeader = cookie
            self.cookieDomain = cookieDomain
            self.onMessage = onMessage
            self.onFinish = onFinish
            self.build(patterns: patterns)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 在页面上下文里跑一段 JS，拿字符串结果。
    func evaluate(_ script: String, completion: ((String) -> Void)? = nil) {
        DispatchQueue.main.async {
            guard let view = self.webView else {
                completion?("")
                return
            }
            view.evaluateJavaScript(script) { value, _ in
                if let text = value as? String {
                    completion?(text)
                } else if let number = value as? NSNumber {
                    completion?(number.stringValue)
                } else {
                    completion?("")
                }
            }
        }
    }

    /// 往下滚一屏，触发页面自己的懒加载。
    func scroll() {
        evaluate(Self.scrollScript)
    }

    func reload() {
        DispatchQueue.main.async {
            self.webView?.reload()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.teardown()
        }
    }

    // MARK: - 建页面

    private func build(patterns: [String]) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: Self.hookScript(patterns: patterns),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let proxy = Handler()
        proxy.owner = self
        controller.add(proxy, name: Self.handlerName)
        configuration.userContentController = controller
        handler = proxy

        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        view.customUserAgent = userAgent
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        webView = view
        attach(view)

        let load: () -> Void = { [weak self] in
            guard let self = self, let view = self.webView else { return }
            guard let target = URL(string: self.startURL) else { return }
            view.load(URLRequest(url: target))
        }
        if cookieHeader.isEmpty {
            load()
        } else {
            CookieJar.writeIfAbsent(cookieHeader, domainSuffix: cookieDomain, completion: load)
        }
    }

    private func teardown() {
        handler?.owner = nil
        if let view = webView {
            view.configuration.userContentController
                .removeScriptMessageHandler(forName: Self.handlerName)
            view.stopLoading()
            view.navigationDelegate = nil
            view.removeFromSuperview()
        }
        host?.removeFromSuperview()
        host = nil
        webView = nil
        handler = nil
    }

    private func attach(_ view: WKWebView) {
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
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        container.addSubview(view)
        window.addSubview(container)
        window.sendSubviewToBack(container)
        host = container
    }

    // MARK: - 回调

    private func handle(_ message: Message) {
        onMessage?(message)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }

    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var owner: WebPageHarvester?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let owner = owner else { return }
            guard let payload = message.body as? [String: Any] else { return }
            let url = payload["url"] as? String ?? ""
            let body = payload["body"] as? String ?? ""
            guard !body.isEmpty else { return }
            owner.handle(Message(url: url, body: body))
        }
    }

    // MARK: - 注入脚本

    private static func hookScript(patterns: [String]) -> String {
        var list = "[]"
        if
            let data = try? JSONSerialization.data(withJSONObject: patterns),
            let text = String(data: data, encoding: .utf8)
        {
            list = text
        }
        return """
        (function(){
          if (window.__flareHarvestHooked) { return; }
          window.__flareHarvestHooked = true;
          var PATTERNS = \(list);
          function interested(u) {
            var s = String(u || '');
            for (var i = 0; i < PATTERNS.length; i++) {
              if (s.indexOf(PATTERNS[i]) >= 0) { return true; }
            }
            return false;
          }
          function post(u, t) {
            try {
              var body = String(t || '');
              if (body.length > 6000000) { body = body.substring(0, 6000000); }
              window.webkit.messageHandlers.flareharvest.postMessage({
                url: String(u || ''),
                body: body
              });
            } catch (e) {}
          }
          try {
            var originalFetch = window.fetch;
            if (originalFetch) {
              window.fetch = function() {
                var args = arguments;
                var u = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url);
                var promise = originalFetch.apply(this, args);
                try {
                  if (u && interested(u)) {
                    promise.then(function(res) {
                      try {
                        res.clone().text().then(function(t) { post(u, t); });
                      } catch (e) {}
                    });
                  }
                } catch (e) {}
                return promise;
              };
            }
          } catch (e) {}
          try {
            var originalOpen = XMLHttpRequest.prototype.open;
            var originalSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
              this.__flareURL = url;
              return originalOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
              var xhr = this;
              try {
                if (xhr.__flareURL && interested(xhr.__flareURL)) {
                  xhr.addEventListener('load', function() {
                    try { post(xhr.__flareURL, xhr.responseText); } catch (e) {}
                  });
                }
              } catch (e) {}
              return originalSend.apply(this, arguments);
            };
          } catch (e) {}
        })();
        """
    }

    /// 页面是 JS 无限滚动，得真的滚一下才会拉下一页。
    /// 找不到滚动容器就退回 `window`，顺手补一个 wheel 事件。
    private static let scrollScript = """
    (function(){
      try {
        window.scrollTo(0, document.body.scrollHeight);
        if (document.documentElement) {
          document.documentElement.scrollTop = document.documentElement.scrollHeight;
        }
        if (document.body) { document.body.scrollTop = document.body.scrollHeight; }
      } catch (e) {}
      var best = null;
      var bestHeight = 0;
      try {
        var all = document.querySelectorAll('div, main, section, ul');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          try {
            if (el.scrollHeight > el.clientHeight + 200 && el.clientHeight > 200) {
              if (el.scrollHeight > bestHeight) { bestHeight = el.scrollHeight; best = el; }
            }
          } catch (e) {}
        }
      } catch (e) {}
      if (best) {
        try {
          best.scrollTop = best.scrollHeight;
          best.dispatchEvent(new WheelEvent('wheel', {deltaY: 1600, bubbles: true, cancelable: true}));
        } catch (e) {}
      }
      try { window.dispatchEvent(new Event('scroll')); } catch (e) {}
      return best ? '1' : '0';
    })()
    """
}
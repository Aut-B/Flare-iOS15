import SwiftUI
import UIKit
import WebKit

/// 「网页登录 → 抓 cookie」的通用页面。
///
/// Instagram、小红书这类没有开放 API 的平台，网页版登录后 cookie 就是全部凭证。
/// 这里负责把用户扔进真正的登录页（桌面 UA，否则会被引导去下载 App），
/// 轮询 cookie 仓库，一旦出现**新的**目标 cookie 就回调并自动关闭。
///
/// 「新的」很关键：重新登录时数据仓库里还留着上一次的 `web_session`，
/// 只要判断「存在就完成」就会一打开就立刻关掉 —— 表现就是「网页弹一下就退回去」。
struct CookieLoginView: View {
    let url: String
    let title: String
    /// 移动 UA 会被这些站点引导去「打开 App」，所以要伪装桌面 Safari。
    let userAgent: String
    /// 出现这个 cookie 才算登录成功（`sessionid` / `web_session` 之类）。
    let requiredCookieName: String
    /// 只取这个域名下的 cookie。
    let cookieDomainSuffix: String
    /// 打开前先清掉该域名的旧 cookie。重新登录时必须开，
    /// 否则网页会认为「已经登录」，直接跳回首页，永远拿不到新会话。
    var clearCookies: Bool = false
    /// 按 1280 宽排版再整体缩小。小红书的手机版登录页没有二维码，
    /// 只有桌面版才有 —— 6s 这种窄屏必须开这个才有得扫。
    var desktopLayout: Bool = false
    /// 用户点取消时回调（用来把旧 cookie 灌回隐藏页面，避免签名页变成匿名）。
    var onCancel: (() -> Void)? = nil
    let onCookies: ([HTTPCookie]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 点「完成」时 +1，让 WebView 那边强制把当前 cookie 收下。
    @State private var finishToken = 0

    var body: some View {
        NavigationView {
            CookieWebContainer(
                url: url,
                userAgent: userAgent,
                requiredCookieName: requiredCookieName,
                cookieDomainSuffix: cookieDomainSuffix,
                clearCookies: clearCookies,
                desktopLayout: desktopLayout,
                finishToken: finishToken
            ) { cookies in
                onCookies(cookies)
                dismiss()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel?()
                        dismiss()
                    }
                }
                // 二维码扫完页面不一定跳转，自动判断也可能慢半拍。
                // 留一个手动出口，用户点「完成」就直接把当前会话收下。
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { finishToken += 1 }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct CookieWebContainer: UIViewRepresentable {
    let url: String
    let userAgent: String
    let requiredCookieName: String
    let cookieDomainSuffix: String
    let clearCookies: Bool
    let desktopLayout: Bool
    let finishToken: Int
    let onCookies: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            requiredCookieName: requiredCookieName,
            cookieDomainSuffix: cookieDomainSuffix,
            onCookies: onCookies
        )
    }

    func makeUIView(context: Context) -> UIView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 桌面 UA 只改 `navigator.userAgent`，改不了视口宽度。
        if userAgent.contains("Macintosh") || userAgent.contains("Windows") {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.desktopShim(scaleToFit: !desktopLayout),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 先记录「打开前的会话」，再决定要不要清 cookie、要不要加载。
        context.coordinator.begin(webView: webView, url: url, clearCookies: clearCookies)
        guard desktopLayout else { return webView }
        return DesktopContainer(webView: webView)
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.apply(finishToken: finishToken)
    }

    func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    /// 让窄屏也按桌面版排版，并且把「手机」特征抹掉。
    ///
    /// `scaleToFit` 只给「不套 DesktopContainer」的场景用：靠 `initial-scale`
    /// 把 1280 宽压进屏幕。套了 DesktopContainer 的必须给 1，
    /// 否则缩放会叠加两次，二维码小到扫不出来。
    private static func desktopShim(scaleToFit: Bool) -> String {
        let initialScale = scaleToFit ? "0.30" : "1"
        return """
    (function(){
      function apply(){
        try {
          var head = document.head || document.documentElement;
          if (!head) return;
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.setAttribute('name', 'viewport');
            head.appendChild(meta);
          }
          meta.setAttribute('content', 'width=1280, initial-scale=\(initialScale), minimum-scale=0.1, maximum-scale=5, user-scalable=yes');
        } catch (e) {}
      }
      apply();
      document.addEventListener('DOMContentLoaded', apply, true);
      window.addEventListener('load', apply, true);
      try {
        Object.defineProperty(navigator, 'platform', { get: function(){ return 'MacIntel'; } });
        Object.defineProperty(navigator, 'maxTouchPoints', { get: function(){ return 0; } });
      } catch (e) {}
    })();
    """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let requiredCookieName: String
        private let cookieDomainSuffix: String
        private let onCookies: ([HTTPCookie]) -> Void
        private var timer: Timer?
        private var finished = false
        private weak var webView: WKWebView?
        private var loginURL: String = ""
        private var clearCookies = false
        /// 打开登录页之前仓库里的会话值。只有出现**不同**的值才算登录成功。
        private var baseline: String?
        private var baselineReady = false
        /// 「完成」按钮按了几次。只在值变化时处理，避免每次刷新都触发。
        private var lastFinishToken = 0
        /// 登录页真正加载完的时间。清完 cookie 后页面往往先种一个游客
        /// `web_session`，这时候收下会话等于白登一次 —— 页面就绪后再等
        /// 两秒才开始认 cookie。
        private var armedAt: Date?
        /// 就绪时把「游客会话」记成新的基线。之后只有**换过**的会话才算登录成功。
        private var baselineRefreshed = false

        init(
            requiredCookieName: String,
            cookieDomainSuffix: String,
            onCookies: @escaping ([HTTPCookie]) -> Void
        ) {
            self.requiredCookieName = requiredCookieName
            self.cookieDomainSuffix = cookieDomainSuffix
            self.onCookies = onCookies
        }

        func begin(webView: WKWebView, url: String, clearCookies: Bool) {
            self.webView = webView
            self.loginURL = url
            self.clearCookies = clearCookies
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                let existing = cookies.first {
                    $0.name == self.requiredCookieName && $0.domain.contains(self.cookieDomainSuffix)
                }
                self.baseline = existing?.value
                self.baselineReady = true
                if clearCookies {
                    CookieJar.clear(domainSuffix: self.cookieDomainSuffix) {
                        // 清完旧会话，baseline 也就不作数了。
                        self.baseline = nil
                        self.load()
                    }
                } else {
                    self.load()
                }
            }
            startPolling()
            // 有些站点（小红书）会一直有子请求在跑，`didFinish` 迟迟不来。
            // 兜个底：最迟 10 秒也把基线定下来，别让轮询永远不生效。
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self, !self.finished else { return }
                if self.armedAt == nil { self.armedAt = Date() }
            }
        }

        private func load() {
            guard let webView = webView, let target = URL(string: loginURL) else { return }
            webView.load(URLRequest(url: target))
        }

        func startPolling() {
            stopPolling()
            // 登录大多是页面内跳转，`didFinish` 不一定触发，直接轮询最稳。
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        private func checkCookies() {
            guard !finished, baselineReady else { return }
            guard let armed = armedAt, Date().timeIntervalSince(armed) > 2.0 else { return }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.finished else { return }
                let matched = cookies.filter { $0.domain.contains(self.cookieDomainSuffix) }
                guard
                    let session = matched.first(where: {
                        $0.name == self.requiredCookieName && !$0.value.isEmpty
                    })
                else {
                    return
                }
                // 第一次走到这里说明页面已经就绪：此刻的会话是游客态，
                // 记成新基线，免得页面自种的游客 cookie 直接把 sheet 关掉。
                if !self.baselineRefreshed {
                    self.baselineRefreshed = true
                    self.baseline = session.value
                    return
                }
                // 值没变 = 还是打开前那套会话，说明用户还没真正登录成功。
                if let baseline = self.baseline, baseline == session.value {
                    return
                }
                self.finished = true
                self.stopPolling()
                DispatchQueue.main.async {
                    self.onCookies(matched)
                }
            }
        }

        /// 用户点「完成」：直接把当前会话收下，不必等页面跳转或轮询。
        func apply(finishToken: Int) {
            guard finishToken != lastFinishToken else { return }
            lastFinishToken = finishToken
            guard finishToken > 0 else { return }
            forceFinish()
        }

        private func forceFinish() {
            guard !finished else { return }
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.finished else { return }
                let matched = cookies.filter { $0.domain.contains(self.cookieDomainSuffix) }
                guard matched.contains(where: {
                    $0.name == self.requiredCookieName && !$0.value.isEmpty
                }) else { return }
                self.finished = true
                self.stopPolling()
                DispatchQueue.main.async {
                    self.onCookies(matched)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            armedAt = Date()
            checkCookies()
        }
    }
}

/// 按 1280 宽排版，再整体缩放到屏幕宽度。小红书的手机版登录页没有二维码，
/// 只有桌面版才有；6s 这种窄屏必须走这条路。
private final class DesktopContainer: UIView {
    private static let layoutWidth: CGFloat = 1280
    private static let layoutHeight: CGFloat = 1600
    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let scale = width / Self.layoutWidth
        webView.bounds = CGRect(
            x: 0,
            y: 0,
            width: Self.layoutWidth,
            height: max(Self.layoutHeight, height / max(scale, 0.01))
        )
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.center = CGPoint(x: width / 2, y: height / 2)
    }
}

/// cookie 相关的小工具，Instagram 和小红书都要用。
enum CookieJar {
    /// 拼 `Cookie:` 请求头。只取目标域名的，避免把别站 cookie 一起发出去。
    static func header(_ cookies: [HTTPCookie], domainSuffix: String) -> String {
        cookies
            .filter { $0.domain.contains(domainSuffix) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func value(_ cookies: [HTTPCookie], named name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    /// 从 `Cookie:` 字符串里取某个 key。
    static func value(inHeader header: String, named name: String) -> String? {
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let index = piece.firstIndex(of: "=") else { continue }
            if String(piece[piece.startIndex..<index]) == name {
                return String(piece[piece.index(after: index)...])
            }
        }
        return nil
    }

    /// 删掉某个域名下的全部 cookie（重新登录前用）。
    static func clear(domainSuffix: String, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let targets = cookies.filter { $0.domain.contains(domainSuffix) }
            guard !targets.isEmpty else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            let group = DispatchGroup()
            for cookie in targets {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }
    }

    /// 把一段 `Cookie:` 串写进 WKWebsiteDataStore（网页版兜底页用）。
    /// 只在目标域名还没有 cookie 时才写：用户可能在网页里重新登录过，
    /// 每次都灌旧串等于把他刚登好的会话顶掉。
    static func writeIfAbsent(
        _ header: String,
        domainSuffix: String,
        completion: @escaping () -> Void
    ) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let existing = cookies.filter { cookie in
                cookie.domain.contains(domainSuffix) && !cookie.value.isEmpty
            }
            if existing.isEmpty {
                write(header, domainSuffix: domainSuffix, completion: completion)
            } else {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    static func write(_ header: String, domainSuffix: String, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        var cookies: [HTTPCookie] = []
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let index = piece.firstIndex(of: "=") else { continue }
            let name = String(piece[piece.startIndex..<index])
            let value = String(piece[piece.index(after: index)...])
            guard !name.isEmpty, !value.isEmpty else { continue }
            if let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".\(domainSuffix)",
                .path: "/",
            ]) {
                cookies.append(cookie)
            }
        }
        guard !cookies.isEmpty else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// 把 WKWebView 里的 cookie 灌进 URLSession 的共享仓库，
    /// 这样 `URLSession.shared` 的请求也能带上登录态。
    static func syncToSharedStorage(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

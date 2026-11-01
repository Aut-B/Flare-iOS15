import SwiftUI
import WebKit
import UIKit

/// 要打开的一本书。
struct WereadReaderTarget: Identifiable {
    let id = UUID()
    /// 网页阅读器地址（`/web/reader/<hash>`）。没拿到时是网页书架地址。
    let url: String
    let title: String
    /// true = 没有阅读器地址，先落到网页书架再自动点开那本书。
    let needsJump: Bool
}

/// 微信读书阅读器（网页版，全屏）。
///
/// 只做一件事：把网页阅读器**原样全屏**铺开。
/// 网页阅读器本来就支持长按选文、划线、写想法、翻页、进度同步，
/// 这些自己用原生重写一遍既做不到那么好，也没必要。
///
/// 关键是地址：网页阅读器要的是 `/web/reader/<hash>` 里那个 hash，
/// 用 `shelf/sync` 的数字 bookId 自己拼一定 404 —— 上一版「点进去白屏」
/// 就是这个原因。hash 由 `WereadStore` 从网页书架的链接里抄下来缓存。
struct WereadReaderView: View {
    let target: WereadReaderTarget

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var reloadToken = 0
    @State private var inReader = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WereadReaderWebView(
                url: target.url,
                cookie: WereadStore.shared.cookie,
                bookTitle: target.title,
                needsJump: target.needsJump,
                reloadToken: reloadToken,
                isLoading: $isLoading,
                inReader: $inReader
            )
            .ignoresSafeArea()

            if isLoading || (target.needsJump && !inReader) {
                // 兜底路径会先落到网页书架再自动点开，中间那一下不要露给用户。
                ZStack {
                    Color(.systemBackground)
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在打开《\(target.title)》…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                floatingButton("xmark", label: "关闭") { dismiss() }
                floatingButton("arrow.clockwise", label: "刷新") { reloadToken += 1 }
            }
            .padding(.trailing, 10)
            .padding(.top, 6)
        }
        .background(Color(.systemBackground))
        .statusBar(hidden: true)
    }

    private func floatingButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.32))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct WereadReaderWebView: UIViewRepresentable {
    let url: String
    let cookie: String
    let bookTitle: String
    let needsJump: Bool
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var inReader: Bool

    /// 让阅读页的文字可以被长按选中。
    ///
    /// 微信读书自己接管了 `touchstart` / `selectstart`，还会给正文容器写
    /// `user-select: none`。CSS 用 `!important` 盖掉，事件在捕获阶段掐断，
    /// 这样系统原生的选择手柄、复制/查询/翻译菜单就能正常出来。
    private static let selectionScript = """
    (function(){
      var styleId = 'flare-select-style';
      function apply(){
        try {
          var head = document.head || document.documentElement;
          if (!head) { return; }
          var style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            head.appendChild(style);
          }
          style.textContent = 'body, body * { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; }';
          var inline = document.querySelectorAll('[style*="user-select"]');
          for (var i = 0; i < inline.length; i++) {
            inline[i].style.setProperty('-webkit-user-select', 'text', 'important');
            inline[i].style.setProperty('user-select', 'text', 'important');
          }
        } catch (e) {}
      }
      apply();
      document.addEventListener('DOMContentLoaded', apply, true);
      window.addEventListener('load', apply, true);
      ['selectstart', 'contextmenu'].forEach(function(name){
        document.addEventListener(name, function(e){ e.stopPropagation(); }, true);
      });
      try {
        var observer = new MutationObserver(function(){ apply(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // 微信读书的阅读页默认把文字设成不可选（它想自己做划线交互），
        // 结果 WKWebView 里长按既不出选择手柄，也没法写想法。这里强行放开。
        configuration.preferences.isTextInteractionEnabled = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.selectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 桌面 UA：手机 UA 下微信读书会把网页换成「打开 App」引导页。
        webView.customUserAgent = WebPlatformUserAgent.desktop
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedToken != reloadToken {
            context.coordinator.loadedToken = reloadToken
            context.coordinator.load()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WereadReaderWebView
        weak var webView: WKWebView?
        var loadedToken = 0

        private var didAttemptJump = false
        private var jumpAttempts = 0
        /// true = 当前在「网页书架 → 自动点开那本书」的兜底流程里。
        private var jumpMode = false
        /// 阅读器页只校验一次，避免每次翻页都跑一遍。
        private var checkedReader = false

        init(parent: WereadReaderWebView) {
            self.parent = parent
        }

        func load() {
            guard let webView = webView else { return }
            guard let target = URL(string: parent.url) else { return }
            didAttemptJump = false
            jumpAttempts = 0
            jumpMode = parent.needsJump
            checkedReader = false
            // 页面里已经登录过就别再灌旧 cookie —— 那会把用户刚登好的会话顶掉。
            let request = URLRequest(url: target)
            if parent.cookie.isEmpty {
                webView.load(request)
            } else {
                CookieJar.writeIfAbsent(
                    parent.cookie,
                    domainSuffix: "weread.qq.com"
                ) {
                    webView.load(request)
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            let current = webView.url?.absoluteString ?? ""
            // 真的跳进阅读器了就把地址记下来，下次点这本书直接秒开。
            if current.contains("/web/reader/") {
                parent.inReader = true
                WereadStore.shared.rememberReaderLink(title: parent.bookTitle, url: current)
                if !jumpMode { verifyReader(in: webView) }
                return
            }
            // 直接拼出来的地址被服务端踢回书架 = 这本书的 hash 拼错了
            // （下架、合集、老书）。别让用户对着书架发愣，走点击兜底。
            if parent.url.contains("/web/reader/"), !jumpMode {
                enterJumpMode(in: webView)
                return
            }
            guard jumpMode || parent.needsJump else { return }
            jumpMode = true
            guard !didAttemptJump else { return }
            didAttemptJump = true
            // 书架是 JS 渲染的，`didFinish` 时列表往往还没出来，多试几次。
            scheduleJump(in: webView)
        }

        /// 阅读器页可能只是「书不存在」的空壳（HTTP 200），看正文判断一下。
        private func verifyReader(in webView: WKWebView) {
            guard !checkedReader else { return }
            checkedReader = true
            // 正文是 JS 画出来的，`didFinish` 时往往还是白屏。
            // 等两秒再看，别把「还没画完」当成「这本书不存在」。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak webView] in
                guard let self = self, let webView = webView, !self.jumpMode else { return }
                let script = "(document.body ? (document.body.innerText || '') : '').slice(0, 800)"
                webView.evaluateJavaScript(script) { value, _ in
                    let text = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let missing =
                        text.contains("404")
                        || text.contains("不存在")
                        || text.contains("已下架")
                        || text.count < 20
                    guard missing else { return }
                    self.enterJumpMode(in: webView)
                }
            }
        }

        private func enterJumpMode(in webView: WKWebView) {
            guard !jumpMode else { return }
            jumpMode = true
            checkedReader = true
            didAttemptJump = false
            jumpAttempts = 0
            parent.inReader = false
            parent.isLoading = true
            guard let shelf = URL(string: "https://weread.qq.com/web/shelf") else { return }
            webView.load(URLRequest(url: shelf))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
        }

        /// 卡片经常用新窗口打开；没有这个回调点了会没反应。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func scheduleJump(in webView: WKWebView) {
            guard jumpAttempts < 5 else { return }
            let delay = jumpAttempts == 0 ? 1.2 : 2.0
            jumpAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                Self.openBook(in: webView, title: self.parent.bookTitle) { found in
                    if !found {
                        self.scheduleJump(in: webView)
                    }
                }
            }
        }

        /// 在网页书架里找到书名匹配的那本并点开。
        private static func openBook(
            in webView: WKWebView,
            title: String,
            completion: @escaping (Bool) -> Void
        ) {
            guard !title.isEmpty else {
                completion(true)
                return
            }
            let script = """
            (function(){
              var title = \(jsString(title));
              function norm(s){ return (s||"").replace(/\\s+/g,"").toLowerCase(); }
              var target = norm(title);
              if (!target) return "";
              var nodes = document.querySelectorAll('a, li, [class*="book"], [class*="shelf"]');
              var best = null;
              for (var i = 0; i < nodes.length; i++) {
                var t = norm(nodes[i].innerText || nodes[i].textContent || "");
                if (!t) continue;
                if (t === target || t.indexOf(target) >= 0) { best = nodes[i]; break; }
              }
              if (!best) return "";
              var link = best.closest ? best.closest('a') : null;
              if (link && link.href && link.href.indexOf('/web/reader/') >= 0) {
                location.href = link.href;
                return "nav";
              }
              best.click();
              return "click";
            })()
            """
            webView.evaluateJavaScript(script) { value, _ in
                let result = value as? String ?? ""
                completion(!result.isEmpty)
            }
        }

        private static func jsString(_ value: String) -> String {
            let escaped =
                value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
            return "\"\(escaped)\""
        }
    }
}

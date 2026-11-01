import SwiftUI
import Combine
import WebKit
import UIKit

/// 微信读书阅读器（网页版）。
///
/// 原生书架点一本书时直接开一个全屏网页：先落到网页书架，再用 JS 把这本书
/// 点开 —— 网页阅读器要的是加密过的 bookId，`shelf/sync` 给的是数字 id，
/// 自己拼一定 404。这样「先进线上书架、再点一次」那一步就省掉了。
///
/// 没有导航栏：网页铺满整屏（这才是全屏），右下角只留三个悬浮按钮。
struct WereadReaderView: View {
    let book: WereadBook

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WereadWebModel()
    @State private var isLoading = true

    private static let shelfURL = "https://weread.qq.com/web/shelf"

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WereadReaderWebView(
                url: Self.shelfURL,
                cookie: WereadStore.shared.cookie,
                bookTitle: book.title,
                model: model,
                isLoading: $isLoading
            )
            .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4)
            }

            VStack(spacing: 10) {
                floatingButton("xmark", label: "关闭") { dismiss() }
                floatingButton("arrow.clockwise", label: "刷新") { model.reload() }
                floatingButton("books.vertical", label: "回书架") { model.loadShelf() }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 18)
        }
        .background(Color(.systemBackground))
    }

    private func floatingButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.38))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

final class WereadWebModel: ObservableObject {
    @Published var canGoBack = false

    weak var webView: WKWebView?

    func refresh() {
        canGoBack = webView?.canGoBack ?? false
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    /// 回到网页书架。阅读器页面自己的返回键不一定在，这个兜底用。
    func loadShelf() {
        guard let target = URL(string: "https://weread.qq.com/web/shelf") else { return }
        webView?.load(URLRequest(url: target))
    }
}

private struct WereadReaderWebView: UIViewRepresentable {
    let url: String
    let cookie: String
    let bookTitle: String
    @ObservedObject var model: WereadWebModel
    @Binding var isLoading: Bool

    /// 桌面 UA：手机 UA 下微信读书会把网页换成「打开 App」引导页。
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        model.webView = webView

        let start: () -> Void = {
            guard let target = URL(string: url) else { return }
            webView.load(URLRequest(url: target))
        }
        // 页面里已经登录过就别再灌旧 cookie —— 那会把用户刚登好的会话顶掉。
        if cookie.isEmpty {
            start()
        } else {
            CookieJar.writeIfAbsent(cookie, domainSuffix: "weread.qq.com", completion: start)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: WereadReaderWebView
        /// 只在第一次落到书架时自动点书；之后用户自己点的不再干预。
        private var didAttemptJump = false
        private var jumpAttempts = 0

        init(parent: WereadReaderWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.model.refresh()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.model.refresh()
            guard !didAttemptJump else { return }
            didAttemptJump = true
            // 书架是 JS 渲染的，`didFinish` 时列表往往还没出来，多试几次。
            scheduleJump(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
            parent.model.refresh()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
            parent.model.refresh()
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
            guard jumpAttempts < 4 else { return }
            let delay = jumpAttempts == 0 ? 1.2 : 2.0
            jumpAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self, let webView else { return }
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
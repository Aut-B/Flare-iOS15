import SwiftUI
import WebKit
import UIKit

/// 抖音 / TikTok 这类「网页版本身就最全」的平台。
///
/// 它们没有稳定的开放接口，但网页版该有的都有：视频、点赞、评论、转发、
/// 收藏、私信。这里放一个常驻 `WKWebsiteDataStore.default()` 的浏览器页面，
/// 登录一次就一直留着 —— 和 Instagram / 小红书那套 cookie 登录是同一个思路，
/// 只是不需要再把数据搬进原生列表。
struct WebPlatformView: View {
    let url: String
    let title: String
    let mobileUserAgent: String
    let desktopUserAgent: String

    @StateObject private var model = WebPlatformModel()
    @State private var desktopMode = false

    private var userAgent: String {
        desktopMode ? desktopUserAgent : mobileUserAgent
    }

    var body: some View {
        WebPlatformWebView(url: url, userAgent: userAgent, model: model)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .top) {
                if model.isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)

                    Button {
                        model.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!model.canGoForward)

                    Spacer()

                    Button {
                        model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Spacer()

                    Menu {
                        Button {
                            desktopMode.toggle()
                        } label: {
                            Label(
                                desktopMode ? "手机版网页" : "桌面版网页",
                                systemImage: "display"
                            )
                        }
                        Button {
                            model.openInSafari()
                        } label: {
                            Label("在浏览器里打开", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
    }
}

struct DouyinView: View {
    var body: some View {
        WebPlatformView(
            url: "https://www.douyin.com/",
            title: "抖音",
            mobileUserAgent: WebPlatformUserAgent.mobile,
            desktopUserAgent: WebPlatformUserAgent.desktop
        )
    }
}

struct TikTokView: View {
    var body: some View {
        WebPlatformView(
            url: "https://www.tiktok.com/",
            title: "TikTok",
            mobileUserAgent: WebPlatformUserAgent.mobile,
            desktopUserAgent: WebPlatformUserAgent.desktop
        )
    }
}

enum WebPlatformUserAgent {
    static let mobile =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktop =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

final class WebPlatformModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

    weak var webView: WKWebView?

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reload() {
        webView?.reload()
    }

    func openInSafari() {
        guard let url = webView?.url else { return }
        UIApplication.shared.open(url)
    }

    func refresh() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }
}

private struct WebPlatformWebView: UIViewRepresentable {
    let url: String
    let userAgent: String
    @ObservedObject var model: WebPlatformModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // 允许视频自动播 / 内联播，不然点开视频只有声音没有画面。
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        if let target = URL(string: url) {
            webView.load(URLRequest(url: target))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 切手机版 / 桌面版：换 UA 并重载当前页。
        guard !userAgent.isEmpty, webView.customUserAgent != userAgent else { return }
        webView.customUserAgent = userAgent
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: WebPlatformModel

        init(model: WebPlatformModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            model.refresh()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
            model.refresh()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            model.isLoading = false
            model.refresh()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            model.isLoading = false
            model.refresh()
        }

        /// 抖音 / TikTok 的卡片大量用新窗口打开；没有这个回调点了会没反应。
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
    }
}

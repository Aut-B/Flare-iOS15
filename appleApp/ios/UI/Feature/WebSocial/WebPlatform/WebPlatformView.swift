import SwiftUI
import Combine
import WebKit
import UIKit

/// 用网页版直接承载的平台（小红书 / Instagram 兜底）。
///
/// 有些平台的私有接口动不动就变签名、加风控，网页版反而是最稳的：
/// 视频、点赞、评论、转发、收藏全都在。这里给一个常驻
/// `WKWebsiteDataStore.default()` 的浏览器页面，登录一次就一直留着。
struct WebPlatformView: View {
    let url: String
    let title: String
    let mobileUserAgent: String
    let desktopUserAgent: String
    /// 打开前先灌进去的 cookie 串（从原生登录里拿到的）。
    var initialCookie: String = ""
    /// 上面 cookie 属于哪个域名，例如 `xiaohongshu.com`。
    var cookieDomainSuffix: String = ""
    /// 浏览器工具条（后退 / 前进 / 刷新 / 桌面版）放底部还是收进右上角菜单。
    /// 嵌在时间线标签里时要收起来，否则会和应用自己的底部栏打架。
    var showsBrowserBar: Bool = true
    /// 有些站（微信读书）手机 UA 会被塞「打开 App」引导，直接进桌面版更省事。
    var startDesktop: Bool = false
    /// 追加在右上角菜单末尾的一项，用来「切回原生列表 / 书架」。
    var extraMenuTitle: String? = nil
    var extraMenuAction: (() -> Void)? = nil

    @StateObject private var model = WebPlatformModel()
    @State private var desktopMode: Bool

    init(
        url: String,
        title: String,
        mobileUserAgent: String,
        desktopUserAgent: String,
        initialCookie: String = "",
        cookieDomainSuffix: String = "",
        showsBrowserBar: Bool = true,
        startDesktop: Bool = false,
        extraMenuTitle: String? = nil,
        extraMenuAction: (() -> Void)? = nil
    ) {
        self.url = url
        self.title = title
        self.mobileUserAgent = mobileUserAgent
        self.desktopUserAgent = desktopUserAgent
        self.initialCookie = initialCookie
        self.cookieDomainSuffix = cookieDomainSuffix
        self.showsBrowserBar = showsBrowserBar
        self.startDesktop = startDesktop
        self.extraMenuTitle = extraMenuTitle
        self.extraMenuAction = extraMenuAction
        _desktopMode = State(initialValue: startDesktop)
    }

    private var userAgent: String {
        desktopMode ? desktopUserAgent : mobileUserAgent
    }

    var body: some View {
        Group {
            if showsBrowserBar {
                content.toolbar { bottomBar }
            } else {
                content.toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        browserMenu
                    }
                }
            }
        }
    }

    private var content: some View {
        WebPlatformWebView(
            url: url,
            userAgent: userAgent,
            initialCookie: initialCookie,
            cookieDomainSuffix: cookieDomainSuffix,
            model: model
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if model.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
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

            browserMenu
        }
    }

    private var browserMenu: some View {
        Menu {
            Button {
                model.goBack()
            } label: {
                Label("后退", systemImage: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            Button {
                model.goForward()
            } label: {
                Label("前进", systemImage: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            Button {
                model.reload()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Divider()
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
            if let title = extraMenuTitle, let action = extraMenuAction {
                Divider()
                Button(action: action) {
                    Label(title, systemImage: "square.grid.2x2")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
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
    let initialCookie: String
    let cookieDomainSuffix: String
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

        let start: () -> Void = {
            guard let target = URL(string: url) else { return }
            webView.load(URLRequest(url: target))
        }
        // 原生登录拿到的 cookie 先灌进数据仓库，否则网页版会要求重新登录。
        if initialCookie.isEmpty || cookieDomainSuffix.isEmpty {
            start()
        } else {
            CookieJar.write(initialCookie, domainSuffix: cookieDomainSuffix, completion: start)
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
    }
}

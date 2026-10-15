import SwiftUI
import WebKit
import Perception
import FlareAppleUI
import NavigationBackport

struct BackportWebLoginScreen: View {
    @Environment(\.dismiss) var dismiss
    @State private var viewModel: BackportWebLoginViewModel?
    /// WebView 是否还在加载。x.com 在 iPhone 6S 上首屏可能要十几秒，
    /// 没有指示时看起来就像「点进去一片白屏」。
    @State private var isLoading = true
    private let onCookie: (String) -> Void
    let url: String
    init(
        onCookie: @escaping (String) -> Void,
        url: String
    ) {
        self.url = url
        self.onCookie = onCookie
    }

    var body: some View {
        NBNavigationStack {
            // iOS 15 回退：viewModel 是 @Perceptible，NBNavigationStack 的内容闭包
            // 是惰性求值的，必须把读取点包进 WithPerceptionTracking，否则
            // canShowWebView 置 true 时视图不会重算，登录网页迟迟不出现。
            WithPerceptionTracking {
                if let viewModel, viewModel.canShowWebView {
                    ZStack {
                        BackportWebView(
                            url: URL(string: url),
                            configuration: viewModel.configuration,
                            isLoading: $isLoading
                        ) { webView in
                            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
                            // uiDelegate 与 navigationDelegate 都由 WKDelegate 承担：
                            // window.open 的拦截在 uiDelegate，URL 策略在 navigationDelegate。
                            webView.uiDelegate = viewModel.delegate
                            webView.navigationDelegate = viewModel.delegate
                        }
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                Label {
                                    Text("Cancel")
                                } icon: {
                                    Image(systemName: "xmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .task {
            // Initialize after state is installed so view rebuilds don't clear cookies again.
            guard viewModel == nil else { return }
            let model = BackportWebLoginViewModel(onCookie: onCookie, url: url)
            model.clearStaleCookies()
            viewModel = model
        }
    }
}

class WKDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let decidePolicy: () -> Void
    init(decidePolicy: @escaping () -> Void
    ) {
        self.decidePolicy = decidePolicy
    }

    /// target=_blank / window.open：iOS 15 的系统默认行为是新开一个模态 WebView，
    /// 以高斯模糊背景的 pageSheet 呈现。X 的登录流程（输入邮箱后的下一步、
    /// 「继续使用谷歌」）会把用户带进这个遮罩，而 sheet 一被下拉关闭，
    /// 整个登录流程就断在这里——表现为「点了下一步一直卡住/等不到密码界面」。
    /// 这里把新窗口请求拉回同一个 WebView 加载。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationResponsePolicy {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
            return .cancel
        }
        return .allow
    }

    /// 双保险：即使 decidePolicyFor 没拦住，也禁止系统创建模态子窗口，
    /// 把请求拉回主 WebView。返回 nil 即「不创建新窗口」。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        decidePolicy()
        return .allow
    }
}

@Perceptible
final class BackportWebLoginViewModel {
    var canShowWebView = false
    let url: String
    let onCookie: (String) -> Void
    let delegate: WKDelegate
    /// 登录页使用的数据仓库，cookie 的写入与读取必须走同一个实例。
    let dataStore = WKWebsiteDataStore.default()
    /// 配置改为 stored 属性：原来是计算属性，body 每求值一次就新建一个
    /// WKWebViewConfiguration，视图重算时 WebView 会按新配置重建、登录态丢失。
    let configuration: WKWebViewConfiguration
    @PerceptionIgnored private var observers = [NSKeyValueObservation]()
    init(
        onCookie: @escaping (String) -> Void,
        url: String
    ) {
        self.onCookie = onCookie
        self.url = url
        self.delegate = WKDelegate {
            // cookie 必须从登录页实际使用的仓库里取。configuration 用默认（持久化）
            // 仓库，而 WKWebsiteDataStore.default() 是进程内单例，网页写入的就是它。
            // 注意：这里不能捕获 self——delegate 还在初始化中，转义闭包捕获 self 会触发
            // "used before being initialized"。
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { (cookies) in
                let cookieString = BackportWebLoginViewModel.cookieHeaderString(from: cookies, for: .init(string: url))
                onCookie(cookieString)
            }
        }
        // 用默认（持久化）仓库：X/微博的登录流程依赖 sessionStorage 与带凭证的
        // XHR，非持久化仓库在部分 iOS 15 上会让登录 POST 静默失败，表现为
        // 「点了下一步一直卡住」。清空旧 cookie 的逻辑见 clearStaleCookies()。
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // iOS 15 回退：WKPreferences.javaScriptCanOpenWindowsAutomatically 默认 false，
        // window.open 会被静默拦掉（页面像卡住）。打开后 window.open 会走
        // uiDelegate 的 createWebViewWith，由 WKDelegate 把请求拉回主 WebView。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.websiteDataStore = dataStore
        self.configuration = configuration
        // 不再走「清空全部网站数据后再显示」的异步链路，登录页立即可见。
        self.canShowWebView = true
    }
    /// 只清理登录域下的旧 cookie，避免上次登录的残留 cookie 让 canResume 直接通过。
    /// targeted 删除比上游「清空全部网站数据」快得多，且在页面加载前就发起。
    func clearStaleCookies() {
        guard let host = URL(string: url)?.host?.lowercased() else { return }
        dataStore.httpCookieStore.getAllCookies { [dataStore] cookies in
            for cookie in cookies where cookie.domain.lowercased().hasSuffix(host) {
                dataStore.httpCookieStore.delete(cookie)
            }
        }
    }
    private static func cookieHeaderString(from cookies: [HTTPCookie], for url: URL?) -> String {
        let host = url?.host?.lowercased()
        let filtered = cookies.filter { cookie in
            guard let host = host else { return true }
            let domain = cookie.domain.lowercased()
            return domain == host || (domain.hasPrefix(".") && (domain.hasSuffix(host) || host.hasSuffix(domain)))
        }
        return filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    deinit {
        observers.removeAll()
    }
}

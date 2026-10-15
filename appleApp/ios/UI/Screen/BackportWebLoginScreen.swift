import SwiftUI
import WebKit
import Perception
import FlareAppleUI
import NavigationBackport

struct BackportWebLoginScreen: View {
    @Environment(\.dismiss) var dismiss
    @State private var viewModel: BackportWebLoginViewModel?
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
                    BackportWebView(url: URL(string: url), configuration: viewModel.configuration) { webView in
                        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
                        webView.navigationDelegate = viewModel.delegate
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

class WKDelegate: NSObject, WKNavigationDelegate {
    let decidePolicy: () -> Void
    init(decidePolicy: @escaping () -> Void
    ) {
        self.decidePolicy = decidePolicy
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
    @PerceptionIgnored private var observers = [NSKeyValueObservation]()
    init(
        onCookie: @escaping (String) -> Void,
        url: String
    ) {
        self.onCookie = onCookie
        self.url = url
        self.delegate = WKDelegate { [weak self] in
            guard let self else { return }
            // cookie 必须从登录页实际使用的仓库里取。
            self.dataStore.httpCookieStore.getAllCookies { (cookies) in
                let cookieString = BackportWebLoginViewModel.cookieHeaderString(from: cookies, for: .init(string: url))
                onCookie(cookieString)
            }
        }
        // 不再走「清空全部网站数据后再显示」的异步链路，登录页立即可见。
        self.canShowWebView = true
    }
    var configuration: WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 用默认（持久化）仓库：X/微博的登录流程依赖 sessionStorage 与带凭证的
        // XHR，非持久化仓库在部分 iOS 15 上会让登录 POST 静默失败，表现为
        // 「点了下一步一直卡住」。清空旧 cookie 的逻辑见 clearStaleCookies()。
        configuration.websiteDataStore = dataStore
        return configuration
    }
    /// 只清理登录域下的旧 cookie，避免上次登录的残留 cookie 让 canResume 直接通过。
    ///  targeted 删除比上游「清空全部网站数据」快得多，且在页面加载前就发起。
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

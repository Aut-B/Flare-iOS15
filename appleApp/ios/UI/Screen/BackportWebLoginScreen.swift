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
        // iOS 15 回退：viewModel 是 @Perceptible，SwiftUI 不会自动追踪它的属性，
        // 必须把读取点包进 WithPerceptionTracking，否则 canShowWebView 置 true 时
        // 视图不会重算，登录网页迟迟不出现。
        WithPerceptionTracking {
            NBNavigationStack {
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
            viewModel = BackportWebLoginViewModel(onCookie: onCookie, url: url)
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
    /// 非持久化数据仓库：登录页立即显示，且 cookie 读取必须走同一个实例。
    let dataStore = WKWebsiteDataStore.nonPersistent()
    @PerceptionIgnored private var observers = [NSKeyValueObservation]()
    init(
        onCookie: @escaping (String) -> Void,
        url: String
    ) {
        self.onCookie = onCookie
        self.url = url
        self.delegate = WKDelegate { [weak self] in
            guard let self else { return }
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
        // iOS 15 回退：改用非持久化数据仓库。原实现要先 fetchDataRecords + removeData
        // 清空全部网站数据才把 canShowWebView 置 true，这一步是异步的，期间界面停在空白；
        // 非持久化仓库天然隔离，登录页可以立刻出现，cookie 仍能从 httpCookieStore 取到。
        configuration.websiteDataStore = dataStore
        return configuration
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

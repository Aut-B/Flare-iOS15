import SwiftUI
import WebKit
import UIKit
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
                            // 供「重试」按钮 reload 用。
                            viewModel.webView = webView
                        }
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        // 加载失败时给出可见的错误与重试入口，不再是一片纯白。
                        if let loadError = viewModel.loadError {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.icloud")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("加载失败")
                                    .font(.headline)
                                Text(loadError)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    viewModel.loadError = nil
                                    viewModel.webView?.reload()
                                } label: {
                                    Text("重试")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.secondarySystemBackground))
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
                } else if viewModel != nil {
                    // 清空旧网站数据期间的等待指示，避免又是「一片白」。
                    VStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            // Initialize after state is installed so view rebuilds don't clear cookies again.
            guard viewModel == nil else { return }
            let model = BackportWebLoginViewModel(onCookie: onCookie, url: url)
            viewModel = model
            // 与上游行为对齐：先把全部网站数据清空，完成后才显示 WebView。
            // 之前「按 host 定向异步删 cookie + 立即显示」有两个问题：
            // ① 域名后缀匹配方向有漏洞（cookie 在 .weibo.cn、登录 URL 在子域时漏删，
            //    新浪 SSO 域更是完全漏掉），第二个账号登录时旧登录态残留；
            // ② 删除是异步的，页面加载经常 race 赢删除——读到的还是上一个账号的
            //    cookie，Kotlin 侧 canResume 直接通过，sheet 一弹出就被关掉，
            //    表现为「点登录闪一下然后回到登录界面」。
            model.clearAllWebsiteData {
                model.canShowWebView = true
            }
        }
    }
}

class WKDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let decidePolicy: () -> Void
    /// 加载失败时把错误送到界面（ViewModel 初始化完成后赋值）。
    weak var owner: BackportWebLoginViewModel?

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
        guard navigationAction.targetFrame == nil else { return .allow }
        let request = navigationAction.request
        // 只接管 http/https：javascript:/about:blank/data: 等 scheme 拉回主 WebView
        // 只会静默失败，还会把原导航 cancel 掉，页面就停在原地不动。
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .cancel
        }
        // 用原始请求加载：登录流程里的 POST 表单（方法、body、header）不能丢，
        // 只取 url 会把 POST 降级成 GET，登录态直接断。
        webView.load(request)
        return .cancel
    }

    /// 双保险：即使 decidePolicyFor 没拦住，也禁止系统创建模态子窗口，
    /// 把请求拉回主 WebView。返回 nil 即「不创建新窗口」。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = navigationAction.request
        if let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            webView.load(request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        decidePolicy()
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportError(error)
    }

    private func reportError(_ error: Error) {
        let nsError = error as NSError
        // window.open 拦截是我们主动 cancel 的导航，不算加载失败。
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        owner?.loadError = error.localizedDescription
    }
}

@Perceptible
final class BackportWebLoginViewModel {
    var canShowWebView = false
    /// 最近一次加载失败的用户可读信息；nil 表示正常。
    var loadError: String?
    let url: String
    let onCookie: (String) -> Void
    let delegate: WKDelegate
    /// 登录页使用的数据仓库，cookie 的写入与读取必须走同一个实例。
    let dataStore = WKWebsiteDataStore.default()
    /// 配置改为 stored 属性：原来是计算属性，body 每求值一次就新建一个
    /// WKWebViewConfiguration，视图重算时 WebView 会按新配置重建、登录态丢失。
    let configuration: WKWebViewConfiguration
    /// 「重试」用：保存对当前 WebView 的弱引用，不参与 Perception 追踪。
    @PerceptionIgnored weak var webView: WKWebView?
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
        // 「点了下一步一直卡住」。
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // iOS 15 回退：WKPreferences.javaScriptCanOpenWindowsAutomatically 默认 false，
        // window.open 会被静默拦掉（页面像卡住）。打开后 window.open 会走
        // uiDelegate 的 createWebViewWith，由 WKDelegate 把请求拉回主 WebView。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.websiteDataStore = dataStore
        self.configuration = configuration
        // 全部存储属性就绪后，把失败回调接到自己身上。
        self.delegate.owner = self
    }

    /// 与上游一致：清空全部网站数据（cookie/localStorage/sessionStorage 等），
    /// 完成后才让登录页显示 WebView。定向删除既会漏域又有 race，见 screen 内注释。
    func clearAllWebsiteData(completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: records,
                completionHandler: completion
            )
        }
    }

    deinit {
        observers.removeAll()
    }
    private static func cookieHeaderString(from cookies: [HTTPCookie], for url: URL?) -> String {
        let host = url?.host?.lowercased()
        let filtered = cookies.filter { cookie in
            guard let host else { return true }
            let domain = cookie.domain.lowercased()
            return domain == host || (domain.hasPrefix(".") && (domain.hasSuffix(host) || host.hasSuffix(domain)))
        }
        return filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

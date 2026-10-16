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
    /// 诊断日志面板开关。
    @State private var showDebugLog = false
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
                        // 诊断入口：X 登录「输入邮箱后走不到下一步」这类 JS 流程卡死，
                        // 只能靠页面内部的 fetch/XHR/window.open 事件定位。
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    showDebugLog = true
                                } label: {
                                    Text("诊断")
                                        .font(.caption2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.black.opacity(0.55))
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                                .padding(12)
                            }
                        }
                        .allowsHitTesting(true)
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
        .background(
            // 给 WKDelegate 提供宿主 VC：window.open 的真子窗口要从这里全屏 present。
            // pageSheet 在 iOS 15 上带高斯模糊背景且一被下拉关闭流程就断，
            // 所以子窗口用 fullScreen。
            HostingControllerFinder(onFound: { controller in
                viewModel?.hostController = controller
            })
        )
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
        .onDisappear {
            // 登录流程结束（成功/取消）时关掉还挂着的 window.open 子窗口。
            if let child = viewModel?.hostController?.presentedViewController as? ChildWebViewController {
                child.dismiss(animated: true)
            }
        }
        .sheet(isPresented: $showDebugLog) {
            NBNavigationStack {
                WithPerceptionTracking {
                    debugLogSheet
                }
            }
        }
    }

    @ViewBuilder
    private var debugLogSheet: some View {
        let lines = viewModel?.debugLog ?? []
        List {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("登录诊断日志")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                } label: {
                    Label {
                        Text("复制")
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showDebugLog = false
                } label: {
                    Label {
                        Text("关闭")
                    } icon: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}

/// window.open 的真子窗口容器：iOS 15 上系统默认把新窗口呈现成带高斯模糊的
/// pageSheet，一被下拉关闭登录流程就断；这里用自己的 fullScreen VC。
final class ChildWebViewController: UIViewController {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.layer.cornerRadius = 18
        closeButton.frame = CGRect(x: 12, y: 48, width: 36, height: 36)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(closeButton)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}

/// 从 SwiftUI 视图树里拿宿主 UIViewController（responder 链向上找）。
private extension UIView {
    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }
}

private struct HostingControllerFinder: UIViewRepresentable {
    var onFound: (UIViewController) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let controller = uiView.parentViewController {
            onFound(controller)
        }
    }
}

class WKDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let decidePolicy: () -> Void
    /// 加载失败时把错误送到界面（ViewModel 初始化完成后赋值）。
    weak var owner: BackportWebLoginViewModel?

    init(decidePolicy: @escaping () -> Void
    ) {
        self.decidePolicy = decidePolicy
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func log(_ text: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.owner?.appendDebug("\(stamp) \(text)")
        }
    }

    // MARK: - 导航策略

    /// target=_blank / window.open：iOS 15 的系统默认行为是新开一个模态 WebView，
    /// 以高斯模糊背景的 pageSheet 呈现。X 的登录流程（输入邮箱后的下一步、
    /// 「继续使用谷歌」）会把用户带进这个遮罩，而 sheet 一被下拉关闭，
    /// 整个登录流程就断在这里——表现为「点了下一步一直卡住/等不到密码界面」。
    /// 这里把新窗口请求拉回同一个 WebView 加载。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationResponsePolicy {
        guard navigationAction.targetFrame == nil else { return .allow }
        let request = navigationAction.request
        log("targetFrame==nil 导航: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "nil")")
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

    /// window.open：创建真正的子窗口并全屏呈现。系统默认的模态 pageSheet
    /// （高斯模糊）一被下拉关闭流程就断；自己的 fullScreen VC 可控可关。
    /// 已经开着子窗口时不再嵌套，直接复用。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = navigationAction.request
        log("window.open: \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "nil")")

        if let existing = owner?.hostController?.presentedViewController as? ChildWebViewController {
            existing.webView.load(request)
            return existing.webView
        }

        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // 占位窗口（about:blank/javascript:）不接管，交给页面自己处理。
            return nil
        }

        // 用系统传入的 configuration 建子窗口（dataStore 与登录页共享，
        // cookie 写入对父窗口可见）。注意必须手动 load——系统不会自动加载。
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.uiDelegate = self
        child.navigationDelegate = self
        child.customUserAgent = webView.customUserAgent
        child.load(request)

        if let host = owner?.hostController {
            let controller = ChildWebViewController(webView: child)
            controller.modalPresentationStyle = .fullScreen
            host.present(controller, animated: true)
        } else {
            log("window.open 无宿主 VC，退回主窗口加载")
            webView.load(request)
        }
        return child
    }

    /// JS window.close()：把对应子窗口收掉。
    func webViewDidClose(_ webView: WKWebView) {
        log("webViewDidClose")
        if let child = owner?.hostController?.presentedViewController as? ChildWebViewController,
           child.webView === webView {
            child.dismiss(animated: true)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        log("响应: \(navigationResponse.response.url?.absoluteString ?? "nil")")
        decidePolicy()
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("开始加载: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        log("加载完成: \(webView.url?.absoluteString ?? "nil")")
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
        log("加载失败: \(error.localizedDescription)")
        owner?.loadError = error.localizedDescription
    }

    // MARK: - JS 诊断回传

    /// 登录页注入的脚本把 js_error / promise_reject / fetch / xhr /
    /// window_open / submit 事件回传到这里，「输入邮箱后走不到下一步」
    /// 这类卡死只能靠这些事件定位（是 XHR 403 风控、JS 报错还是弹窗被拦）。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let detail = body["detail"] as? String else {
            return
        }
        log("\(type): \(detail)")
    }
}

/// WKUserContentController 强引用 message handler，用代理断开环：
/// controller → proxy -(weak)→ WKDelegate -(weak)→ ViewModel。
private final class MessageHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@Perceptible
final class BackportWebLoginViewModel {
    var canShowWebView = false
    /// 最近一次加载失败的用户可读信息；nil 表示正常。
    var loadError: String?
    /// 登录页内部事件流水（诊断用），最多保留 80 条。
    var debugLog: [String] = []
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
    /// window.open 子窗口的呈现宿主（登录屏的 UIHostingController）。
    @PerceptionIgnored weak var hostController: UIViewController?
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
        // uiDelegate 的 createWebViewWith，由 WKDelegate 创建真子窗口。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.websiteDataStore = dataStore
        // 诊断脚本：documentStart 注入，把页面内部的 JS 错误 / fetch / XHR /
        // window.open / 表单提交事件回传到 native（见 WKDelegate.userContentController）。
        let userContentController = WKUserContentController()
        userContentController.addUserScript(
            WKUserScript(
                source: Self.debugScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userContentController.add(MessageHandlerProxy(delegate: self.delegate), name: "flareLoginDebug")
        configuration.userContentController = userContentController
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

    func appendDebug(_ line: String) {
        debugLog.append(line)
        if debugLog.count > 80 {
            debugLog.removeFirst(debugLog.count - 80)
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

    /// 登录页内部事件采集脚本。注入时机 atDocumentStart，先于页面自身脚本执行，
    /// 因此 fetch/XHR/window.open 的包装不会被页面绕过。
    static let debugScript = #"""
(function(){
var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.flareLoginDebug;
function send(t, d){ if(!h) return; try { h.postMessage({type: t, detail: String(d).substring(0, 300)}); } catch(e){} }
send('injected', location.href);
window.addEventListener('error', function(e){
  send('js_error', (e.message || '?') + ' @' + ((e.filename || '?').split('/').pop()) + ':' + (e.lineno || 0));
});
window.addEventListener('unhandledrejection', function(e){
  var r = e.reason;
  send('promise_reject', (r && (r.message || r.status || r.code)) || String(r));
});
var of = window.fetch;
if (typeof of === 'function') {
  window.fetch = function(){
    var input = arguments[0];
    var url = (typeof input === 'string') ? input : ((input && input.url) || '?');
    send('fetch', url);
    var p = of.apply(this, arguments);
    if (p && p.then) {
      p.then(function(r){ send('fetch_done', r.status + ' ' + url); },
             function(err){ send('fetch_fail', ((err && err.message) || err) + ' ' + url); });
    }
    return p;
  };
}
var oo = window.open;
window.open = function(){ send('window_open', arguments[0]); return oo.apply(this, arguments); };
var xo = XMLHttpRequest.prototype.open, xs = XMLHttpRequest.prototype.send;
XMLHttpRequest.prototype.open = function(m, u){
  this.__flareUrl = m + ' ' + ((typeof u === 'string') ? u : ((u && u.url) || '?'));
  return xo.apply(this, arguments);
};
XMLHttpRequest.prototype.send = function(){
  var x = this;
  try {
    x.addEventListener('loadend', function(){ send('xhr', (x.__flareUrl || '?') + ' -> ' + x.status); });
    x.addEventListener('error', function(){ send('xhr_error', x.__flareUrl || '?'); });
    x.addEventListener('timeout', function(){ send('xhr_timeout', x.__flareUrl || '?'); });
  } catch(e) {}
  return xs.apply(this, arguments);
};
document.addEventListener('submit', function(e){ send('submit', (e.target && e.target.action) || 'form'); }, true);
window.addEventListener('DOMContentLoaded', function(){ send('dom_ready', location.href); });
})();
"""#
}

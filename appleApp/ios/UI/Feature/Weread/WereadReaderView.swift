import SwiftUI
import WebKit

/// 阅读器：直接加载微信读书网页版阅读页。
///
/// 之前是自己调 `publicchapterInfos` 拿目录、再拼 `chapter/e_*` 分片解密正文，
/// 接口一改就整本书都「没有目录」。网页版阅读器本来就是这套内容的最终形态：
/// 排版、目录、划线、字体调节、进度同步都是现成的，还能和手机 App 同步。
struct WereadReaderView: View {
    let book: WereadBook

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    private var readerURL: String {
        "https://weread.qq.com/web/reader/\(book.id)"
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                WereadReaderWebView(
                    url: readerURL,
                    cookie: WereadStore.shared.cookie,
                    isLoading: $isLoading
                )
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let url = URL(string: readerURL) {
                            Link(destination: url) {
                                Label("在浏览器里打开", systemImage: "safari")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct WereadReaderWebView: UIViewRepresentable {
    let url: String
    let cookie: String
    @Binding var isLoading: Bool

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.mobileUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let start: () -> Void = {
            guard let target = URL(string: url) else { return }
            webView.load(URLRequest(url: target))
        }
        // 扫码登录的 cookie 可能只在 Kotlin 那边，粘进来的 cookie 更是在别处，
        // 统一灌进 WKWebsiteDataStore，网页版阅读器才能认得出登录态。
        if cookie.isEmpty {
            start()
        } else {
            CookieJar.write(cookie, domainSuffix: "weread.qq.com", completion: start)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let isLoading: Binding<Bool>

        init(isLoading: Binding<Bool>) {
            self.isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }
    }
}

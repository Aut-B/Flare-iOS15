import SwiftUI
import WebKit

/// 扫码登录微信读书网页版。
///
/// 网页版在移动 UA 下会直接弹「下载 App」，所以这里伪装成桌面 Safari。
/// 登录成功后 cookie（`wr_vid` / `wr_skey`）落在 WKWebView 的 cookie 仓库里，
/// 轮询取一次就够 —— 之后所有接口都靠这几个 cookie。
struct WereadLoginView: View {
    let onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                WereadWebContainer { cookies in
                    WereadStore.shared.adopt(cookies: cookies)
                    if WereadStore.shared.isLoggedIn {
                        onFinish(true)
                        dismiss()
                    }
                }
                .overlay(alignment: .bottom) {
                    Text("用微信扫码登录，登录后会自动返回书架")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("登录微信读书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onFinish(false)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct WereadWebContainer: UIViewRepresentable {
    let onCookies: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookies: onCookies)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 桌面 UA：移动 UA 会被引导去下载 App，看不到扫码界面。
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://weread.qq.com/")!))
        context.coordinator.startPolling()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookies: ([HTTPCookie]) -> Void
        private var timer: Timer?

        init(onCookies: @escaping ([HTTPCookie]) -> Void) {
            self.onCookies = onCookies
        }

        func startPolling() {
            stopPolling()
            // 登录是页面内跳转，`didFinish` 不一定触发，直接轮询 cookie 最稳。
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        private func checkCookies() {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let weread = cookies.filter { $0.domain.contains("weread.qq.com") }
                guard weread.contains(where: { $0.name == "wr_vid" && !$0.value.isEmpty }) else {
                    return
                }
                self.stopPolling()
                DispatchQueue.main.async {
                    self.onCookies(weread)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
        }
    }
}

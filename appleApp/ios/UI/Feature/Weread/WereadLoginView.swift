import SwiftUI
import WebKit
import UIKit

/// 登录微信读书网页版。
///
/// 两条路：
/// 1. 扫码 —— 网页版在移动 UA 下会直接弹「下载 App」，所以伪装成桌面 Safari。
///    登录成功后 cookie（`wr_vid` / `wr_skey`）落在 WKWebView 的 cookie 仓库里，
///    轮询取一次就够。
/// 2. 粘贴 Cookie —— 6s 这类老机器上 WKWebView 连页面都加载不出来，
///    只能让用户在别处登录好，把 cookie 串贴进来。
struct WereadLoginView: View {
    let onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method = 0
    @State private var cookieText = ""
    @State private var pasteError: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("登录方式", selection: $method) {
                    Text("扫码登录").tag(0)
                    Text("粘贴 Cookie").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if method == 0 {
                    qrLogin
                } else {
                    cookieLogin
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

    @ViewBuilder
    private var qrLogin: some View {
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

    @ViewBuilder
    private var cookieLogin: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("如果上面的网页打不开（老设备常见），可以在电脑或手机浏览器里登录 weread.qq.com，从开发者工具复制 Cookie 粘到这里。需要包含 wr_vid 与 wr_skey。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $cookieText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    let value = UIPasteboard.general.string ?? ""
                    pasteError = nil
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        pasteError = "剪贴板是空的，请先复制 Cookie。"
                        return
                    }
                    cookieText = value
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    pasteError = nil
                    if WereadStore.shared.adopt(cookieHeader: cookieText) {
                        onFinish(true)
                        dismiss()
                    } else {
                        pasteError = "Cookie 无效：请确认包含 wr_vid 与 wr_skey，且未过期。"
                    }
                } label: {
                    Text("用 Cookie 登录")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let pasteError {
                    Text(pasteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
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

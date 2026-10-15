#if os(iOS)
typealias WebViewRepresentable = UIViewRepresentable
#elseif os(macOS)
typealias WebViewRepresentable = NSViewRepresentable
#endif

#if os(iOS) || os(macOS)
import SwiftUI
import WebKit

public struct BackportWebView: WebViewRepresentable {

    // MARK: - Initializers
    public init(
        url: URL? = nil,
        configuration: WKWebViewConfiguration? = nil,
        isLoading: Binding<Bool>? = nil,
        webView: @escaping (WKWebView) -> Void = { _ in }) {
        self.url = url
        self.configuration = configuration
        self.isLoading = isLoading
        self.webView = webView
    }

    // MARK: - Properties

    private let url: URL?
    private let configuration: WKWebViewConfiguration?
    private let isLoading: Binding<Bool>?
    private let webView: (WKWebView) -> Void

    // MARK: - Functions

    #if os(iOS)
    public func makeUIView(context: Context) -> WKWebView {
        let view = makeView()
        if let isLoading {
            context.coordinator.startObserving(view, isLoading: isLoading)
        }
        return view
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    #if os(macOS)
    public func makeNSView(context: Context) -> WKWebView {
        makeView()
    }

    public func updateNSView(_ view: WKWebView, context: Context) {}
    #endif

    #if os(iOS)
    /// 观察 WKWebView 的 isLoading，把加载状态传给 SwiftUI 侧显示进度指示。
    /// x.com/Google 的登录页在 iPhone 6S 上首屏可能要十几秒，没有指示时
    /// 用户看到的就是「一片白屏」。
    public final class Coordinator {
        private var observations: [NSKeyValueObservation] = []

        func startObserving(_ view: WKWebView, isLoading: Binding<Bool>) {
            isLoading.wrappedValue = view.isLoading
            observations.removeAll()
            observations.append(
                view.observe(\.isLoading, options: [.new]) { view, _ in
                    DispatchQueue.main.async {
                        isLoading.wrappedValue = view.isLoading
                    }
                }
            )
        }

        deinit {
            observations.removeAll()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    #endif
}

private extension BackportWebView {

    func makeWebView() -> WKWebView {
        guard let configuration = self.configuration else { return WKWebView() }
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func makeView() -> WKWebView {
        let view = makeWebView()
        webView(view)
        tryLoad(url, into: view)
        return view
    }

    func tryLoad(_ url: URL?, into view: WKWebView) {
        guard let url = url else { return }
        view.load(URLRequest(url: url))
    }
}
#endif

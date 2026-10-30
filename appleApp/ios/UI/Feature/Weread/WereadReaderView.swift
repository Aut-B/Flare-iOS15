import SwiftUI
import WebKit

/// 阅读器：目录 + 正文 + 翻章。
///
/// 正文用 `WKWebView` 渲染服务端给的 HTML，排版跟网页版一致（衬线字体、
/// 段落缩进、图片居中），比自己重新排版省事，也不会把注脚、图注弄丢。
struct WereadReaderView: View {
    let book: WereadBook

    @ObservedObject private var store = WereadStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [WereadChapter] = []
    @State private var index = 0
    @State private var html = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showTOC = false

    private var current: WereadChapter? {
        chapters.indices.contains(index) ? chapters[index] : nil
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                content
                if let current {
                    bottomBar(current)
                }
            }
            .background(WereadTheme.paper)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showTOC = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(chapters.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showTOC) {
            WereadTOCView(chapters: chapters, currentIndex: index) { picked in
                showTOC = false
                Task { await open(picked) }
            }
        }
        .task {
            if chapters.isEmpty {
                await bootstrap()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(errorText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                if !store.isLoggedIn {
                    Button("重新登录") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("重试") {
                        Task { await reload() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if html.isEmpty, isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WereadContentWebView(html: html)
        }
    }

    private func bottomBar(_ chapter: WereadChapter) -> some View {
        HStack {
            Button {
                Task { await step(-1) }
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13))
            }
            .disabled(index <= 0 || isLoading)

            Spacer()

            Text(chapter.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            Spacer()

            Button {
                Task { await step(1) }
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13))
            }
            .disabled(index >= chapters.count - 1 || isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 加载

    private func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await store.chapters(for: book.id)
            guard !list.isEmpty else {
                errorText = "这本书没有目录，可能不支持网页阅读"
                return
            }
            chapters = list

            // 接着上次读的那一章。
            let saved = await store.progress(for: book.id)
            if let saved, let position = list.firstIndex(where: { $0.uid == saved.chapterUid }) {
                index = position
            }
            await loadCurrent()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reload() async {
        errorText = nil
        await loadCurrent()
    }

    private func step(_ delta: Int) async {
        let next = index + delta
        guard chapters.indices.contains(next) else { return }
        index = next
        await loadCurrent()
    }

    private func open(_ chapter: WereadChapter) async {
        guard let position = chapters.firstIndex(where: { $0.uid == chapter.uid }) else { return }
        index = position
        await loadCurrent()
    }

    private func loadCurrent() async {
        guard let chapter = current else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let body = try await store.content(bookId: book.id, chapterUid: chapter.uid)
            html = WereadTheme.wrap(body)
            store.report(bookId: book.id, chapterUid: chapter.uid, offset: 0)
        } catch {
            html = ""
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 目录

private struct WereadTOCView: View {
    let chapters: [WereadChapter]
    let currentIndex: Int
    let onPick: (WereadChapter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.uid) { offset, chapter in
                    Button {
                        onPick(chapter)
                    } label: {
                        HStack(spacing: 8) {
                            Text(chapter.title)
                                .font(.system(size: 14, weight: offset == currentIndex ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if offset == currentIndex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.leading, CGFloat(max(chapter.level - 1, 0)) * 10)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 正文渲染

private enum WereadTheme {
    /// 微信读书网页版的纸色。
    static let paper = Color(red: 0.965, green: 0.949, blue: 0.914)

    /// 把服务端的 HTML 套一层自己的排版：正文里那些 `wr_` 类名依赖网页版的
    /// 全局样式表，单独拿出来会没有字号和行高。
    static func wrap(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        :root { color-scheme: light; }
        html, body {
            margin: 0; padding: 0;
            background: #f6f1e9;
            color: #2b2b2b;
            -webkit-text-size-adjust: 100%;
        }
        body {
            font-family: -apple-system, "PingFang SC", "Songti SC", serif;
            font-size: 18px;
            line-height: 1.85;
            padding: 20px 20px 60px;
            word-wrap: break-word;
        }
        p { margin: 0 0 1.05em; text-align: justify; text-indent: 2em; }
        h1, h2, h3 { font-weight: 600; margin: 1.4em 0 0.7em; text-indent: 0; }
        h1 { font-size: 1.35em; }
        h2 { font-size: 1.2em; }
        h3 { font-size: 1.05em; }
        img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
        blockquote { margin: 1em 0; padding: 0.4em 1em; border-left: 3px solid #d8cfc0; color: #5a5a5a; }
        table { width: 100%; border-collapse: collapse; font-size: 0.92em; }
        td, th { border: 1px solid #ddd5c8; padding: 4px 6px; }
        a { color: #1a6bd6; text-decoration: none; }
        .readerChapterContent { padding: 0 !important; }
        </style>
        </head><body><div class="readerChapterContent">\(body)</div></body></html>
        """
    }
}

private struct WereadContentWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        guard !html.isEmpty else { return }
        webView.loadHTMLString(html, baseURL: URL(string: "https://weread.qq.com/"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var loadedHTML: String?
    }
}

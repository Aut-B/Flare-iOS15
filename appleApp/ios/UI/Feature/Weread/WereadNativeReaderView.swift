import SwiftUI
import WebKit
import UIKit

/// 原生书架点书后直接打开的目标。
struct WereadNativeTarget: Identifiable {
    let book: WereadBook

    var id: String { book.id }
}

/// 微信读书原生阅读页。
///
/// 不再先打开 `/web/shelf` 再让网页自己点书：目录走
/// `publicchapterInfos`，正文走 `chapter/e_*` + 解密，直接渲染当前章节。
/// 这样点书就是「目录 + 第一章」，不会白屏等网页阅读器加载，也不会出现
/// 标题还是上一本书、返回不到书架的问题。
///
/// 正文仍然用 `WKWebView` 渲染（章节 HTML 自带排版和图片），但页面是我们
/// 自己生成的：可以强制打开文本选择，并支持本地划线和想法。
struct WereadNativeReaderView: View {
    let target: WereadNativeTarget

    @ObservedObject private var store = WereadStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [WereadChapter] = []
    @State private var index = 0
    @State private var html = ""
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showChapters = false
    @State private var showWeb = false
    @State private var cache: [Int: String] = [:]
    @State private var highlights: [Int: [WereadHighlight]] = [:]
    @State private var scrollFraction: Double = 0
    @State private var loadToken = 0

    private var current: WereadChapter? {
        chapters.indices.contains(index) ? chapters[index] : nil
    }

    private var currentHighlights: [WereadHighlight] {
        guard let current else { return [] }
        return highlights[current.uid] ?? []
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // 章节 WebView 必须常驻：一旦从视图树里拿掉，WKWebView 就被销毁，
            // 再挂回来又要重新加载一次 HTML，白屏时间翻倍。
            if !html.isEmpty {
                reader
            }

            if loading, html.isEmpty {
                loadingView
            } else if loading {
                // 正文已经拿到、WebView 还在排版时盖一层加载提示，
                // 不要让用户对着一片白屏等。
                loadingOverlay
            } else if let errorMessage, html.isEmpty {
                errorView(errorMessage)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .statusBar(hidden: true)
        .task { await load() }
        .sheet(isPresented: $showChapters) {
            chapterList
        }
        .fullScreenCover(isPresented: $showWeb) {
            WereadReaderView(
                target: WereadReaderTarget(
                    url: "https://weread.qq.com/web/shelf",
                    title: target.book.title,
                    bookId: target.book.id,
                    needsJump: true
                )
            )
        }
        .onDisappear { saveProgress() }
    }

    // MARK: - 页面

    private var reader: some View {
        // 记住生成这个 reader 时的加载代次；`onReady` 是 escaping 闭包，
        // 会晚于翻章触发，代次不一致就说明是上一章的渲染完成。
        let token = loadToken
        WereadChapterWebView(
            html: html,
            baseURL: URL(string: "https://weread.qq.com/"),
            cookie: store.cookie,
            highlights: currentHighlights,
            onHighlight: { item in
                guard let chapter = current else { return }
                var list = highlights[chapter.uid] ?? []
                if let position = list.firstIndex(where: { $0.id == item.id }) {
                    list[position] = item
                } else {
                    list.append(item)
                }
                highlights[chapter.uid] = list
                WereadHighlightStore.save(list, bookId: target.book.id, chapterUid: chapter.uid)
            },
            onScroll: { value in
                scrollFraction = min(max(value, 0), 1)
            },
            onReady: {
                // 只认当前这一次加载的渲染完成：翻章时旧页面的 ready
                // 不应该把新章节的 loading 提前关掉。
                if token == self.loadToken { loading = false }
            }
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                saveProgress()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回书架")

            VStack(alignment: .leading, spacing: 1) {
                Text(target.book.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(current?.title ?? "正在打开…")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                showChapters = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("目录")

            Menu {
                Button {
                    Task { await reloadChapter() }
                } label: {
                    Label("重新加载本章", systemImage: "arrow.clockwise")
                }
                Button {
                    showWeb = true
                } label: {
                    Label("网页版阅读器", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button {
                Task { await open(index - 1) }
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(index <= 0)
            .opacity(index <= 0 ? 0.35 : 1)

            Spacer(minLength: 0)

            Text(chapters.isEmpty ? "" : "\(index + 1) / \(chapters.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                Task { await open(index + 1) }
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(index >= chapters.count - 1)
            .opacity(index >= chapters.count - 1 ? 0.35 : 1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在打开《\(target.book.title)》…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("直接读取目录和章节，不再经过网页书架")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    /// 正文已到、WebView 还在排版时的过渡层。
    private var loadingOverlay: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(0.94)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView()
                Text(current?.title.isEmpty == false ? "正在排版本章…" : "正在打开…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("重试") {
                Task { await load(force: true) }
            }
            .buttonStyle(.borderedProminent)
            Button("用网页版打开") {
                showWeb = true
            }
            .font(.footnote)
        }
        .padding(30)
    }

    private var chapterList: some View {
        NavigationView {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, chapter in
                    Button {
                        showChapters = false
                        Task { await open(offset) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(chapter.title.isEmpty ? "第 \(offset + 1) 章" : chapter.title)
                                .font(.system(size: 15))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if offset == index {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, CGFloat(max(chapter.level - 1, 0)) * 12)
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showChapters = false }
                }
            }
        }
    }

    // MARK: - 加载

    @MainActor
    private func load(force: Bool = false) async {
        if !force, !chapters.isEmpty { return }
        loadToken += 1
        let token = loadToken
        loading = true
        errorMessage = nil
        html = ""
        do {
            // 目录和阅读进度互不依赖，并行发出去，少等一个来回。
            // 这里直接走 service 而不是 store，避免并发闭包捕获 self。
            let service = WereadService.shared
            let bookId = target.book.id
            let cookie = store.cookie
            async let progressTask = service.progress(bookId: bookId, cookie: cookie)
            let list = try await store.chapters(for: target.book.id)
            guard token == loadToken else { return }
            guard !list.isEmpty else { throw WereadError.empty }
            chapters = list

            var start = 0
            if let progress = try? await progressTask,
               let position = list.firstIndex(where: { $0.uid == progress.chapterUid }) {
                start = position
            }
            index = start
            await loadChapter(at: start, token: token)
        } catch {
            guard token == loadToken else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadChapter() async {
        guard let current else { return }
        cache[current.uid] = nil
        loadToken += 1
        await loadChapter(at: index, token: loadToken)
    }

    @MainActor
    private func open(_ position: Int) async {
        guard chapters.indices.contains(position) else { return }
        guard position != index else { return }
        saveProgress()
        loadToken += 1
        await loadChapter(at: position, token: loadToken)
    }

    @MainActor
    private func loadChapter(at position: Int, token: Int) async {
        guard chapters.indices.contains(position) else { return }
        index = position
        scrollFraction = 0
        loading = true
        errorMessage = nil
        // 先清掉上一章正文：否则请求期间标题已经换成新章，正文还是旧章，
        // 看起来像「点进去内容不对」。
        html = ""

        let chapter = chapters[position]
        if highlights[chapter.uid] == nil {
            highlights[chapter.uid] = WereadHighlightStore.load(
                bookId: target.book.id,
                chapterUid: chapter.uid
            )
        }
        if let cached = cache[chapter.uid] {
            html = cached
            await waitForRender(token: token)
            prefetch(after: position)
            return
        }

        do {
            let raw = try await store.content(bookId: target.book.id, chapterUid: chapter.uid)
            guard token == loadToken else { return }
            let wrapped = WereadReaderHTML.wrap(raw)
            cache[chapter.uid] = wrapped
            html = wrapped
            // 不再「赋完 html 就算加载完」：那时候 WebView 还没排版，
            // 用户看到的是白屏。等 `onReady` 或超时兜底。
            await waitForRender(token: token)
            prefetch(after: position)
        } catch {
            guard token == loadToken else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    /// 等 WebView 真正渲染完（`didFinish` / JS `ready`）。
    /// 图片一直加载时 `didFinish` 也可能迟迟不来，最多等 3 秒就放行，
    /// 免得一直卡在转圈。
    @MainActor
    private func waitForRender(token: Int) async {
        for _ in 0..<30 {
            if token != loadToken { return }
            if !loading { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if token == loadToken {
            loading = false
        }
    }

    /// 预取下一章：翻章时不用再等网络。失败就算了，不影响当前章。
    private func prefetch(after position: Int) {
        let next = position + 1
        guard chapters.indices.contains(next) else { return }
        let chapter = chapters[next]
        guard cache[chapter.uid] == nil else { return }
        let bookId = target.book.id
        Task {
            guard let raw = try? await store.content(bookId: bookId, chapterUid: chapter.uid) else {
                return
            }
            let wrapped = WereadReaderHTML.wrap(raw)
            await MainActor.run {
                if self.cache[chapter.uid] == nil {
                    self.cache[chapter.uid] = wrapped
                }
            }
        }
    }

    private func saveProgress() {
        guard let current else { return }
        let offset = Int(Double(max(current.wordCount, 1)) * scrollFraction)
        store.report(bookId: target.book.id, chapterUid: current.uid, offset: offset)
    }
}

// MARK: - 划线 / 想法

struct WereadHighlight: Codable, Hashable, Identifiable {
    let id: String
    let text: String
    let note: String
}

enum WereadHighlightStore {
    private static func key(bookId: String, chapterUid: Int) -> String {
        "weread.highlights.\(bookId).\(chapterUid)"
    }

    static func load(bookId: String, chapterUid: Int) -> [WereadHighlight] {
        guard
            let data = UserDefaults.standard.data(forKey: key(bookId: bookId, chapterUid: chapterUid)),
            let list = try? JSONDecoder().decode([WereadHighlight].self, from: data)
        else {
            return []
        }
        return list
    }

    static func save(_ list: [WereadHighlight], bookId: String, chapterUid: Int) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key(bookId: bookId, chapterUid: chapterUid))
    }
}

// MARK: - 章节 WebView

private struct WereadChapterWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    let cookie: String
    let highlights: [WereadHighlight]
    let onHighlight: (WereadHighlight) -> Void
    let onScroll: (Double) -> Void
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "weread")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(html, in: webView, baseURL: baseURL, cookie: cookie)
        context.coordinator.apply(highlights, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "weread")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WereadChapterWebView
        private var lastHTML = ""
        private var lastHighlights = ""
        private var loaded = false

        init(_ parent: WereadChapterWebView) {
            self.parent = parent
        }

        func load(_ html: String, in webView: WKWebView, baseURL: URL?, cookie: String) {
            guard !html.isEmpty, html != lastHTML else { return }
            lastHTML = html
            lastHighlights = ""
            loaded = false
            install(cookies: cookie, in: webView) {
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func apply(_ highlights: [WereadHighlight], in webView: WKWebView) {
            let encoder = JSONEncoder()
            guard
                let data = try? encoder.encode(highlights),
                let json = String(data: data, encoding: .utf8),
                json != lastHighlights,
                loaded
            else {
                return
            }
            lastHighlights = json
            webView.evaluateJavaScript("window.__wrRestore(\(json));", completionHandler: nil)
        }

        private func install(cookies header: String, in webView: WKWebView, completion: @escaping () -> Void) {
            let cookies = WereadCookieParser.parse(header)
            guard !cookies.isEmpty else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            markReady(in: webView)
        }

        /// 页面可交互了：恢复本地划线，并通知 SwiftUI 收起加载层。
        private func markReady(in webView: WKWebView?) {
            loaded = true
            lastHighlights = ""
            if let webView = webView {
                apply(parent.highlights, in: webView)
            }
            DispatchQueue.main.async {
                self.parent.onReady()
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else {
                return
            }
            switch type {
            case "ready":
                // JS 解析完正文就会发 ready，比 didFinish 更早，先用它把
                // 白屏收掉；两边都调一次，markReady 本身是幂等的。
                markReady(in: message.webView)
            case "highlight":
                let id = (body["id"] as? String) ?? UUID().uuidString
                let text = (body["text"] as? String) ?? ""
                let note = (body["note"] as? String) ?? ""
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    self.parent.onHighlight(WereadHighlight(id: id, text: text, note: note))
                }
            case "scroll":
                let value = (body["value"] as? NSNumber)?.doubleValue ?? 0
                DispatchQueue.main.async {
                    self.parent.onScroll(value)
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = defaultText
                field.placeholder = "写点什么…"
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completionHandler(nil)
            })
            alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text ?? "")
            })
            topViewController()?.present(alert, animated: true)
        }

        private func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }
    }
}

private enum WereadCookieParser {
    static func parse(_ header: String) -> [HTTPCookie] {
        header
            .split(separator: ";")
            .compactMap { part in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { return nil }
                return HTTPCookie(properties: [
                    .domain: ".weread.qq.com",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                ])
            }
    }
}

// MARK: - 章节 HTML

enum WereadReaderHTML {
    static func wrap(_ body: String) -> String {
        let normalized = normalize(body)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        :root { color-scheme: light dark; }
        html, body {
            margin: 0;
            padding: 18px 18px 48px;
            background: transparent;
            color: #1c1c1e;
            font: 17px/1.85 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        html, body {
            -webkit-user-select: none !important;
            user-select: none !important;
            -webkit-touch-callout: none !important;
        }
        /* 只给真正承载文字的节点开选择。以前把 `#wr-content *` 整个打开，
           长按会命中外层容器，一拖就把整章当成一个选区（用户说的
           「一选择就是全页」）。容器保持 none，文字节点单独开 text。 */
        #wr-content p, #wr-content h1, #wr-content h2, #wr-content h3,
        #wr-content h4, #wr-content h5, #wr-content h6, #wr-content li,
        #wr-content blockquote, #wr-content pre, #wr-content code,
        #wr-content td, #wr-content th, #wr-content em, #wr-content strong,
        #wr-content span, #wr-content a, #wr-content i, #wr-content b,
        #wr-content u, #wr-content font {
            -webkit-user-select: text !important;
            user-select: text !important;
            -webkit-touch-callout: default !important;
        }
        #wr-content img {
            -webkit-user-select: none !important;
            user-select: none !important;
            -webkit-touch-callout: none !important;
        }
        #wr-tools, #wr-tools * {
            -webkit-user-select: none !important;
            user-select: none !important;
            -webkit-touch-callout: none !important;
        }
        img { max-width: 100% !important; height: auto !important; }
        p { margin: 0 0 1em; }
        h1, h2, h3, h4 { line-height: 1.4; margin: 1.2em 0 0.6em; }
        mark.wr-hl {
            background: #ffe58a;
            color: inherit;
            border-radius: 2px;
            padding: 0 1px;
        }
        mark.wr-hl[data-note]:not([data-note=""]) {
            border-bottom: 2px solid #f0a020;
        }
        #wr-tools {
            position: fixed;
            display: none;
            z-index: 99999;
            gap: 6px;
            padding: 5px;
            border-radius: 10px;
            background: rgba(28, 28, 30, 0.92);
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25);
        }
        #wr-tools button {
            border: 0;
            border-radius: 7px;
            padding: 7px 12px;
            font: 13px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
            color: #fff;
            background: transparent;
        }
        #wr-tools button:active { background: rgba(255, 255, 255, 0.16); }
        @media (prefers-color-scheme: dark) {
            html, body { color: #e5e5e7; }
            mark.wr-hl { background: #6b5a00; }
        }
        </style>
        </head>
        <body>
        <div id="wr-content">\(normalized)</div>
        <div id="wr-tools">
            <button id="wr-hl" type="button">划线</button>
            <button id="wr-note" type="button">想法</button>
        </div>
        <script>
        (function () {
            var tools = document.getElementById('wr-tools');
            var savedRange = null;

            function hideTools() {
                tools.style.display = 'none';
            }

            function selectedText() {
                var selection = window.getSelection();
                if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
                var text = String(selection.toString() || '').trim();
                if (!text) return null;
                return { selection: selection, range: selection.getRangeAt(0), text: text };
            }

            document.addEventListener('selectionchange', function () {
                setTimeout(function () {
                    var current = selectedText();
                    if (!current) { hideTools(); return; }
                    var rect = current.range.getBoundingClientRect();
                    if (!rect || (rect.width === 0 && rect.height === 0)) { hideTools(); return; }
                    var top = rect.top - 46;
                    if (top < 8) top = rect.bottom + 8;
                    var left = Math.min(Math.max(rect.left + rect.width / 2 - 62, 8), window.innerWidth - 132);
                    tools.style.top = top + 'px';
                    tools.style.left = left + 'px';
                    tools.style.display = 'flex';
                    savedRange = current.range.cloneRange();
                }, 120);
            });

            function wrapSelection(note) {
                var current = selectedText();
                var range = current ? current.range : savedRange;
                if (!range) return;
                var text = String(range.toString() || '').trim();
                if (!text) return;

                var mark = document.createElement('mark');
                mark.className = 'wr-hl';
                mark.id = 'h' + Date.now();
                mark.setAttribute('data-note', note || '');
                if (note) mark.title = note;

                try {
                    range.surroundContents(mark);
                } catch (error) {
                    var fragment = range.extractContents();
                    mark.appendChild(fragment);
                    range.insertNode(mark);
                }

                window.webkit.messageHandlers.weread.postMessage({
                    type: 'highlight',
                    id: mark.id,
                    text: text,
                    note: note || ''
                });
                if (current) current.selection.removeAllRanges();
                hideTools();
                savedRange = null;
            }

            function keepSelection(event) {
                event.preventDefault();
                event.stopPropagation();
            }
            ['touchstart', 'touchend', 'mousedown'].forEach(function (name) {
                document.getElementById('wr-hl').addEventListener(name, keepSelection, { passive: false });
                document.getElementById('wr-note').addEventListener(name, keepSelection, { passive: false });
            });

            document.getElementById('wr-hl').addEventListener('click', function (event) {
                event.preventDefault();
                wrapSelection('');
            });

            document.getElementById('wr-note').addEventListener('click', function (event) {
                event.preventDefault();
                var note = window.prompt('写想法', '');
                if (note === null) return;
                wrapSelection(note);
            });

            window.__wrRestore = function (list) {
                if (!list || !list.length) return;
                var root = document.getElementById('wr-content');
                if (!root) return;
                list.forEach(function (item) {
                    if (item.id && document.getElementById(item.id)) return;
                    var full = String(item.text || '');
                    var needle = full.slice(0, 40);
                    if (!needle) return;
                    // 每一条都新建 walker：上一次 surroundContents 会把文本节点
                    // 拆开，复用旧 walker 会让第二条之后的划线找不到文本。
                    var walker = document.createTreeWalker(root, 4, null);
                    var node = null;
                    while ((node = walker.nextNode())) {
                        if (!node.nodeValue) continue;
                        if (node.parentElement && node.parentElement.closest('mark.wr-hl')) continue;
                        var at = node.nodeValue.indexOf(needle);
                        if (at < 0) continue;
                        var range = document.createRange();
                        range.setStart(node, at);
                        range.setEnd(node, Math.min(at + full.length, node.nodeValue.length));
                        var mark = document.createElement('mark');
                        mark.className = 'wr-hl';
                        mark.id = item.id || ('h' + Date.now());
                        mark.setAttribute('data-note', item.note || '');
                        if (item.note) mark.title = item.note;
                        try { range.surroundContents(mark); } catch (error) {}
                        break;
                    }
                });
            };

            var last = 0;
            window.addEventListener('scroll', function () {
                var max = document.documentElement.scrollHeight - window.innerHeight;
                var value = max > 0 ? window.scrollY / max : 0;
                var now = Date.now();
                if (now - last < 300) return;
                last = now;
                window.webkit.messageHandlers.weread.postMessage({ type: 'scroll', value: value });
            }, { passive: true });

            window.webkit.messageHandlers.weread.postMessage({ type: 'ready' });
        })();
        </script>
        </body>
        </html>
        """
    }

    /// 纯文本章节（老 txt 书）里没有任何标签，整章会变成**一个文本节点**：
    /// 长按要么选不动、要么一拖就整章全选。这里按行包成 `<p>`，
    /// 划线 / 想法才能按段落工作。
    private static func normalize(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        let lower = trimmed.lowercased()
        if lower.contains("<p") || lower.contains("<div") || lower.contains("<br")
            || lower.contains("<h1") || lower.contains("<h2") || lower.contains("<h3")
        {
            return trimmed
        }
        let paragraphs = trimmed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escape($0))</p>" }
        return paragraphs.isEmpty ? trimmed : paragraphs.joined()
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

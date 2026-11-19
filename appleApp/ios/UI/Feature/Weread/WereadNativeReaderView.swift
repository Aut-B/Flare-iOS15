import SwiftUI
import WebKit
import UIKit
import os

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
    /// 章节正文缓存的「最近使用顺序」，队尾最新。配合 `cacheCapacity` 做淘汰。
    /// 以前 cache 只增不减，读一本几百章的书会把整本 HTML 都攒在内存里，
    /// iPhone 6s 只有 2GB，翻到后面容易被系统杀掉。
    @State private var cacheOrder: [Int] = []
    @State private var highlights: [Int: [WereadHighlight]] = [:]
    @State private var scrollFraction: Double = 0
    /// 进章后要跳到的章内比例（0~1）。只在「打开这本书」时用一次，
    /// 翻章/重载都不该复用 —— 那些场景本来就要从头看。
    @State private var restoreFraction: Double = 0
    /// 待执行的滚动请求。非 nil 时 `updateUIView` 会把它发给 JS 的 `__wrScrollTo`，
    /// 发完立刻清空；用「值变化」驱动而不是闭包，避免 WebView 重建后请求丢失。
    @State private var scrollRequest: Double?
    @State private var loadToken = 0

    /// 正文缓存最多留几章。一章 HTML 通常几十到几百 KB，留 3 章既能覆盖
    /// 「来回翻两页」，又不会在 2GB 设备上把内存顶满。
    private static let cacheCapacity = 3

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
        return WereadChapterWebView(
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
            scrollRequest: scrollRequest,
            onScrollApplied: {
                // 请求已经交给 WebView，清掉，避免下次 updateUIView 重复滚。
                if scrollRequest != nil { scrollRequest = nil }
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
            // 目录为空时 store.chapters 已经抛错；这里再兜一次，
            // 但**必须把 loading 关掉**，否则界面永远停在「正在打开…」，
            // 既没有正文也没有错误提示 —— 也就是纯白屏。
            guard !list.isEmpty else {
                loading = false
                errorMessage = WereadError.empty.localizedDescription
                return
            }
            chapters = list

            var start = 0
            // 续读位置：以前只拿 chapterUid 定位到「章」，chapterOffset 取了
            // 却从没用过，所以每次重开都停在章首。这里把它换成章内比例，
            // 等 WebView 渲染完再滚过去（见 restoreFraction）。
            var resume: Double = 0
            if let progress = try? await progressTask,
               let position = list.firstIndex(where: { $0.uid == progress.chapterUid }) {
                start = position
                let words = max(list[position].wordCount, 1)
                if progress.chapterOffset > 0 {
                    resume = min(max(Double(progress.chapterOffset) / Double(words), 0), 1)
                }
            }
            index = start
            restoreFraction = resume
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
        // 清缓存要连 LRU 队列一起清，否则队列里留着一个永远不存在的条目。
        cache[current.uid] = nil
        cacheOrder.removeAll { $0 == current.uid }
        // 重新加载本章是用户主动动作，从章首开始，不要复用续读位置。
        restoreFraction = 0
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
            restoreScrollIfNeeded(token: token)
            prefetch(after: position)
            return
        }

        do {
            let raw = try await store.content(bookId: target.book.id, chapterUid: chapter.uid)
            guard token == loadToken else { return }
            let wrapped = WereadReaderHTML.wrap(raw)
            rememberInCache(chapter.uid, wrapped)
            html = wrapped
            // 不再「赋完 html 就算加载完」：那时候 WebView 还没排版，
            // 用户看到的是白屏。等 `onReady` 或超时兜底。
            await waitForRender(token: token)
            restoreScrollIfNeeded(token: token)
            prefetch(after: position)
        } catch {
            guard token == loadToken else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    /// 写缓存并按 LRU 淘汰。
    ///
    /// `cacheOrder` 队尾是最近用过的；超过 `cacheCapacity` 就从队头丢。
    /// 只丢正文，不碰 `highlights`（划线是用户数据，不是缓存）。
    private func rememberInCache(_ uid: Int, _ html: String) {
        cache[uid] = html
        cacheOrder.removeAll { $0 == uid }
        cacheOrder.append(uid)
        while cacheOrder.count > Self.cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            cache[evicted] = nil
        }
    }

    /// 打开书之后，把 WebView 滚到上次读到的位置。
    ///
    /// 只在「这本书第一次进章」时执行一次：`restoreFraction` 用完立刻清零，
    /// 否则后面手动翻章会被反复拽回原位（用户会觉得页面在抢滚动）。
    /// 调用点都在 `waitForRender` 之后，确保 DOM 已排版，`scrollTo` 才有意义。
    private func restoreScrollIfNeeded(token: Int) {
        let fraction = restoreFraction
        guard fraction > 0.001, token == loadToken else { return }
        restoreFraction = 0
        scrollFraction = fraction
        scrollRequest = fraction
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
                    // 预取也走 LRU：否则预取会把缓存撑到无上限，
                    // A3 那个内存问题就等于没修。
                    self.rememberInCache(chapter.uid, wrapped)
                }
            }
        }
    }

    private func saveProgress() {
        guard let current else { return }
        let offset = Int(Double(max(current.wordCount, 1)) * scrollFraction)
        store.report(
            bookId: target.book.id,
            chapterUid: current.uid,
            offset: offset,
            chapterIndex: index
        )
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
    /// 待执行的章内滚动比例。非 nil 时在页面 ready 之后滚过去。
    let scrollRequest: Double?
    /// 滚动请求已经处理（无论成功失败都要回调，否则会一直重试）。
    let onScrollApplied: () -> Void
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
        context.coordinator.requestScroll(scrollRequest, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "weread")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        /// 统一日志：只看失败原因，不打印正文/划线内容。
        static let log = Logger(subsystem: "dev.dimension.flare.weread", category: "reader")

        var parent: WereadChapterWebView
        private var lastHTML = ""
        private var lastHighlights = ""
        private var loaded = false
        /// 页面还没 ready 时收到的滚动请求，等 `markReady` 再补执行。
        private var pendingScroll: Double?

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
            // 直接拼 JSON 有两个坑：
            // 1. `JSONEncoder` 不转义 U+2028/U+2029，而 `evaluateJavaScript`
            //    是把整段当源码解析 —— 旧引擎语义下这两个字符等同于换行，
            //    拼出来的脚本会语法错误，划线整批恢复不了。
            // 2. 以前 `completionHandler: nil`，失败了没有任何痕迹。
            // 这里转义 + 记录失败原因（只记条数和错误，不记划线正文）。
            let literal = Self.javaScriptStringLiteral(json)
            webView.evaluateJavaScript("window.__wrRestore(\(literal));") { _, error in
                guard let error = error else { return }
                Self.log.error(
                    "weread restore highlights failed (count=\(highlights.count, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
            }
        }

        /// 把 JSON 文本包成一个 JS 字符串并安全传给 `JSON.parse`。
        ///
        /// 走两个反斜杠转义而不是直接内联，是为了彻底绕开 U+2028/U+2029 和
        /// 任何引号/反斜杠问题：`JSON.parse` 只认纯 JSON，比内联字面量稳。
        private static func javaScriptStringLiteral(_ text: String) -> String {
            var escaped = text
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
            escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
            escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
            escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
            escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            return "JSON.parse(\"\(escaped)\")"
        }

        /// 在页面 ready 之后把 WebView 滚到指定比例。
        ///
        /// 只在 `loaded == true` 时执行：排版前 `scrollTo` 会落到 0（页面高度还是 0），
        /// 那就是「每次都回到章首」的老毛病。还没 ready 就先记着，等 `markReady` 再补。
        func requestScroll(_ fraction: Double?, in webView: WKWebView) {
            guard let fraction = fraction else { return }
            guard loaded else {
                pendingScroll = fraction
                return
            }
            performScroll(fraction, in: webView)
        }

        private func performScroll(_ fraction: Double, in webView: WKWebView) {
            pendingScroll = nil
            let clamped = min(max(fraction, 0), 1)
            let script = """
            (function(){
              var h = document.documentElement;
              var max = h.scrollHeight - window.innerHeight;
              if (!(max > 0)) { return false; }
              window.scrollTo(0, Math.round(max * \(clamped)));
              return true;
            })()
            """
            webView.evaluateJavaScript(script) { value, error in
                if let error = error {
                    Self.log.error(
                        "weread restore scroll failed: \(String(describing: error), privacy: .public)"
                    )
                } else if (value as? Bool) == false {
                    Self.log.debug("weread restore scroll skipped: page not scrollable yet")
                }
                // 无论成败都清掉请求：失败时反复重试只会和用户手动滚动打架。
                DispatchQueue.main.async { self.parent.onScrollApplied() }
            }
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
                // 排版完成后再补执行挂起的续读滚动。
                if let pending = pendingScroll {
                    performScroll(pending, in: webView)
                }
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
        /* 不要给 html/body 设 user-select:none：iOS 15 的 WKWebView 里，
           祖先一旦是 none，子节点的 user-select:text 经常盖不回来，直接表现
           为「怎么长按都选不了字」。正文整块放开选择，只对图片和工具条禁止。 */
        #wr-content,
        #wr-content p, #wr-content div, #wr-content section, #wr-content article,
        #wr-content h1, #wr-content h2, #wr-content h3,
        #wr-content h4, #wr-content h5, #wr-content h6, #wr-content li,
        #wr-content blockquote, #wr-content pre, #wr-content code,
        #wr-content td, #wr-content th, #wr-content tr, #wr-content tbody,
        #wr-content em, #wr-content strong, #wr-content mark,
        #wr-content span, #wr-content a, #wr-content i, #wr-content b,
        #wr-content u, #wr-content font, #wr-content cite, #wr-content small,
        #wr-content sup, #wr-content sub {
            -webkit-user-select: text !important;
            user-select: text !important;
            -webkit-touch-callout: default !important;
        }
        #wr-content img, #wr-content svg, #wr-content video, #wr-content button {
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

            // iOS 15 的 WKWebView 对 user-select 的继承很挑：只要祖先里有 none，
            // 长按就可能根本起不了选区。微信读书的正文层级不固定（p / div / 更深
            // 的嵌套都有），所以不靠一张静态选择器表，而是在手指按下时把命中的
            // 元素往上 4 层临时放开选择。这样任何结构都能选中，同时不放开 body，
            // 避免「一拖就整章全选」。
            function enableSelectionAt(target) {
                var el = target;
                var depth = 0;
                while (el && el !== document.body && depth < 4) {
                    try {
                        el.style.setProperty('-webkit-user-select', 'text', 'important');
                        el.style.setProperty('user-select', 'text', 'important');
                        el.style.setProperty('-webkit-touch-callout', 'default', 'important');
                    } catch (e) {}
                    el = el.parentElement;
                    depth += 1;
                }
            }
            ['touchstart', 'pointerdown', 'mousedown'].forEach(function (name) {
                document.addEventListener(name, function (event) {
                    if (event.target) { enableSelectionAt(event.target); }
                }, { passive: true, capture: true });
            });

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

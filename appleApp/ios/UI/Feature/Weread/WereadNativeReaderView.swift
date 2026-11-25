import SwiftUI
import WebKit
import UIKit
import os
import FlareAppleCore

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
    @Environment(\.scenePhase) private var scenePhase

    @State private var chapters: [WereadChapter] = []
    @State private var index = 0
    @State private var html = ""
    @State private var loading = true
    @State private var errorMessage: String?
    /// PDF 不能走原生 chapter 分片；置 true 后只显示跳转网页版的提示页。
    @State private var isPDF = false
    /// 沉浸阅读：点正文空白处切换，隐藏上下栏。
    @State private var immersive = false
    @State private var showChapters = false
    @State private var showWeb = false
    @State private var cache: [Int: String] = [:]
    /// 章节正文缓存的「最近使用顺序」，队尾最新。配合 `cacheCapacity` 做淘汰。
    /// 以前 cache 只增不减，读一本几百章的书会把整本 HTML 都攒在内存里，
    /// iPhone 6s 只有 2GB，翻到后面容易被系统杀掉。
    @State private var cacheOrder: [Int] = []
    @State private var highlights: [Int: [WereadHighlight]] = [:]
    /// 服务端同步的划线/想法，按 chapterUid 分组。和本地划线分开存，
    /// 避免用户新增一条本地划线时把服务端笔记一并写回 UserDefaults。
    @State private var serverNotes: [Int: [WereadBookmark]] = [:]
    @State private var notesToken = 0
    @State private var notesLoading = false
    @State private var notesError: String?
    @State private var showNotes = false
    @State private var scrollFraction: Double = 0
    /// 当前滚动位置对应的章内字符偏移（和微读 `chapterOffset` 同一口径）。
    /// 比比例更耐排版变化，上报和续读都用它。
    @State private var scrollOffset = 0
    /// 进章后要跳到的章内字符偏移。只在「打开这本书」时用一次，
    /// 翻章/重载都不该复用 —— 那些场景本来就要从头看。
    @State private var restoreOffset = 0
    /// 进章后要跳到的章内比例（0~1），文本长度量不出来时兜底。
    @State private var restoreFraction: Double = 0
    /// 当前章是否已经真正渲染出来。没渲染完就退出时不能把「0」当成
    /// 用户的阅读位置写回本地，否则会把上次读到的地方覆盖成章首。
    @State private var chapterReady = false
    /// 本章是否已经有可信位置（用户滚动过，或续读目标非 0）。
    /// 只有 true 才允许保存：打开书就退出时不能把章首 0 写成本机最新进度，
    /// 否则本机时间戳永远比官方新，下次就再也继承不到官方进度。
    @State private var hasReadingPosition = false
    /// 待执行的滚动请求。非 nil 时 `updateUIView` 会把它发给 JS，
    /// 发完立刻清空；用「值变化」驱动而不是闭包，避免 WebView 重建后请求丢失。
    @State private var scrollRequest: WereadScrollTarget?
    @State private var loadToken = 0
    /// 滚动时定期落本机的节流时间（秒）。
    @State private var lastCachedAt: TimeInterval = 0
    /// JS 点「想法」后发起的输入请求。走 SwiftUI 浮层而不是 `window.prompt`，
    /// 不依赖 WKUIDelegate 的 UIKit 弹窗回调链。
    @State private var noteRequest: WereadNoteRequest?
    @State private var noteDraft = ""
    /// 从笔记面板保存已有想法时置 true，避免重复提交。
    @State private var noteSaving = false
    /// 保存失败的提示。失败时编辑器不关闭，草稿还在。
    @State private var noteError: String?
    /// 服务端「我的想法」索引，用来把笔记面板里的一条对上 `reviewId`。
    @State private var ownReviews: [WereadOwnReview] = []
    /// `ownReviews` 是否至少成功拉过一次（空数组也是有效结果）。
    @State private var ownReviewsLoaded = false
    /// 点了笔记面板里的条目后先收起面板，等 `onDismiss` 再弹编辑器。
    @State private var pendingEdit: WereadHighlight?
    /// 回传给 JS 的想法内容；`text == nil` 表示取消。
    @State private var noteReply: WereadNoteReply?
    @State private var noteReplyToken = 0
    @FocusState private var noteDraftFocused: Bool

    /// 正文缓存最多留几章。一章 HTML 通常几十到几百 KB，留 3 章既能覆盖
    /// 「来回翻两页」，又不会在 2GB 设备上把内存顶满。
    private static let cacheCapacity = 3

    private var current: WereadChapter? {
        chapters.indices.contains(index) ? chapters[index] : nil
    }

    private var currentHighlights: [WereadHighlight] {
        guard let current else { return [] }
        var merged = highlights[current.uid] ?? []
        var indexByText: [String: Int] = [:]
        for (position, item) in merged.enumerated() {
            let key = normalizedText(item.text)
            if !key.isEmpty { indexByText[key] = position }
        }
        for bookmark in serverNotes[current.uid] ?? [] where !bookmark.markText.isEmpty {
            let key = normalizedText(bookmark.markText)
            if let position = indexByText[key] {
                let item = merged[position]
                if item.note.isEmpty, !bookmark.note.isEmpty {
                    merged[position] = WereadHighlight(
                        id: item.id,
                        text: item.text,
                        note: bookmark.note,
                        range: item.range ?? bookmark.range
                    )
                }
                continue
            }
            indexByText[key] = merged.count
            merged.append(
                WereadHighlight(
                    id: bookmark.id,
                    text: bookmark.markText,
                    note: bookmark.note,
                    range: bookmark.range
                )
            )
        }
        return merged
    }

    /// 本章能展示的笔记列表：本地 + 服务端，按 markText 去重。
    /// 同一条划线本地没写想法、服务端有，就补上服务端的想法。
    private var currentNoteEntries: [WereadHighlight] {
        guard let current else { return [] }
        var result = highlights[current.uid] ?? []
        var indexByText: [String: Int] = [:]
        for (position, item) in result.enumerated() {
            let key = normalizedText(item.text)
            if !key.isEmpty { indexByText[key] = position }
        }
        for bookmark in serverNotes[current.uid] ?? [] {
            let key = normalizedText(bookmark.markText)
            if !key.isEmpty, let position = indexByText[key] {
                if result[position].note.isEmpty, !bookmark.note.isEmpty {
                    let item = result[position]
                    result[position] = WereadHighlight(
                        id: item.id,
                        text: item.text,
                        note: bookmark.note,
                        range: item.range ?? bookmark.range
                    )
                }
                continue
            }
            guard !key.isEmpty || !bookmark.note.isEmpty else { continue }
            if !key.isEmpty { indexByText[key] = result.count }
            result.append(
                WereadHighlight(
                    id: bookmark.id,
                    text: bookmark.markText,
                    note: bookmark.note,
                    range: bookmark.range
                )
            )
        }
        return result
    }

    private func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // 章节 WebView 必须常驻：一旦从视图树里拿掉，WKWebView 就被销毁，
            // 再挂回来又要重新加载一次 HTML，白屏时间翻倍。
            if isPDF {
                // PDF 会自动进入官方阅读页（load() 里设 showWeb=true），这里只做
                // 全屏页弹出前的过渡；不再显示"点按钮跳转"的提示页。
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开《\(target.book.title)》…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
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
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !immersive { topBar }
        }
        .overlay {
            // 翻页按钮做成左下/右下两个玻璃小按钮，浮在正文上，不占整条底栏。
            // 全屏(immersive)时仍保留——用户要求上一章/下一章不能消失。
            if !isPDF {
                VStack {
                    Spacer()
                    HStack {
                        pageTurnButton(systemImage: "chevron.left", label: "上", enabled: index > 0) {
                            Task { await open(index - 1) }
                        }
                        .allowsHitTesting(true)
                        Spacer()
                        pageTurnButton(systemImage: "chevron.right", label: "下", enabled: index < chapters.count - 1) {
                            Task { await open(index + 1) }
                        }
                        .allowsHitTesting(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                // 容器整体不拦截点击，只让两个按钮可点——否则会挡住
                // 正文的"点中间进全屏"和划词选区。
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if let request = noteRequest {
                noteEditor(request)
            }
        }
        .statusBar(hidden: true)
        .task { await load() }
        .sheet(isPresented: $showChapters) {
            chapterList
        }
        .sheet(isPresented: $showNotes, onDismiss: {
            // 笔记面板里的条目在面板上层拿不到主视图的编辑浮层，先收面板再编辑。
            guard let entry = pendingEdit else { return }
            pendingEdit = nil
            beginEditing(entry)
        }) {
            notesSheet
                .task { await loadOwnReviews() }
        }
        .fullScreenCover(isPresented: $showWeb) {
            WereadReaderView(target: webReaderTarget)
        }
        .onDisappear { saveProgress() }
        // 切后台/被系统回收前再落一次；强杀无法拦截，滚动节流和续读
        // 目标落盘才是「读到一半被杀」的主要保障。
        .backportOnChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress() }
        }
    }

    /// PDF 直接给官方 `/web/reader/<hash>`，不再先落到网页书架自动点书。
    /// 非 PDF 保持原来的书架兜底，避免改掉已有的阅读器地址处理逻辑。
    private var webReaderTarget: WereadReaderTarget {
        if isPDF,
           let url = WereadService.shared.readerURLString(bookId: target.book.id)
        {
            return WereadReaderTarget(
                url: url,
                title: target.book.title,
                bookId: target.book.id,
                needsJump: false,
                isPDF: true
            )
        }
        return WereadReaderTarget(
            url: "https://weread.qq.com/web/shelf",
            title: target.book.title,
            bookId: target.book.id,
            needsJump: true
        )
    }

    // MARK: - 页面

    private var reader: some View {
        // 记住生成这个 reader 时的加载代次；`onReady` 是 escaping 闭包，
        // 会晚于翻章触发，代次不一致就说明是上一章的渲染完成。
        let token = loadToken
        let chapterUid = current?.uid ?? 0
        let reply = noteReply
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

                // 本地已经落盘，再尽力同步到微读服务端；失败只记诊断，不回滚本地。
                let bookId = target.book.id
                let cookie = store.cookie
                let chapterUid = chapter.uid
                let chapterIdx = chapter.index
                guard !cookie.isEmpty else {
                    let line =
                        "本地笔记已保存但未登录，未上传 book=\(bookId) " +
                        "chapter=\(chapterUid)"
                    WereadService.screenDiag(line)
                    FlareDiagnostics.shared.record(.weread, "ERR", line)
                    return
                }
                Task {
                    await WereadService.shared.uploadHighlight(
                        bookId: bookId,
                        chapterUid: chapterUid,
                        chapterIdx: chapterIdx,
                        range: item.range ?? "",
                        markText: item.text,
                        note: item.note,
                        cookie: cookie
                    )
                }
            },
            onScroll: { value, offset in
                // 旧页面的 pagehide / 迟到的滚动消息不能覆盖新章节的位置。
                guard token == self.loadToken else { return }
                let fraction = min(max(value, 0), 1)
                let position = max(offset, 0)
                scrollFraction = fraction
                scrollOffset = position
                chapterReady = true
                // 能收到滚动消息说明用户已经接管位置（恢复阶段 JS 不报）。
                hasReadingPosition = true
                // 滚动中每 2 秒落一次本机；正常退出仍由 saveProgress 兜底。
                let now = Date().timeIntervalSince1970
                if chapterUid > 0, now - lastCachedAt > 2 {
                    lastCachedAt = now
                    store.cacheProgress(
                        bookId: target.book.id,
                        chapterUid: chapterUid,
                        offset: position,
                        percent: Int(fraction * 100)
                    )
                }
            },
            onChapterLink: { href, text in
                // 章节 HTML 里的 partNNNN.html 相对链接在 loadHTMLString 的
                // 站点根基址下会变成 404。能对上目录就按目录跳章，对不上
                // 就弹目录让用户自己选，绝不让 WebView 去请求那个假地址。
                guard token == self.loadToken else { return }
                handleChapterLink(text, href: href)
            },
            onAnnotationLink: { href, text in
                // 正文里批注/想法/高亮的蓝色可点元素指向 /web/review/...
                // 或相对伪地址时也不该真的导航，统一落到本章笔记面板。
                guard token == self.loadToken else { return }
                handleAnnotationLink(text, href: href)
            },
            onToggleFullscreen: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    immersive.toggle()
                }
            },
            noteReply: reply,
            onNoteRequest: { text in
                // 浮层已经开着时忽略重复请求，避免 JS 的待处理选区被覆盖。
                guard noteRequest == nil, !text.isEmpty else { return }
                noteDraft = ""
                noteSaving = false
                noteError = nil
                noteRequest = WereadNoteRequest(text: text)
            },
            onNoteReplyApplied: {
                if noteReply != nil { noteReply = nil }
            },
            scrollRequest: scrollRequest,
            onScrollApplied: {
                // 请求已经交给 WebView，清掉，避免下次 updateUIView 重复滚。
                guard token == self.loadToken else { return }
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
                Text(isPDF ? "PDF · 网页版阅读" : (current?.title ?? "正在打开…"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isPDF {
                Button {
                    showWeb = true
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("网页版阅读器")
            } else {
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
                    Button {
                        showNotes = true
                    } label: {
                        Label("本章笔记（\(currentNoteEntries.count)）", systemImage: "text.quote")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    /// 左下/右下角的玻璃质感翻页小按钮：只放一个字，不占整条底栏，
    /// 全屏时也保留（上一章/下一章不能消失）。
    private func pageTurnButton(
        systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 40, height: 40)
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 0.5)
                    .frame(width: 40, height: 40)
                Text(label)
                    .font(.system(size: 17, weight: .semibold))
            }
            .opacity(enabled ? 0.85 : 0.3)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(systemImage == "chevron.left" ? "上一章" : "下一章")
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
                WereadService.resetScreenDiag()
                Task { await load(force: true) }
            }
            .buttonStyle(.borderedProminent)
            Button("用网页版打开") {
                showWeb = true
            }
            .font(.footnote)

            // 屏幕诊断：Windows 读不到 App 的 os_log，把关键请求结果直接显示出来，
            // 用户截图即可定位。只含状态码/字节数/返回体开头，不含 cookie。
            let diag = WereadService.takeScreenDiag()
            if !diag.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断（请截图给开发者）").font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        Text(diag)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    Button("复制诊断") {
                        UIPasteboard.general.string = diag
                    }
                    .font(.caption2)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
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

    private var notesSheet: some View {
        NavigationView {
            Group {
                if notesLoading, currentNoteEntries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在同步微读笔记…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let notesError, currentNoteEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("笔记加载失败")
                            .font(.footnote)
                        Text(notesError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("重试") { retryBookmarks() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if currentNoteEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("本章还没有同步的笔记")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("在微读官方 App 或网页里做的划线和想法，会同步到这里")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(currentNoteEntries) { item in
                                Button {
                                    // 面板还开着时主视图的编辑浮层会被盖住，先收起面板。
                                    pendingEdit = item
                                    showNotes = false
                                } label: {
                                    noteRow(item)
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("点任意一条可以改想法，保存后会同步到微信读书")
                                .font(.caption2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(current?.title.isEmpty == false ? "本章笔记" : "笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showNotes = false }
                }
            }
        }
    }

    /// 笔记面板里的一行。整行可点，所以不再开 `textSelection` ——
    /// 文本选择会吞掉点击，用户会以为「点不进去」。
    private func noteRow(_ item: WereadHighlight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.system(size: 15))
                        .multilineTextAlignment(.leading)
                }
                if !item.note.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    Text("点一下写想法")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - 写想法

    /// 原生输入浮层：JS 只负责上报「用户点了想法 + 选中的文字」，
    /// 输入和回传都在 SwiftUI 里完成，不再走 `window.prompt`。
    private func noteEditor(_ request: WereadNoteRequest) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { cancelNote() }
            VStack(alignment: .leading, spacing: 12) {
                Text(request.isEditing ? "编辑想法" : "写想法")
                    .font(.headline)
                if !request.text.isEmpty {
                    Text(request.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                TextEditor(text: $noteDraft)
                    .font(.system(size: 15))
                    .frame(height: 110)
                    .padding(6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .focused($noteDraftFocused)
                if let noteError {
                    Text(noteError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("取消") { cancelNote() }
                        .disabled(noteSaving)
                    Spacer(minLength: 12)
                    Button(noteSaving ? "保存中…" : "保存") { saveNote() }
                        .disabled(
                            noteSaving
                                || noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
                .font(.system(size: 15, weight: .medium))
            }
            .padding(18)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.18), radius: 18)
            .padding(.horizontal, 24)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                noteDraftFocused = true
            }
        }
    }

    private func saveNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let request = noteRequest else { return }
        guard let entry = request.entry else {
            // JS 选文新建：保持原来的回传链路，本地落盘和上传仍由 onHighlight 完成。
            noteReplyToken += 1
            noteReply = WereadNoteReply(id: noteReplyToken, text: text)
            noteRequest = nil
            noteDraft = ""
            noteDraftFocused = false
            return
        }
        guard !noteSaving else { return }
        noteSaving = true
        noteError = nil
        let chapterUid = current?.uid ?? 0
        let chapterIdx = current?.index ?? 0
        Task {
            await performSave(
                text: text,
                entry: entry,
                reviewId: request.reviewId,
                chapterUid: chapterUid,
                chapterIdx: chapterIdx
            )
        }
    }

    private func cancelNote() {
        guard noteRequest != nil, !noteSaving else { return }
        noteReplyToken += 1
        noteReply = WereadNoteReply(id: noteReplyToken, text: nil)
        noteRequest = nil
        noteDraft = ""
        noteError = nil
        noteDraftFocused = false
    }

    /// 从笔记面板点一条笔记进入编辑。
    ///
    /// 打开面板时会先拉一次「我的想法」；没拉到才在这里补拉，避免用户
    /// 点得太快时把「编辑」误判成「新建」。
    private func beginEditing(_ entry: WereadHighlight) {
        guard current != nil else { return }
        noteError = nil
        noteSaving = false
        if ownReviewsLoaded || store.cookie.isEmpty {
            presentEditor(for: entry)
            return
        }
        Task { await prepareEditor(for: entry) }
    }

    @MainActor
    private func prepareEditor(for entry: WereadHighlight) async {
        await loadOwnReviews()
        presentEditor(for: entry)
    }

    private func presentEditor(for entry: WereadHighlight) {
        let matched = matchedReview(for: entry)
        noteDraft = matched?.content ?? entry.note
        noteRequest = WereadNoteRequest(
            text: entry.text,
            entry: entry,
            reviewId: matched?.reviewId,
            isEditing: matched != nil || !entry.note.isEmpty
        )
    }

    /// 把一条笔记对上服务端 review：章内 range 优先，原文兜底。
    private func matchedReview(for entry: WereadHighlight) -> WereadOwnReview? {
        guard let chapter = current else { return nil }
        let text = normalizedText(entry.text)
        let candidates = ownReviews.filter { $0.chapterUid == chapter.uid }
        if let range = entry.range, !range.isEmpty {
            if let exact = candidates.first(where: {
                $0.range == range && normalizedText($0.abstract) == text
            }) {
                return exact
            }
            if let byRange = candidates.first(where: { $0.range == range }) {
                return byRange
            }
        }
        guard !text.isEmpty else {
            // 整章想法没有划线原文，按想法正文兜底。
            let note = normalizedText(entry.note)
            guard !note.isEmpty else { return nil }
            return candidates.first(where: { normalizedText($0.content) == note })
        }
        return candidates.first(where: { normalizedText($0.abstract) == text })
    }

    /// 打开笔记面板时顺手拉一次「我的想法」，只用于定位 reviewId。
    /// 失败时保持 `ownReviewsLoaded == false`，下次点条目会再试。
    @MainActor
    private func loadOwnReviews() async {
        guard !store.cookie.isEmpty else {
            ownReviews = []
            ownReviewsLoaded = true
            return
        }
        let reviews = await WereadService.shared.ownReviews(
            bookId: target.book.id,
            cookie: store.cookie
        )
        ownReviews = reviews ?? []
        ownReviewsLoaded = reviews != nil
    }

    /// 笔记面板里的保存：有 reviewId 就改那条想法；没有就按原有
    /// `addReview` 路径补一条（例如只是划线、或本地想法还没上传成功）。
    @MainActor
    private func performSave(
        text: String,
        entry: WereadHighlight,
        reviewId: String?,
        chapterUid: Int,
        chapterIdx: Int
    ) async {
        let service = WereadService.shared
        let cookie = store.cookie
        // 云端索引没拉到、或这条笔记本来就是服务端下发的，却仍没定位到
        // `reviewId` 时，不要降级成新建 —— 硬建会多出一条重复笔记。
        // 只有确实只存在于本机、还没上传过的想法才继续走新建。
        if reviewId == nil,
           !entry.note.isEmpty,
           (!ownReviewsLoaded || hasServerNote(entry, chapterUid: chapterUid)) {
            noteSaving = false
            noteError = "没能从云端定位到这条想法，先不新建以免重复，请稍后重试"
            return
        }
        let ok: Bool
        if let reviewId, !reviewId.isEmpty {
            ok = await service.editReview(
                reviewId: reviewId,
                content: text,
                cookie: cookie
            )
        } else {
            ok = await service.uploadHighlight(
                bookId: target.book.id,
                chapterUid: chapterUid,
                chapterIdx: chapterIdx,
                range: entry.range ?? "",
                markText: entry.text,
                note: text,
                cookie: cookie
            )
        }
        noteSaving = false
        guard ok else {
            noteError = "同步到微信读书失败，内容还在输入框里，可以稍后重试"
            return
        }
        applyNote(text, to: entry, chapterUid: chapterUid)
        noteRequest = nil
        noteDraft = ""
        noteError = nil
        noteDraftFocused = false
        // 服务端条目的显示以 bookmarklist 为准，重新拉一次刷新列表。
        retryBookmarks()
        Task { await loadOwnReviews() }
    }

    /// 这条内容是否已由 `bookmarklist` 下发（说明云端已有想法）。
    private func hasServerNote(_ entry: WereadHighlight, chapterUid: Int) -> Bool {
        let text = normalizedText(entry.text)
        let note = normalizedText(entry.note)
        guard !text.isEmpty || !note.isEmpty else { return false }
        return (serverNotes[chapterUid] ?? []).contains {
            if !text.isEmpty {
                return normalizedText($0.markText) == text && !$0.note.isEmpty
            }
            // 整章想法没有划线原文，用想法正文判断是否来自服务端。
            return normalizedText($0.note) == note
        }
    }

    /// 编辑成功后把内容写回本地划线（如果这条笔记在本机也有一份）。
    /// 纯服务端条目不在本地伪造，交给 `retryBookmarks()` 刷新。
    private func applyNote(_ note: String, to entry: WereadHighlight, chapterUid: Int) {
        guard chapterUid > 0 else { return }
        var list = highlights[chapterUid] ?? []
        let text = normalizedText(entry.text)
        guard let position = list.firstIndex(where: { item in
            item.id == entry.id || (!text.isEmpty && normalizedText(item.text) == text)
        }) else {
            return
        }
        let item = list[position]
        list[position] = WereadHighlight(
            id: item.id,
            text: item.text,
            note: note,
            range: item.range ?? entry.range
        )
        highlights[chapterUid] = list
        WereadHighlightStore.save(list, bookId: target.book.id, chapterUid: chapterUid)
    }

    // MARK: - 加载

    @MainActor
    private func load(force: Bool = false) async {
        if !force, !chapters.isEmpty { return }
        let service = WereadService.shared
        if service.isPDFBook(id: target.book.id) {
            loadToken += 1
            notesToken += 1
            chapters = []
            html = ""
            cache = [:]
            cacheOrder = []
            highlights = [:]
            serverNotes = [:]
            ownReviews = []
            ownReviewsLoaded = false
            isPDF = true
            loading = false
            errorMessage = nil
            // PDF 直接用微读官方阅读页打开：那个页面原生支持高亮 / 写想法 /
            // 服务端笔记（用户真机已确认能正常读）。不再显示中间提示页拦一道。
            showWeb = true
            return
        }
        isPDF = false
        WereadService.resetScreenDiag()
        loadToken += 1
        let token = loadToken
        notesToken += 1
        let bookmarkToken = notesToken
        if force {
            serverNotes = [:]
            ownReviews = []
            ownReviewsLoaded = false
        }
        notesError = nil
        loading = true
        errorMessage = nil
        html = ""
        do {
            // 目录和阅读进度互不依赖，并行发出去，少等一个来回。
            // 三个请求都走 Store 的会话恢复，过期的 cookie 会先续期再重试。
            let bookId = target.book.id
            Task { await loadBookmarks(bookId: bookId, token: bookmarkToken) }
            async let progressTask = store.progress(for: bookId)
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
            // 续读位置：章由 chapterUid 定位，章内位置优先用字符偏移。
            // 以前只把 offset 换成比例、比例又依赖 wordCount，wordCount 为 0
            // 时会直接算成 1.0 跳到章尾；这里把 offset 原样交给 WebView，
            // 由 JS 按正文文本长度定位，比例只做兜底（见 restoreOffset）。
            var resumeOffset = 0
            var resumeFraction: Double = 0
            if let progress = await progressTask {
                let position = list.firstIndex { $0.uid == progress.chapterUid }
                if let position {
                    start = position
                    if progress.chapterOffset > 0 {
                        resumeOffset = progress.chapterOffset
                        let words = list[position].wordCount
                        // offset 超过章节字数时 ratio 会被截成 1；一旦 DOM
                        // 定位失败就会直接跳到章尾。宁可不用这个比例，
                        // 改用服务端给的章内百分比。
                        if words > 0, progress.chapterOffset <= words {
                            resumeFraction = min(
                                max(Double(progress.chapterOffset) / Double(words), 0),
                                1
                            )
                        } else if progress.percent > 0 {
                            resumeFraction = min(max(Double(progress.percent) / 100, 0), 1)
                        }
                    } else if progress.percent > 0 {
                        resumeFraction = min(max(Double(progress.percent) / 100, 0), 1)
                    }
                }
            }
            index = start
            restoreOffset = resumeOffset
            restoreFraction = resumeFraction
            scrollOffset = resumeOffset
            scrollFraction = resumeFraction
            await loadChapter(at: start, token: token)
        } catch {
            guard token == loadToken else { return }
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    /// 服务端笔记单独拉：慢或失败都不能挡住正文。
    @MainActor
    private func loadBookmarks(bookId: String, token: Int) async {
        guard token == notesToken else { return }
        notesLoading = true
        do {
            // 走 Store 的会话恢复：过期 cookie 时先续期，避免 bookmarklist
            // 静默返回 `{}` 被当成「云端没有笔记」。
            let list = try await store.bookmarks(for: bookId)
            guard token == notesToken else { return }
            serverNotes = Dictionary(grouping: list) { $0.chapterUid }
            notesError = nil
            notesLoading = false
        } catch {
            guard token == notesToken else { return }
            notesLoading = false
            notesError = error.localizedDescription
        }
    }

    @MainActor
    private func retryBookmarks() {
        notesToken += 1
        let token = notesToken
        notesError = nil
        Task {
            await loadBookmarks(
                bookId: target.book.id,
                token: token
            )
        }
    }

    @MainActor
    private func reloadChapter() async {
        guard let current else { return }
        // 清缓存要连 LRU 队列一起清，否则队列里留着一个永远不存在的条目。
        cache[current.uid] = nil
        cacheOrder.removeAll { $0 == current.uid }
        // 重新加载本章是用户主动动作，从章首开始，不要复用续读位置。
        restoreOffset = 0
        restoreFraction = 0
        loadToken += 1
        await loadChapter(at: index, token: loadToken)
    }

    @MainActor
    private func open(_ position: Int) async {
        guard chapters.indices.contains(position) else { return }
        guard position != index else { return }
        saveProgress()
        // 手动翻章从章首开始，不能把「打开这本书」的续读位置带过去。
        restoreOffset = 0
        restoreFraction = 0
        loadToken += 1
        await loadChapter(at: position, token: loadToken)
    }

    /// 把章节正文里的相对链接对回目录。
    ///
    /// epub/azw3 的目录页链接形如 `part0012.html#chapter_3`，文件名是打包
    /// 时的 spine 序号，和 `chapterIdx` 不一定同序，按数字猜会跳错章。
    /// 所以只认链接文字：上一章 / 下一章 / 章节标题（精确 → 唯一包含）。
    /// 对不上返回 nil，由调用方弹目录兜底，绝不把用户送到 404。
    private func chapterPosition(forLinkText text: String) -> Int? {
        let label = chapterTitleKey(text)
        if label.contains("上一章") {
            return index > 0 ? index - 1 : nil
        }
        if label.contains("下一章") {
            return index + 1 < chapters.count ? index + 1 : nil
        }
        if label.contains("目录") { return nil }

        if !label.isEmpty {
            if let exact = chapters.firstIndex(where: { chapterTitleKey($0.title) == label }) {
                return exact
            }
            let partial = chapters.indices.filter { position in
                let title = chapterTitleKey(chapters[position].title)
                return !title.isEmpty && (title.contains(label) || label.contains(title))
            }
            // 只认唯一命中：「第一章」这类短标题容易同时包含在多章里。
            if partial.count == 1 { return partial[0] }
        }
        return nil
    }

    /// 相对章节链接的落点：能对上目录就跳章，对不上就弹目录兜底。
    /// 宁可多弹一次目录，也不要让链接静默失效或落进 404。
    private func handleChapterLink(_ text: String, href: String = "") {
        let link = href.isEmpty ? "-" : String(href.prefix(120))
        if let position = chapterPosition(forLinkText: text) {
            WereadService.screenDiag("目录链接→第\(position + 1)章 \(link)")
            Task { await open(position) }
            return
        }
        WereadService.screenDiag("目录链接未匹配，打开目录 \(link)")
        showChapters = true
    }

    /// 正文里批注/想法/高亮的蓝色可点元素：不请求它指向的地址，
    /// 打开本章笔记面板。能按文字对上一条笔记时只记诊断，面板里可直接看。
    private func handleAnnotationLink(_ text: String, href: String = "") {
        let link = href.isEmpty ? "-" : String(href.prefix(120))
        let key = normalizedText(text)
        let matched = !key.isEmpty && currentNoteEntries.contains {
            normalizedText($0.text) == key
        }
        WereadService.screenDiag(
            "批注蓝条→笔记面板 matched=\(matched ? 1 : 0) \(link)"
        )
        showNotes = true
    }

    private func chapterTitleKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[、。，：；·,.:;\"'“”‘’《》()（）\\[\\]]", with: "", options: .regularExpression)
            .lowercased()
    }

    @MainActor
    private func loadChapter(at position: Int, token: Int) async {
        guard chapters.indices.contains(position) else { return }
        index = position
        scrollFraction = 0
        scrollOffset = 0
        chapterReady = false
        hasReadingPosition = false
        lastCachedAt = 0
        // 上一章还没执行完的续读滚动不能落到新章上。
        scrollRequest = nil
        loading = true
        errorMessage = nil
        // 换章时上一章的待处理想法必须丢掉，否则会包到新章的文本上。
        noteRequest = nil
        noteReply = nil
        noteDraft = ""
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
            if token == loadToken { chapterReady = true }
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
            if token == loadToken { chapterReady = true }
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
        let offset = restoreOffset
        let fraction = restoreFraction
        guard token == loadToken else { return }
        restoreOffset = 0
        restoreFraction = 0
        guard offset > 0 || fraction > 0.001 else { return }
        hasReadingPosition = true
        // 先把「目标位置」记成本地状态：即使滚动因图片未加载完失败，
        // 退出时也不会把刚恢复到的位置又覆盖成 0。
        scrollOffset = offset
        scrollFraction = fraction
        // 续读目标本身也要立刻落本机：用户恢复后不再滚动就强杀时，
        // 之前只有 onScroll/onDisappear 会写，目标位置会丢。
        if let chapter = current, chapter.uid > 0 {
            store.cacheProgress(
                bookId: target.book.id,
                chapterUid: chapter.uid,
                offset: offset,
                percent: Int((fraction * 100).rounded())
            )
        }
        WereadService.screenDiag(
            "进度恢复 book=\(target.book.id) chapter=\(current?.uid ?? 0) offset=\(offset) fraction=\(Int((fraction * 100).rounded()))%"
        )
        scrollRequest = WereadScrollTarget(offset: offset, fraction: fraction)
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
        guard chapterReady, hasReadingPosition, let current else { return }
        var offset = scrollOffset
        if offset <= 0, scrollFraction > 0.001 {
            offset = Int(Double(max(current.wordCount, 1)) * scrollFraction)
        }
        WereadService.screenDiag(
            "进度保存 book=\(target.book.id) chapter=\(current.uid) offset=\(max(offset, 0)) percent=\(Int((scrollFraction * 100).rounded()))"
        )
        store.report(
            bookId: target.book.id,
            chapterUid: current.uid,
            offset: max(offset, 0),
            chapterIndex: current.index,
            percent: Int((scrollFraction * 100).rounded())
        )
    }
}

// MARK: - 划线 / 想法

struct WereadHighlight: Codable, Hashable, Identifiable {
    let id: String
    let text: String
    let note: String
    /// 章内文本偏移 `start-end`，用于回传服务端划线 / 想法。
    /// 官方按自己的渲染对象算 offset，这里用 DOM 文本长度近似，位置可能有偏差，
    /// 需真机校准。旧版本 UserDefaults 里没有这个字段，Optional 解码会得到 nil。
    let range: String?

    init(id: String, text: String, note: String, range: String? = nil) {
        self.id = id
        self.text = text
        self.note = note
        self.range = range
    }
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

/// 一次「写想法 / 编辑想法」请求。
///
/// JS 新建时只带选中的文字（原始 Range 留在 JS 侧）；从笔记面板点进来时
/// 还带原条目和匹配到的服务端 `reviewId`。
private struct WereadNoteRequest: Identifiable {
    let id = UUID()
    let text: String
    var entry: WereadHighlight? = nil
    var reviewId: String? = nil
    /// 编辑已有想法；否则是给划线补想法（或新建）。
    var isEditing: Bool = false
}

/// 一次续读滚动请求：优先按章内字符偏移定位，比例只在量不出文本长度时兜底。
private struct WereadScrollTarget: Equatable {
    let offset: Int
    let fraction: Double
}

/// SwiftUI 回传给 JS 的结果；`text == nil` 表示取消。
private struct WereadNoteReply: Equatable {
    let id: Int
    let text: String?
}

// MARK: - 章节 WebView

private struct WereadChapterWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    let cookie: String
    let highlights: [WereadHighlight]
    let onHighlight: (WereadHighlight) -> Void
    let onScroll: (Double, Int) -> Void
    /// 章节内相对链接（epub/azw3 的 partNNNN.html#...）被点击。
    /// 参数是原始 href 和链接文字，由 Swift 侧对回目录再跳章。
    let onChapterLink: (String, String) -> Void
    /// 正文里批注/想法/高亮的蓝色可点元素被点击。
    /// 参数是原始 href 和元素文字，由 Swift 侧打开本章笔记面板。
    let onAnnotationLink: (String, String) -> Void
    /// 点正文空白处：切换沉浸阅读（隐藏/显示上下栏）。
    let onToggleFullscreen: () -> Void
    let noteReply: WereadNoteReply?
    let onNoteRequest: (String) -> Void
    let onNoteReplyApplied: () -> Void
    /// 待执行的续读位置。非 nil 时在页面 ready 之后滚过去。
    let scrollRequest: WereadScrollTarget?
    /// 滚动请求已经处理（无论成功失败都要回调，否则会一直重试）。
    let onScrollApplied: () -> Void
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 和网页版阅读器保持一致：按字符选中，并显式打开文本交互。
        // 默认的 dynamic 粒度会把整段/整页当成一个可选块，正文里的
        // 内联 user-select 锁又会让长按根本起不了选区。
        configuration.selectionGranularity = .character
        configuration.preferences.isTextInteractionEnabled = true
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
        context.coordinator.applyNoteReply(noteReply, in: webView)
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
        private var lastNoteReplyID: Int?
        private var loaded = false
        /// 页面还没 ready 时收到的滚动请求，等 `markReady` 再补执行。
        private var pendingScroll: WereadScrollTarget?
        /// 页面高度还没撑开时的重试次数。
        private var scrollRetries = 0

        init(_ parent: WereadChapterWebView) {
            self.parent = parent
        }

        func load(_ html: String, in webView: WKWebView, baseURL: URL?, cookie: String) {
            guard !html.isEmpty, html != lastHTML else { return }
            lastHTML = html
            lastHighlights = ""
            loaded = false
            pendingScroll = nil
            scrollRetries = 0
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

        /// 在页面 ready 之后把 WebView 滚到指定位置。
        ///
        /// 只在 `loaded == true` 时执行：排版前 `scrollTo` 会落到 0（页面高度还是 0），
        /// 那就是「每次都回到章首」的老毛病。还没 ready 就先记着，等 `markReady` 再补。
        func requestScroll(_ target: WereadScrollTarget?, in webView: WKWebView) {
            guard let target = target else { return }
            guard loaded else {
                pendingScroll = target
                return
            }
            scrollRetries = 0
            performScroll(target, in: webView)
        }

        private func performScroll(_ target: WereadScrollTarget, in webView: WKWebView) {
            pendingScroll = target
            let script = """
            window.__wrRestoreProgress(\(target.offset), \(target.fraction));
            """
            webView.evaluateJavaScript(script) { value, error in
                if let error = error {
                    Self.log.error(
                        "weread restore scroll failed: \(String(describing: error), privacy: .public)"
                    )
                    // 页面脚本还没装好时 evaluate 会报 undefined；和
                    // 「页面还不可滚动」一样重试，不能第一次失败就放弃。
                    self.retryScroll(in: webView)
                    return
                }
                if (value as? Bool) == true {
                    self.pendingScroll = nil
                    self.scrollRetries = 0
                    DispatchQueue.main.async { self.parent.onScrollApplied() }
                    return
                }
                // 图片还没加载完时页面可能量不出可滚动高度。隔一会儿再试，
                // 不要一次失败就放弃 —— 那就是「回到章首」的直接原因。
                self.retryScroll(in: webView)
            }
        }

        private func retryScroll(in webView: WKWebView) {
            if scrollRetries >= 8 {
                Self.log.debug("weread restore scroll gave up before page was scrollable")
                pendingScroll = nil
                scrollRetries = 0
                DispatchQueue.main.async { self.parent.onScrollApplied() }
                return
            }
            scrollRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let pending = self.pendingScroll else { return }
                self.performScroll(pending, in: webView)
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

        /// 兜底：JS 拦不到的章节链接（onclick / JS 改 location、target=_blank、
        /// 多指点击等）也不要真的去请求 `partNNNN.html` —— 服务端没有这个
        /// 文件，只会把 WebView 带到 404 页。
        ///
        /// 这里不能要求 `navigationType == .linkActivated`：JS 路由式跳转在
        /// WKWebView 里的类型是 `.other`，按类型过滤就会把 404 放过去。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // 只处理主框架；章节页里的子框架导航与跳章无关。
            if let frame = navigationAction.targetFrame, !frame.isMainFrame {
                decisionHandler(.allow)
                return
            }
            let path = url.path.lowercased()
            let isChapterFile = path.hasSuffix(".html")
                || path.hasSuffix(".htm")
                || path.hasSuffix(".xhtml")
            let isWeread = url.host == "weread.qq.com"
            // 批注/想法详情页（`/web/review/...`）在静态章节页的会话里
            // 同样会落到 404，属于本批要拦的「批注蓝条」，不是章文件。
            // 放在章节判断之前：批注链接也可能带 `.html` 后缀。
            let isAnnotationPath = path.hasPrefix("/web/review")
                || path.contains("/review/detail/")
            if isWeread, isAnnotationPath {
                decisionHandler(.cancel)
                let href = url.absoluteString
                WereadService.screenDiag(
                    "已拦截批注伪链接 path=\(String(url.path.prefix(120)))"
                )
                DispatchQueue.main.async {
                    self.parent.onAnnotationLink(href, "")
                }
                return
            }
            if isWeread, isChapterFile {
                decisionHandler(.cancel)
                let href = url.absoluteString
                WereadService.screenDiag(
                    "已拦截章节伪链接 path=\(String(url.path.prefix(120)))"
                )
                DispatchQueue.main.async {
                    self.parent.onChapterLink(href, "")
                }
                return
            }
            decisionHandler(.allow)
        }

        /// 页面可交互了：恢复本地划线，并通知 SwiftUI 收起加载层。
        private func markReady(in webView: WKWebView?) {
            loaded = true
            lastHighlights = ""
            if let webView = webView {
                apply(parent.highlights, in: webView)
                // 排版完成后再补执行挂起的续读滚动。
                if let pending = pendingScroll {
                    scrollRetries = 0
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
                let rawRange = (body["range"] as? String) ?? ""
                let range = rawRange.isEmpty ? nil : rawRange
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    self.parent.onHighlight(
                        WereadHighlight(id: id, text: text, note: note, range: range)
                    )
                }
            case "noteRequest":
                let text = (body["text"] as? String) ?? ""
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    self.parent.onNoteRequest(text)
                }
            case "scroll":
                let value = (body["value"] as? NSNumber)?.doubleValue ?? 0
                let offset = (body["offset"] as? NSNumber)?.intValue ?? 0
                DispatchQueue.main.async {
                    self.parent.onScroll(value, offset)
                }
            case "chapterLink":
                let href = (body["href"] as? String) ?? ""
                let text = (body["text"] as? String) ?? ""
                DispatchQueue.main.async {
                    self.parent.onChapterLink(href, text)
                }
            case "annotationLink":
                let href = (body["href"] as? String) ?? ""
                let text = (body["text"] as? String) ?? ""
                DispatchQueue.main.async {
                    self.parent.onAnnotationLink(href, text)
                }
            case "toggleFullscreen":
                DispatchQueue.main.async {
                    self.parent.onToggleFullscreen()
                }
            default:
                break
            }
        }

        /// 把 SwiftUI 浮层里的想法（或取消）回传给 JS。
        ///
        /// 用「值 + token」而不是闭包，和 `scrollRequest` 一样能扛住
        /// WKWebView 重建；每条结果只应用一次。
        func applyNoteReply(_ reply: WereadNoteReply?, in webView: WKWebView) {
            guard let reply = reply, reply.id != lastNoteReplyID else { return }
            lastNoteReplyID = reply.id
            let script: String
            if let text = reply.text {
                let payload = ["note": text]
                guard
                    let data = try? JSONSerialization.data(withJSONObject: payload),
                    let json = String(data: data, encoding: .utf8)
                else {
                    DispatchQueue.main.async { self.parent.onNoteReplyApplied() }
                    return
                }
                script = "window.__wrApplyNote(\(Self.javaScriptStringLiteral(json)).note);"
            } else {
                script = "window.__wrApplyNote(null);"
            }
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    Self.log.error(
                        "weread apply note failed: \(String(describing: error), privacy: .public)"
                    )
                }
                DispatchQueue.main.async { self.parent.onNoteReplyApplied() }
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
            // 找不到 presenter 时必须回调，否则 `window.prompt` 永远不返回，
            // 整个页面的 JS 会卡住。原生输入浮层已不走这里，这里只做兜底。
            guard let presenter = topViewController() else {
                Self.log.error("weread prompt has no presenter")
                completionHandler(nil)
                return
            }
            presenter.present(alert, animated: true) {
                alert.textFields?.first?.becomeFirstResponder()
            }
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
            /* 左右留白尽量小，把屏宽让给正文；底部留出翻页栏的空间。 */
            padding: 8px 8px 48px;
            background: transparent;
            color: #1c1c1e;
            font: 17px/1.85 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif;
            -webkit-text-size-adjust: 100%;
            word-wrap: break-word;
            overflow-wrap: break-word;
            -webkit-user-select: text;
            user-select: text;
            -webkit-touch-callout: default;
        }
        /* 正文所有节点都放开选择。WeRead 章节 HTML 自带内联
           `-webkit-user-select:none`（有时还带 !important），只给 p/span
           列白名单盖不住更深层的 div，所以这里用 ID 选择器覆盖整棵正文树；
           内联锁由下面的 JS 在页面加载后直接 removeProperty 清掉。 */
        #wr-content,
        #wr-content * {
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

            // epub/azw3 的章内链接是 `part0012.html#chapter_3` 这种相对地址。
            // 页面是 loadHTMLString 生成的，基址是站点根，直接放行会请求
            // 一个不存在的 partNNNN.html（404）。这里拦下来交给 Swift 按目录跳章。
            //
            // 蓝色可点文字不一定写成 `<a href>`：打包后的页面里还有
            // `data-href` / `data-url` / `onclick="location='part0003.html'"`。
            // 只认 `<a href>` 会漏拦，所以两类都抽。
            var CHAPTER_ATTRS = [
                'href', 'data-href', 'data-url', 'data-src',
                'data-target', 'data-link', 'data-chapter', 'data-chapter-url'
            ];

            function chapterHrefFrom(raw) {
                if (!raw) return '';
                var value = String(raw).trim();
                if (!value) return '';
                var lower = value.toLowerCase();
                if (lower.charAt(0) === '#') return '';
                if (lower.indexOf('javascript:') === 0) return '';
                if (lower.indexOf('mailto:') === 0 || lower.indexOf('tel:') === 0) return '';
                if (lower.indexOf('data:') === 0) return '';
                // 外链、协议相对地址放行；微读本站的绝对地址还原成相对路径。
                if (lower.indexOf('//') === 0) return '';
                if (lower.indexOf('http://') === 0 || lower.indexOf('https://') === 0) {
                    if (lower.indexOf('https://weread.qq.com/') !== 0
                        && lower.indexOf('http://weread.qq.com/') !== 0) return '';
                    value = value.replace(/^https?:\\/\\/weread\\.qq\\.com/i, '');
                    if (value.charAt(0) !== '/') return '';
                    value = value.slice(1);
                    lower = value.toLowerCase();
                }
                // 站点绝对路径（/web/...）不拦，那是微读自己的页面。
                if (value.charAt(0) === '/') return '';
                var file = lower.split('#')[0].split('?')[0];
                if (!file) return '';
                return /\\.(html?|xhtml)$/.test(file) ? value : '';
            }

            // 从 onclick / javascript: 里抠章文件名，例如
            // `javascript:location='part0003.html#c1'`。
            function chapterFileIn(text) {
                if (!text) return '';
                var pattern = /(?:\\.{0,2}\\/)?[A-Za-z0-9_\\-.\\/%]+\\.(?:html?|xhtml)(?:\\?[^'"\\s)]*)?(?:#[^'"\\s)]*)?/ig;
                var match;
                while ((match = pattern.exec(String(text))) !== null) {
                    var candidate = chapterHrefFrom(match[0]);
                    if (candidate) return candidate;
                }
                return '';
            }

            function chapterHref(node) {
                if (!node || node.nodeType !== 1) return '';
                for (var i = 0; i < CHAPTER_ATTRS.length; i++) {
                    var candidate = chapterHrefFrom(node.getAttribute(CHAPTER_ATTRS[i]));
                    if (candidate) return candidate;
                }
                return chapterFileIn(
                    node.getAttribute('onclick') || node.getAttribute('href') || ''
                );
            }

            function chapterLinkTarget(start) {
                var node = start;
                var depth = 0;
                while (node && node !== document && depth < 8) {
                    if (node.nodeType === 1) {
                        var href = chapterHref(node);
                        if (href) return { node: node, href: href };
                    }
                    node = node.parentElement;
                    depth += 1;
                }
                return null;
            }

            // 正文里的「批注蓝条」不止 <a href>：服务端章节 HTML 还会用
            // data-review-id / data-note-id / .wr_highlight_char 标出想法
            // 或高亮，官方阅读器的点按逻辑会跳到 `/web/review/...`。
            // 静态章节页没有那套路由，点了就 404；这里统一拦下来交给 Swift
            // 打开本章笔记面板。脚注（data-wr-footernote）是原地气泡，不拦。
            var NOTE_ATTRS = [
                'data-review-id', 'data-reviewid',
                'data-note-id', 'data-noteid',
                'data-bookmark-id', 'data-bookmarkid'
            ];

            function annotationHint(value) {
                if (!value) return '';
                var lower = String(value).toLowerCase();
                if (lower.indexOf('/web/review') >= 0) return 'review';
                if (lower.indexOf('reviewid') >= 0) return 'review';
                if (lower.indexOf('gotoreview') >= 0) return 'review';
                if (lower.indexOf('bookmarkid') >= 0) return 'bookmark';
                if (lower.indexOf('shownote') >= 0) return 'note';
                if (lower.indexOf('weread://') === 0
                    && lower.indexOf('note') >= 0) return 'note';
                return '';
            }

            function annotationHref(node) {
                if (!node || node.nodeType !== 1) return '';
                var attrs = ['href', 'data-href', 'data-url', 'data-link'];
                for (var i = 0; i < attrs.length; i++) {
                    var raw = node.getAttribute(attrs[i]);
                    if (!raw) continue;
                    var value = String(raw).trim();
                    if (!value) continue;
                    var lower = value.toLowerCase();
                    // 章内脚注锚点交给浏览器原地滚，不算批注链接。
                    if (lower.charAt(0) === '#') continue;
                    if (lower.indexOf('javascript:') === 0) {
                        if (annotationHint(value)) return value.slice(0, 200);
                        continue;
                    }
                    return value.slice(0, 200);
                }
                return '';
            }

            function annotationMark(node) {
                if (!node || node.nodeType !== 1) return '';
                if (annotationHint(node.getAttribute('onclick'))) return 'onclick';
                for (var i = 0; i < NOTE_ATTRS.length; i++) {
                    var raw = node.getAttribute(NOTE_ATTRS[i]);
                    if (raw && String(raw).trim()) return NOTE_ATTRS[i];
                }
                var cls = String(node.getAttribute('class') || '');
                if (/(^|\\s)(wr_highlight\\w*|reader_note|reader_review)(\\s|$)/i.test(cls)) {
                    return 'class';
                }
                if (node.tagName && node.tagName.toLowerCase() === 'mark'
                    && /(^|\\s)wr-hl(\\s|$)/i.test(cls)
                    && String(node.getAttribute('data-note') || '').trim()) {
                    return 'mark';
                }
                if (annotationHint(node.getAttribute('href'))) return 'href';
                return '';
            }

            function annotationLinkTarget(start) {
                var node = start;
                var depth = 0;
                while (node && node !== document && depth < 8) {
                    if (node.nodeType === 1) {
                        if (annotationMark(node)) {
                            var href = annotationHref(node);
                            var text = '';
                            try {
                                text = node.innerText || node.textContent || '';
                            } catch (e) { text = ''; }
                            if (!text) {
                                text = node.getAttribute('title')
                                    || node.getAttribute('aria-label')
                                    || '';
                            }
                            return {
                                node: node,
                                href: href,
                                text: String(text).replace(/\\s+/g, ' ').trim().slice(0, 80)
                            };
                        }
                    }
                    node = node.parentElement;
                    depth += 1;
                }
                return null;
            }

            document.addEventListener('click', function (event) {
                // 批注优先：蓝条可能同时带 `partNNNN.html` 和批注标记，
                // 这种情况要进笔记面板，不能当成目录链接去换章。
                var noteHit = annotationLinkTarget(event.target);
                if (noteHit) {
                    event.preventDefault();
                    event.stopImmediatePropagation();
                    window.webkit.messageHandlers.weread.postMessage({
                        type: 'annotationLink',
                        href: noteHit.href,
                        text: noteHit.text
                    });
                    return;
                }
                var hit = chapterLinkTarget(event.target);
                // 点正文空白处切换沉浸阅读（隐藏/显示上下栏）。只在没有选中
                // 文字、不是链接/批注、不在浮动工具条上时触发，避免干扰划线。
                if (!hit && !noteHit) {
                    var sel = '';
                    try { sel = String(window.getSelection() || '').trim(); } catch (e) { sel = ''; }
                    var onTools = false;
                    try { onTools = !!event.target.closest('#wr-tools'); } catch (e) { onTools = false; }
                    if (!sel && !onTools && event.target.closest && event.target.closest('#wr-content')) {
                        window.webkit.messageHandlers.weread.postMessage({ type: 'toggleFullscreen' });
                    }
                }
                if (!hit) return;
                // 用 stopImmediatePropagation：stopPropagation 不拦同一元素上
                // 其它 listener，微读页面自己绑的跳转仍可能把 404 放出去。
                event.preventDefault();
                event.stopImmediatePropagation();
                var href = hit.href;
                // 同一篇里的脚注锚点（`part0012.html#note3` 但 note3 就在
                // 本文档里）直接滚过去，不要当成换章。
                var hashAt = href.indexOf('#');
                if (hashAt >= 0) {
                    var id = href.slice(hashAt + 1);
                    try { id = decodeURIComponent(id); } catch (e) {}
                    var target = null;
                    try {
                        target = document.getElementById(id)
                            || document.getElementsByName(id)[0];
                    } catch (e) { target = null; }
                    if (target && target.scrollIntoView) {
                        target.scrollIntoView();
                        return;
                    }
                }
                var text = '';
                try {
                    text = hit.node.innerText || hit.node.textContent || '';
                } catch (e) { text = ''; }
                if (!text) {
                    text = hit.node.getAttribute('title')
                        || hit.node.getAttribute('aria-label')
                        || '';
                }
                window.webkit.messageHandlers.weread.postMessage({
                    type: 'chapterLink',
                    href: href,
                    text: String(text).trim()
                });
            }, true);

            // 章节 HTML 会在元素上内联写 user-select:none / touch-callout:none，
            // 且可能带 !important。样式表里的 !important 压不过内联 !important，
            // 所以加载后直接把正文树上的这些内联属性删掉。
            function stripSelectionLocks(root) {
                if (!root) return;
                var nodes = [root];
                var descendants = root.querySelectorAll('*');
                for (var i = 0; i < descendants.length; i++) {
                    nodes.push(descendants[i]);
                }
                for (var j = 0; j < nodes.length; j++) {
                    var el = nodes[j];
                    try {
                        el.removeAttribute('unselectable');
                        if (!el.style) continue;
                        el.style.removeProperty('-webkit-user-select');
                        el.style.removeProperty('user-select');
                        el.style.removeProperty('-webkit-touch-callout');
                    } catch (e) {}
                }
            }
            stripSelectionLocks(document.getElementById('wr-content'));
            window.addEventListener('load', function () {
                stripSelectionLocks(document.getElementById('wr-content'));
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

            // 微读服务端的 range 是章内文本偏移，必须在 surroundContents 之前算：
            // 包上 mark 之后文本节点会被拆开，再算就不准了。这里用 DOM 文本长度
            // 近似官方渲染口径，落点可能需要真机校准。
            function textOffset(root, container, offset) {
                if (!root) return 0;
                if (container !== root && !root.contains(container)) return 0;
                var probe = document.createRange();
                probe.setStart(root, 0);
                probe.setEnd(container, offset);
                return String(probe.toString() || '').length;
            }

            document.addEventListener('selectionchange', function () {
                setTimeout(function () {
                    var current = selectedText();
                    if (!current) {
                        // 点工具条时系统会先收起选区，但 click 可能晚一拍才到；
                        // 只要 savedRange 还在就保留工具条，避免第一下点击落空。
                        if (!savedRange) { hideTools(); }
                        return;
                    }
                    var rect = current.range.getBoundingClientRect();
                    if (!rect || (rect.width === 0 && rect.height === 0)) { hideTools(); return; }
                    var top = rect.top - 46;
                    if (top < 8) top = rect.bottom + 8;
                    if (top + 40 > window.innerHeight - 8) {
                        top = Math.max(8, rect.top - 46);
                    }
                    var left = Math.min(Math.max(rect.left + rect.width / 2 - 62, 8), window.innerWidth - 132);
                    tools.style.top = top + 'px';
                    tools.style.left = left + 'px';
                    tools.style.display = 'flex';
                    savedRange = current.range.cloneRange();
                }, 120);
            });

            function wrapSelection(note, rangeOverride) {
                var current = rangeOverride ? null : selectedText();
                var range = rangeOverride || (current ? current.range : savedRange);
                if (!range) return;
                var text = String(range.toString() || '').trim();
                if (!text) return;

                var mark = document.createElement('mark');
                mark.className = 'wr-hl';
                mark.id = 'h' + Date.now();
                mark.setAttribute('data-note', note || '');
                if (note) mark.title = note;

                var root = document.getElementById('wr-content');
                var start = textOffset(root, range.startContainer, range.startOffset);
                var end = textOffset(root, range.endContainer, range.endOffset);
                if (end < start) {
                    var swap = start;
                    start = end;
                    end = swap;
                }

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
                    note: note || '',
                    range: start + '-' + end
                });
                var selection = window.getSelection();
                if (selection) selection.removeAllRanges();
                hideTools();
                savedRange = null;
            }

            function keepSelection(event) {
                event.stopPropagation();
            }
            // 不能 preventDefault：touchend 被拦后 iOS 不会再合成 click，
            // 划线和想法按钮就成了「看得见但点不动」。
            ['touchstart', 'pointerdown', 'mousedown'].forEach(function (name) {
                document.getElementById('wr-hl').addEventListener(name, keepSelection, { passive: true });
                document.getElementById('wr-note').addEventListener(name, keepSelection, { passive: true });
            });
            // 点正文或空白处才收起工具条并清掉暂存选区。
            ['touchstart', 'mousedown'].forEach(function (name) {
                document.addEventListener(name, function (event) {
                    if (event.target && tools.contains(event.target)) return;
                    savedRange = null;
                    hideTools();
                }, { passive: true, capture: true });
            });

            document.getElementById('wr-hl').addEventListener('click', function (event) {
                event.preventDefault();
                wrapSelection('');
            });

            // 「想法」不再调用 window.prompt：WKWebView 的 prompt 依赖
            // WKUIDelegate 的 UIKit 弹窗回调，presenter 找不到时 JS 会一直挂起，
            // 表现就是「点了没反应」。这里把选区和文字留在 JS，交给 Swift
            // 原生浮层输入，结果通过 __wrApplyNote 回传。
            var pendingNoteRange = null;

            document.getElementById('wr-note').addEventListener('click', function (event) {
                event.preventDefault();
                if (pendingNoteRange) return;
                var current = selectedText();
                var range = current ? current.range.cloneRange() : savedRange;
                if (!range) return;
                var text = String(range.toString() || '').trim();
                if (!text) return;
                pendingNoteRange = range;
                window.webkit.messageHandlers.weread.postMessage({
                    type: 'noteRequest',
                    text: text
                });
            });

            window.__wrApplyNote = function (note) {
                var range = pendingNoteRange;
                pendingNoteRange = null;
                if (!range) return;
                if (note === null || note === undefined || String(note).trim() === '') {
                    var selection = window.getSelection();
                    if (selection) selection.removeAllRanges();
                    savedRange = null;
                    hideTools();
                    return;
                }
                wrapSelection(String(note), range);
            };

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

            // —— 阅读进度：续读定位 + 位置上报 ——
            // Swift 传进来的 offset 是章内字符偏移（和微读 chapterOffset 同口径）；
            // fraction 只在正文还没量出文本长度时兜底。
            var pendingRestore = null;
            var restoreAt = 0;
            // 恢复落点和上报取样必须用同一个视口锚点，否则每进一次会漂一行。
            var progressAnchorY = 48;
            // 取样点要落在视口顶部那一行的字形盒里，不能正好压在行的上边界上，
            // 否则 caretRangeFromPoint 可能取到上一行，每重进一次就往上漂一行。
            var progressProbeY = progressAnchorY + 12;
            var scrollStopTimer = 0;

            function textNodeAt(root, offset) {
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
                var remaining = offset;
                var last = null;
                var node = null;
                while ((node = walker.nextNode())) {
                    var value = node.nodeValue || '';
                    if (!value.length) continue;
                    if (remaining < value.length) return { node: node, at: remaining };
                    remaining -= value.length;
                    last = node;
                }
                // offset 正好落在文末：退到最后一个字符，保证还能量出矩形。
                if (last) return { node: last, at: last.nodeValue.length - 1 };
                return null;
            }

            function applyRestore() {
                if (!pendingRestore) return true;
                // 用户已经自己滑动/点按，就别再按旧位置把人拽回去。
                if (pendingRestore.moved) return true;
                var root = document.getElementById('wr-content');
                var max = document.documentElement.scrollHeight - window.innerHeight;
                if (!(max > 0)) return false;
                var target = 0;
                var found = false;
                var total = root ? String(root.textContent || '').length : 0;
                // 官方 chapterOffset 和 DOM 文本口径可能不同（TXT 章节会
                // 去掉行首空白/空行，长度偏短）。offset 明显超过 DOM 全长时
                // textNodeAt 会退到最后一个字符，反而跳到章尾；这种时候只用
                // 比例兜底，宁可略偏也不要固定跑到章尾。
                var offsetTooLarge = total > 0
                    && pendingRestore.offset > Math.max(total * 1.5, total + 2000);
                if (pendingRestore.offset > 0 && root && !offsetTooLarge) {
                    var position = textNodeAt(root, pendingRestore.offset);
                    if (position) {
                        try {
                            var length = position.node.nodeValue.length;
                            var range = document.createRange();
                            range.setStart(position.node, position.at);
                            range.setEnd(
                                position.node,
                                Math.min(position.at + 1, length)
                            );
                            var rect = range.getBoundingClientRect();
                            target = window.scrollY + rect.top - progressAnchorY;
                            found = true;
                        } catch (e) {}
                    }
                    if (!found && total > 0) {
                        target = max * Math.min(pendingRestore.offset / total, 1);
                    }
                }
                // 只有「按 offset 根本没定位到」时才用比例兜底；定位到章首
                // 附近（target <= 0）是合法结果，不能再用比例把人往前推。
                if (!found && pendingRestore.fraction > 0) {
                    target = max * Math.min(Math.max(pendingRestore.fraction, 0), 1);
                }
                target = Math.min(Math.max(target, 0), max);
                restoreAt = Date.now();
                window.scrollTo(0, Math.round(target));
                pendingRestore.applied = true;
                return true;
            }

            window.__wrRestoreProgress = function (offset, fraction) {
                pendingRestore = {
                    offset: Number(offset) || 0,
                    fraction: Number(fraction) || 0,
                    applied: false,
                    moved: false
                };
                return applyRestore();
            };

            // 图片加载完正文会重新排版，落点会偏；再校一次。用户已经自己
            // 滚动过就不再拽回去。
            window.addEventListener('load', function () {
                if (pendingRestore && !pendingRestore.moved) applyRestore();
            });

            // 视口顶部那一行对应的章内字符偏移。取不到文本节点时按比例折算。
            function currentOffset() {
                var root = document.getElementById('wr-content');
                if (!root) return 0;
                try {
                    if (document.caretRangeFromPoint) {
                        var caret = document.caretRangeFromPoint(
                            window.innerWidth / 2,
                            progressProbeY
                        );
                        if (caret && root.contains(caret.startContainer)) {
                            var probe = document.createRange();
                            probe.setStart(root, 0);
                            probe.setEnd(caret.startContainer, caret.startOffset);
                            return String(probe.toString() || '').length;
                        }
                    }
                    // 新版 WebKit 可能只实现标准接口，补一条同样的兜底。
                    if (document.caretPositionFromPoint) {
                        var caret = document.caretPositionFromPoint(
                            window.innerWidth / 2,
                            progressProbeY
                        );
                        if (caret && caret.offsetNode && root.contains(caret.offsetNode)) {
                            var probe = document.createRange();
                            probe.setStart(root, 0);
                            probe.setEnd(caret.offsetNode, caret.offset);
                            return String(probe.toString() || '').length;
                        }
                    }
                } catch (e) {}
                var max = document.documentElement.scrollHeight - window.innerHeight;
                var total = String(root.textContent || '').length;
                if (!(max > 0) || total <= 0) return 0;
                var ratio = Math.min(Math.max(window.scrollY / max, 0), 1);
                return Math.round(total * ratio);
            }

            var lastReport = 0;
            var lastSent = null;

            function restoring() {
                return pendingRestore && !pendingRestore.moved;
            }

            function reportScroll(force) {
                // 恢复本身也会触发 scroll；这时候报上去的落点和 Swift 记的目标
                // 可能差一行，反复进出就会漂。恢复阶段先不报，等用户自己滚动。
                if (restoring()) return;
                var max = document.documentElement.scrollHeight - window.innerHeight;
                var value = max > 0 ? window.scrollY / max : 0;
                var offset = currentOffset();
                var now = Date.now();
                if (!force && now - lastReport < 200) return;
                lastReport = now;
                if (lastSent && lastSent.value === value && lastSent.offset === offset) return;
                lastSent = { value: value, offset: offset };
                window.webkit.messageHandlers.weread.postMessage({
                    type: 'scroll',
                    value: value,
                    offset: offset
                });
            }

            window.addEventListener('scroll', function () {
                if (pendingRestore && !pendingRestore.moved && Date.now() - restoreAt > 400) {
                    pendingRestore.moved = true;
                    reportScroll(true);
                }
                reportScroll(false);
                // 老 iOS 没有 scrollend：滚动停下 180ms 后强制补一次，
                // 惯性滚动结束后的最终位置才不会被 200ms 节流吞掉。
                clearTimeout(scrollStopTimer);
                scrollStopTimer = setTimeout(function () { reportScroll(true); }, 180);
            }, { passive: true });

            // 手指一碰就代表用户接管阅读位置，恢复阶段立即结束。
            ['touchstart', 'mousedown'].forEach(function (name) {
                window.addEventListener(name, function () {
                    if (pendingRestore) pendingRestore.moved = true;
                }, { passive: true });
            });

            // 退出前/手指松开时立刻补一次，别被 200ms 节流吞掉最后一段。
            ['touchend', 'scrollend', 'pagehide'].forEach(function (name) {
                window.addEventListener(name, function () { reportScroll(true); }, { passive: true });
            });

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

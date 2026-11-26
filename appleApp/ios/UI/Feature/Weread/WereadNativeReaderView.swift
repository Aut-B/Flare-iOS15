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

/// 原生阅读页的正文字号范围。
///
/// 只改生成页面的 CSS 变量让浏览器重排，不缩放整页、不引入横向滚动；
/// 字号只存在 `@State` 内存里，切章保持，重开书回到默认，不落任何本地存储。
private enum WereadFontSize {
    static let minimum: CGFloat = 15
    static let maximum: CGFloat = 25
    static let step: CGFloat = 2
    static let initial: CGFloat = 17
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
    @Environment(\.colorScheme) private var colorScheme

    @State private var chapters: [WereadChapter] = []
    @State private var index = 0
    @State private var html = ""
    @State private var loading = true
    @State private var errorMessage: String?
    /// PDF 不能走原生 chapter 分片；置 true 后只显示跳转网页版的提示页。
    @State private var isPDF = false
    /// PDF 画布缩放倍数。只对官方网页阅读器的 canvas 整页做 GPU 缩放，
    /// 文字书仍走 `fontSize` 重排。纯内存状态，不写 UserDefaults。
    @State private var pdfZoomScale: CGFloat = 1
    /// 沉浸阅读：点正文空白处切换，隐藏上下栏。
    @State private var immersive = false
    /// 正文字号。切章时视图本身不重建，所以会保持；不写 UserDefaults。
    @State private var fontSize: CGFloat = WereadFontSize.initial
    @State private var showChapters = false
    @State private var showWeb = false
    @State private var cache: [Int: String] = [:]
    /// 章节正文缓存的「最近使用顺序」，队尾最新。配合 `cacheCapacity` 做淘汰。
    /// 以前 cache 只增不减，读一本几百章的书会把整本 HTML 都攒在内存里，
    /// iPhone 6s 只有 2GB，翻到后面容易被系统杀掉。
    @State private var cacheOrder: [Int] = []
    /// 本次会话里新增/兼容展示的划线只留内存，不再写 UserDefaults。
    @State private var highlights: [Int: [WereadHighlight]] = [:]
    /// 服务端同步的划线/想法，按 chapterUid 分组。和内存划线分开存，
    /// 合并时以云端为准，不再把服务端笔记写回本机。
    @State private var serverNotes: [Int: [WereadBookmark]] = [:]
    /// 云端划线是否至少成功拉取过一次（空数组也算）。旧本机数据迁移前
    /// 必须先拿到这份索引，否则无法判断哪些内容云端已有，容易重复上传。
    @State private var serverNotesLoaded = false
    /// 旧 UserDefaults 划线只在每本书首次打开时尝试迁移一次。
    @State private var legacyMigrationStarted = false
    /// 新增划线/想法上传失败时的明确提示，不能把会话内可见当成已同步。
    @State private var highlightSyncMessage: String?
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
    /// 前台阅读计时的锚点：从这一刻起的时间会算进下一次 `rt` 上报。
    @State private var readingFlushAnchor: Date?
    /// 已计时但还没上报的秒数。单次最多报 60 秒，多出的留到下一次。
    @State private var pendingReadingSeconds = 0
    /// 前台每 30 秒（官方 `startReportTimer` 的 30000ms）上报阅读时长的循环任务。
    @State private var readingTimer: Task<Void, Never>?
    /// 是否已有一条带 `rt` 的上报在路上；避免并发 flush 把同一段秒数发两遍。
    @State private var readingFlushInFlight = false
    /// 所有 `/web/book/read` 共用的串行任务链。前一条请求完整结束后才发下一条，
    /// 旧章快照即使晚到也只能排在以前，不会反超新章。
    @State private var reportTail: Task<Void, Never>?
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
    @State private var pendingEdit: WereadCloudNote?
    /// 删除确认中的云端条目 / 正在删除的条目 id / 删除失败提示。
    @State private var pendingDelete: WereadCloudNote?
    @State private var deletingNoteID: String?
    @State private var deleteError: String?
    /// 回传给 JS 的想法内容；`text == nil` 表示取消。
    @State private var noteReply: WereadNoteReply?
    @State private var noteReplyToken = 0
    /// 官方翻译实验。译文只活在 WebView 的章节 DOM 里；
    /// 这里只保留开关、显隐、节点数和轮询状态，不保存任何译文文本。
    @State private var translationOn = false
    @State private var translationVisible = false
    @State private var translationBusy = false
    @State private var translationStatus: String?
    @State private var translationMessage: String?
    /// 当前章节 `.wr-translation` 节点数；-1 表示还没收到本次页面回报。
    @State private var translationNodeCount = -1
    @State private var translationTask: Task<Void, Never>?
    /// 官方动态格式信息与切换状态。只有服务端提供 `otherType` 的书才会
    /// 出现入口；纯 PDF 不在本机造文本层。
    @State private var formatInfo: WereadBookFormatInfo?
    @State private var formatBusy = false
    @State private var formatMessage: String?
    /// 切换格式后官方要求跳转的阅读器地址（带 `jumpType=switchFormat`）。
    @State private var webURLOverride: String?
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
                // 服务端有想法时以服务端为准：旧本机镜像只用于兼容迁移，
                // 不能盖过云端内容，也不能反过来冒充成已同步笔记。
                if !bookmark.note.isEmpty {
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

    /// 全书云端笔记 / 划线 / 想法。
    ///
    /// 只由 `serverNotes` 和 `ownReviews` 构造，**不读本地 UserDefaults
    /// 里的划线**，避免把本机记录冒充成云端已同步内容。条目按目录顺序、
    /// 创建时间排序；同一段划线上的多条想法各占一行，编辑/删除才不会
    /// 误改到别的想法。
    private var cloudNoteEntries: [WereadCloudNote] {
        var rows: [WereadCloudNote] = []
        var usedReviewIds = Set<String>()
        var coveredBookmarkIds = Set<String>()
        // 一次建好章节索引，避免每条笔记都线性扫一遍目录（6S 上章节多时很贵）。
        let chapterByUid = Dictionary(
            chapters.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func chapterIndex(for uid: Int) -> Int {
            chapterByUid[uid]?.index ?? 0
        }
        func chapterSortKey(for uid: Int) -> Int {
            chapterByUid[uid]?.index ?? Int.max
        }
        func chapterTitle(for uid: Int) -> String {
            let title = chapterByUid[uid]?.title ?? ""
            return title.isEmpty ? "章节 \(uid)" : title
        }

        // 想法是编辑/删除的最小单位，先按 review 建行；能对上划线时把
        // bookmarkId 一起带上，删除整条（划线 + 想法）才有依据。
        let reviews = ownReviews.sorted { lhs, rhs in
            let left = chapterSortKey(for: lhs.chapterUid)
            let right = chapterSortKey(for: rhs.chapterUid)
            if left != right { return left < right }
            return lhs.reviewId < rhs.reviewId
        }
        for review in reviews {
            guard !review.content.isEmpty else { continue }
            let bookmark = serverNotes[review.chapterUid]?.first { item in
                let text = normalizedText(item.markText)
                let byRange = !review.range.isEmpty && item.range == review.range
                let byText =
                    !review.abstract.isEmpty
                    && text == normalizedText(review.abstract)
                return byRange || byText
            }
            let bookmarkId = bookmark.flatMap(serverBookmarkId)
            if let bookmarkId { coveredBookmarkIds.insert(bookmarkId) }
            usedReviewIds.insert(review.reviewId)
            rows.append(
                WereadCloudNote(
                    id: "review:\(review.reviewId)",
                    chapterUid: review.chapterUid,
                    chapterIndex: chapterIndex(for: review.chapterUid),
                    chapterTitle: chapterTitle(for: review.chapterUid),
                    text: normalizedText(review.abstract),
                    note: review.content,
                    range: review.range,
                    createTime: bookmark?.createTime ?? 0,
                    kind: .thought,
                    bookmarkId: bookmarkId,
                    reviewId: review.reviewId
                )
            )
        }

        // 再补纯划线和「想法索引没拉到时」的服务端条目。
        for (chapterUid, list) in serverNotes {
            for bookmark in list {
                let text = normalizedText(bookmark.markText)
                let note = normalizedText(bookmark.note)
                guard !text.isEmpty || !note.isEmpty else { continue }
                let bookmarkId = serverBookmarkId(bookmark)
                if note.isEmpty {
                    rows.append(
                        WereadCloudNote(
                            id: "mark:\(bookmark.id)",
                            chapterUid: chapterUid,
                            chapterIndex: chapterIndex(for: chapterUid),
                            chapterTitle: chapterTitle(for: chapterUid),
                            text: text,
                            note: "",
                            range: bookmark.range,
                            createTime: bookmark.createTime,
                            kind: .highlight,
                            bookmarkId: bookmarkId,
                            reviewId: nil
                        )
                    )
                    continue
                }
                // id 本身就是 reviewId 的条目已经在上面按想法建过行。
                if usedReviewIds.contains(bookmark.id) { continue }
                if let bookmarkId, coveredBookmarkIds.contains(bookmarkId) { continue }
                // 这条 note 已经由上面的 ownReviews 行覆盖时不再重复；
                // 仅存在于 bookmarklist 的内联 note 仍然要展示。
                let coveredByNote = ownReviews.contains { review in
                    guard review.chapterUid == chapterUid else { return false }
                    let content = normalizedText(review.content)
                    return !content.isEmpty && (content == note || note.contains(content))
                }
                if coveredByNote { continue }
                rows.append(
                    WereadCloudNote(
                        id: "server:\(bookmark.id)",
                        chapterUid: chapterUid,
                        chapterIndex: chapterIndex(for: chapterUid),
                        chapterTitle: chapterTitle(for: chapterUid),
                        text: text,
                        note: note,
                        range: bookmark.range,
                        createTime: bookmark.createTime,
                        kind: .thought,
                        bookmarkId: bookmarkId,
                        reviewId: nil
                    )
                )
            }
        }

        return rows.sorted { lhs, rhs in
            let left = chapterSortKey(for: lhs.chapterUid)
            let right = chapterSortKey(for: rhs.chapterUid)
            if left != right { return left < right }
            let lTime = lhs.createTime > 0 ? lhs.createTime : TimeInterval.greatestFiniteMagnitude
            let rTime = rhs.createTime > 0 ? rhs.createTime : TimeInterval.greatestFiniteMagnitude
            if lTime != rTime { return lTime < rTime }
            return lhs.id < rhs.id
        }
    }

    /// `bookmarklist` 的真实划线 id；`bookmark-...` / `thought-...`
    /// 是拉取失败时的合成 id，或本身是想法 id，不能拿去删划线。
    private func serverBookmarkId(_ bookmark: WereadBookmark) -> String? {
        let id = bookmark.id
        guard
            !id.isEmpty,
            !id.hasPrefix("bookmark-"),
            !id.hasPrefix("thought-"),
            !ownReviews.contains(where: { $0.reviewId == id })
        else {
            return nil
        }
        return id
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
        // 左下 / 右下各一个单字按钮，只占自己的命中区域，不铺整条底栏。
        // 两个 overlay 分开做，避免再出现整层容器挡住正文的情况。
        .overlay(alignment: .bottomLeading) {
            if !isPDF, !chapters.isEmpty {
                pageTurnButton(
                    title: "上",
                    systemImage: "chevron.up",
                    accessibilityLabel: "上一章",
                    enabled: index > 0 && !loading
                ) {
                    Task { await open(index - 1) }
                }
                .padding(.leading, 16)
                .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isPDF, !chapters.isEmpty {
                pageTurnButton(
                    title: "下",
                    systemImage: "chevron.down",
                    accessibilityLabel: "下一章",
                    enabled: index < chapters.count - 1 && !loading
                ) {
                    Task { await open(index + 1) }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        .overlay {
            if let request = noteRequest {
                noteEditor(request)
            }
        }
        .overlay(alignment: .top) {
            if translationBusy || formatBusy {
                HStack(spacing: 6) {
                    ProgressView()
                    Text(
                        formatBusy
                            ? "正在切换官方格式…"
                            : (translationStatus ?? "正在请求官方翻译…")
                    )
                        .font(.caption2)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
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
            if isPDF {
                // PDF 正文是官方网页阅读器画的 canvas，没有文本层；改字号只会
                // 让网页重排。这里给整页套一个可缩放画布，双指/按钮都是
                // GPU transform，不注入 CSS、不重绘文本。
                WereadPDFCanvasReader(
                    zoomScale: $pdfZoomScale,
                    canSwitchFormat: formatInfo?.canSwitch == true
                        && formatInfo?.current == .pdf,
                    formatBusy: formatBusy,
                    formatMessage: $formatMessage,
                    onSwitchFormat: {
                        Task { await requestFormatSwitch(to: .epub) }
                    },
                    onClose: { showWeb = false }
                ) {
                    WereadReaderView(target: webReaderTarget)
                }
            } else {
                WereadReaderView(target: webReaderTarget)
            }
        }
        .onDisappear {
            translationTask?.cancel()
            stopReadingTimer()
            // 先同步落本机再上报：上报要等网络，进程可能先被挂起/回收，
            // 不能把「退出前的最后一段位置」押在异步任务一定跑完上。
            persistLocalProgress()
            Task { await saveProgress() }
        }
        // 切后台/被系统回收前再落一次；强杀无法拦截，滚动节流和续读
        // 目标落盘才是「读到一半被杀」的主要保障。
        .backportOnChange(of: scenePhase) { _, phase in
            if phase == .active {
                // 只算前台时间：回前台重新起锚点，不补后台停留的秒数。
                startReadingTimer()
            } else {
                stopReadingTimer()
                persistLocalProgress()
                Task { await saveProgress() }
            }
        }
        .backportOnChange(of: showWeb) { _, shown in
            // 进了官方网页阅读器就交给它自己计时，避免两边同时上报。
            if shown {
                stopReadingTimer()
                persistLocalProgress()
                Task { await saveProgress() }
            } else {
                pdfZoomScale = 1
                startReadingTimer()
            }
        }
        .alert(
            "翻译（实验）",
            isPresented: Binding(
                get: { translationMessage != nil },
                set: { if !$0 { translationMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(translationMessage ?? "")
        }
        .alert(
            "切换格式",
            isPresented: Binding(
                // PDF 画布自己也会弹同一个 alert，避免两处同时呈现。
                get: { formatMessage != nil && !isPDF },
                set: { if !$0 { formatMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(formatMessage ?? "")
        }
        .alert(
            "划线未同步",
            isPresented: Binding(
                get: { highlightSyncMessage != nil },
                set: { if !$0 { highlightSyncMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(highlightSyncMessage ?? "")
        }
    }

    /// PDF 直接给官方 `/web/reader/<hash>`，不再先落到网页书架自动点书。
    /// 非 PDF 保持原来的书架兜底，避免改掉已有的阅读器地址处理逻辑。
    private var webReaderTarget: WereadReaderTarget {
        if let webURLOverride, !webURLOverride.isEmpty {
            return WereadReaderTarget(
                url: webURLOverride,
                title: target.book.title,
                bookId: target.book.id,
                needsJump: false,
                isPDF: isPDF
            )
        }
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
            fontSize: fontSize,
            translationVisible: translationVisible,
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

                // 新划线/想法只进内存并上传云端，不再写本机 UserDefaults。
                // 未登录或上传失败时只在本次会话可见，必须明确提示，不能
                // 把「看得见」当成「已同步」。
                let bookId = target.book.id
                let cookie = store.cookie
                let chapterUid = chapter.uid
                let chapterIdx = chapter.index
                guard !cookie.isEmpty else {
                    let line =
                        "划线仅保留在会话内，未登录未上传 book=\(bookId) " +
                        "chapter=\(chapterUid)"
                    WereadService.screenDiag(line)
                    FlareDiagnostics.shared.record(.weread, "ERR", line)
                    highlightSyncMessage =
                        "未登录微信读书，刚做的划线/想法只保留在本次阅读里，" +
                        "不会写入本机；登录后请重新划线。"
                    return
                }
                let token = loadToken
                Task { @MainActor in
                    let ok = await WereadService.shared.uploadHighlight(
                        bookId: bookId,
                        chapterUid: chapterUid,
                        chapterIdx: chapterIdx,
                        range: item.range ?? "",
                        markText: item.text,
                        note: item.note,
                        cookie: cookie
                    )
                    guard ok else {
                        highlightSyncMessage =
                            "划线/想法没有同步到微信读书云端。笔记只存云端，" +
                            "重启后不会保留这条；请检查登录或网络后重新划线。"
                        return
                    }
                    // 上传成功后重新拉云端索引，让笔记面板立刻以服务端为准。
                    guard token == loadToken else { return }
                    await refreshNotes()
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
                // 有章节只靠滚动就绪（没走加载成功分支）时，也把阅读计时带起来。
                startReadingTimer()
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
                // 或相对伪地址时也不该真的导航，统一落到笔记面板。
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
            },
            onTranslationCount: { count in
                // 旧页面迟到的节点数不能覆盖新章节的统计。
                guard token == self.loadToken else { return }
                translationNodeCount = count
            }
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await saveProgress() }
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
                fontSizeControls

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
                    if let info = formatInfo,
                       info.canSwitch,
                       info.current == .epub
                    {
                        Button {
                            Task { await requestFormatSwitch(to: .pdf) }
                        } label: {
                            Label("切换为 PDF", systemImage: "doc.richtext")
                        }
                        .disabled(formatBusy)
                    }
                    Button {
                        showNotes = true
                    } label: {
                        Label("笔记（\(cloudNoteEntries.count)）", systemImage: "text.quote")
                    }
                    Divider()
                    Button {
                        startTranslation()
                    } label: {
                        Label(
                            translationOn ? "翻译已开启" : "开启自动翻译（实验）",
                            systemImage: "character.bubble"
                        )
                    }
                    .disabled(translationOn || translationBusy)
                    Button {
                        showTranslation()
                    } label: {
                        Label("显示译文", systemImage: "text.bubble")
                    }
                    .disabled(!translationOn || translationVisible || translationBusy)
                    Button {
                        translationVisible = false
                    } label: {
                        Label("只看原文", systemImage: "text.alignleft")
                    }
                    .disabled(!translationVisible)
                    if translationOn {
                        Button(role: .destructive) {
                            startCancellingTranslation()
                        } label: {
                            Label("取消翻译", systemImage: "xmark.circle")
                        }
                        .disabled(translationBusy)
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

    /// 左下 / 右下的单字翻章按钮：48pt 触控区，44pt 可见圆钮。
    /// 纸色实底 + 墨色字，方向箭头只做轻提示；不用材质、模糊或重阴影。
    private func pageTurnButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: -1) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pageTurnInk.opacity(0.62))
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(pageTurnInk)
            }
            .frame(width: 48, height: 48)
            .background(
                Circle()
                    .fill(pageTurnSurface)
                    .frame(width: 44, height: 44)
            )
            .overlay(
                Circle()
                    .strokeBorder(pageTurnInk.opacity(0.16), lineWidth: 0.75)
                    .frame(width: 44, height: 44)
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(PageTurnButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 翻章按钮的纸色与墨色。比纯系统灰更柔和，深色模式也不发白。
    private var pageTurnInk: Color {
        colorScheme == .dark
            ? Color(red: 0.88, green: 0.85, blue: 0.78)
            : Color(red: 0.30, green: 0.27, blue: 0.22)
    }

    private var pageTurnSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.15, blue: 0.13)
            : Color(red: 0.96, green: 0.95, blue: 0.92)
    }

    /// 顶部字号按钮。放在顶栏而不是正文底部，避免和左/右下翻章按钮、
    /// 网页里的划选工具条抢同一块区域；沉浸时随顶栏一起收起，不打断阅读。
    private var fontSizeControls: some View {
        HStack(spacing: 0) {
            fontSizeButton(
                label: "A−",
                accessibilityLabel: "缩小字体",
                enabled: fontSize > WereadFontSize.minimum
            ) {
                adjustFontSize(by: -WereadFontSize.step)
            }
            fontSizeButton(
                label: "A+",
                accessibilityLabel: "放大字体",
                enabled: fontSize < WereadFontSize.maximum
            ) {
                adjustFontSize(by: WereadFontSize.step)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("当前字号 \(Int(fontSize))")
    }

    private func fontSizeButton(
        label: String,
        accessibilityLabel: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 字号按固定步长增减并夹在上下限内；不带动画，6S 上点一下立即重排。
    private func adjustFontSize(by delta: CGFloat) {
        let next = min(
            max(fontSize + delta, WereadFontSize.minimum),
            WereadFontSize.maximum
        )
        guard next != fontSize else { return }
        fontSize = next
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
                if notesLoading, cloudNoteEntries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在同步微读笔记…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let notesError, cloudNoteEntries.isEmpty {
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
                        Button("重试") { Task { await refreshNotes() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cloudNoteEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("这本书还没有同步的笔记")
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
                            ForEach(cloudNoteEntries) { item in
                                Button {
                                    // 面板还开着时主视图的编辑浮层会被盖住，先收起面板。
                                    guard deletingNoteID == nil else { return }
                                    pendingEdit = item
                                    showNotes = false
                                } label: {
                                    noteRow(item)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = item
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDelete = item
                                    } label: {
                                        Label("删除云端笔记", systemImage: "trash")
                                    }
                                }
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "全书 \(cloudNoteEntries.count) 条，来自微信读书云端。" +
                                        "点一条编辑或补想法，左滑 / 长按删除。"
                                )
                                if !ownReviewsLoaded, !store.cookie.isEmpty {
                                    Text("想法索引未同步，编辑/删除可能暂不可用；点左上角刷新或稍后重试。")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await refreshNotes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(notesLoading || deletingNoteID != nil)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showNotes = false }
                }
            }
            .confirmationDialog(
                "从微信读书云端删除？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                // 想法索引没拉到时不给会误导的删除按钮，只留取消和说明。
                if !(item.reviewId == nil && !item.note.isEmpty) {
                    if item.reviewId?.isEmpty == false {
                        Button("删除想法", role: .destructive) {
                            Task { await deleteCloudNote(item, removeHighlight: false) }
                        }
                    }
                    if item.bookmarkId?.isEmpty == false {
                        Button(
                            item.reviewId == nil ? "删除划线" : "删除划线及想法",
                            role: .destructive
                        ) {
                            Task { await deleteCloudNote(item, removeHighlight: true) }
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { item in
                if item.reviewId == nil, !item.note.isEmpty {
                    Text("这条想法的云端索引还没同步，先刷新列表再删除；现在不会执行删除。")
                } else {
                    Text("会直接同步到微信读书云端，官方 App 里也会消失，且不可撤销。")
                }
            }
            .alert(
                "删除失败",
                isPresented: Binding(
                    get: { deleteError != nil },
                    set: { if !$0 { deleteError = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    /// 笔记面板里的一行。整行可点，所以不再开 `textSelection` ——
    /// 文本选择会吞掉点击，用户会以为「点不进去」。
    private func noteRow(_ item: WereadCloudNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.chapterTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.kind.title)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                }
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
            if deletingNoteID == item.id {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
            // JS 选文新建：保持原来的回传链路，只进内存并上传云端，
            // 由 onHighlight 完成，不再写本机。
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
        // 云端条目的章节跟着条目本身走，不能读 `current`：用户可能已经
        // 翻到别的章，按当前章保存会把想法写到错误章节。
        let chapterUid = request.chapterUid > 0 ? request.chapterUid : (current?.uid ?? 0)
        let chapterIdx = request.chapterIdx
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
    private func beginEditing(_ entry: WereadCloudNote) {
        noteError = nil
        noteSaving = false
        if ownReviewsLoaded || store.cookie.isEmpty {
            presentEditor(for: entry)
            return
        }
        Task { await prepareEditor(for: entry) }
    }

    @MainActor
    private func prepareEditor(for entry: WereadCloudNote) async {
        await loadOwnReviews()
        presentEditor(for: entry)
    }

    private func presentEditor(for entry: WereadCloudNote) {
        let matched =
            entry.reviewId.flatMap { id in
                ownReviews.first { $0.reviewId == id }
            }
            ?? matchedReview(for: entry)
        let reviewId = entry.reviewId ?? matched?.reviewId
        noteDraft = matched?.content ?? entry.note
        let highlight = WereadHighlight(
            id: entry.id,
            text: entry.text,
            note: entry.note,
            range: entry.range.isEmpty ? nil : entry.range
        )
        noteRequest = WereadNoteRequest(
            text: entry.text,
            entry: highlight,
            reviewId: reviewId,
            chapterUid: entry.chapterUid,
            chapterIdx: entry.chapterIndex,
            isEditing: reviewId != nil || !entry.note.isEmpty
        )
    }

    /// 把一条笔记对上服务端 review：章内 range 优先，原文 / 想法兜底。
    private func matchedReview(for entry: WereadCloudNote) -> WereadOwnReview? {
        let text = normalizedText(entry.text)
        let candidates = ownReviews.filter { $0.chapterUid == entry.chapterUid }
        let range = entry.range
        if !range.isEmpty {
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
        // 纯划线也可能已经在云端带了想法，只是想法索引没拉到。此时新建
        // 会多出一条重复想法，必须先让用户刷新索引。
        if reviewId == nil, !ownReviewsLoaded, !cookie.isEmpty {
            noteSaving = false
            noteError = "还没拉到云端想法索引，先刷新笔记列表再保存，避免重复新建"
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
        noteRequest = nil
        noteDraft = ""
        noteError = nil
        noteDraftFocused = false
        // 笔记只以服务端为准：保存成功后重新拉全书笔记和想法索引，
        // 不再把想法写进本机 UserDefaults。
        await refreshNotes()
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

    /// 删除一条云端笔记。想法和划线分别调官方 Web 删除接口；
    /// 删除成功后重新拉列表核对，不能只凭 HTTP 200 谎报已同步。
    @MainActor
    private func deleteCloudNote(_ note: WereadCloudNote, removeHighlight: Bool) async {
        guard deletingNoteID == nil else { return }
        guard !store.cookie.isEmpty else {
            deleteError = "微信读书登录已失效，请重新登录后再删除"
            return
        }
        let reviewId = note.reviewId
        let bookmarkId = note.bookmarkId
        if reviewId == nil, !note.note.isEmpty {
            deleteError = "这条想法的云端索引还没同步，先刷新笔记列表再删除，避免误删划线"
            return
        }
        guard reviewId != nil || (removeHighlight && bookmarkId != nil) else {
            deleteError = "这条笔记没有可用的云端 ID，刷新列表后再试"
            return
        }
        deletingNoteID = note.id
        deleteError = nil
        defer { deletingNoteID = nil }

        let service = WereadService.shared
        let cookie = store.cookie
        var deletedReview = false
        var deletedBookmark = false

        if let reviewId, !reviewId.isEmpty {
            guard await service.deleteReview(reviewId: reviewId, cookie: cookie) else {
                deleteError = "删除想法失败：微信读书没有确认删除，请稍后重试"
                return
            }
            deletedReview = true
        }

        if removeHighlight, let bookmarkId, !bookmarkId.isEmpty {
            guard await service.removeBookmark(bookmarkId: bookmarkId, cookie: cookie) else {
                if deletedReview {
                    clearLocalMirror(of: note, removeHighlight: false)
                    await refreshNotes()
                    deleteError = "想法已删除，但划线删除失败；列表已刷新，可以再删一次划线"
                } else {
                    deleteError = "删除划线失败：微信读书没有确认删除，请稍后重试"
                }
                return
            }
            deletedBookmark = true
        }

        guard deletedReview || deletedBookmark else {
            deleteError = "这条笔记没有可删除的云端内容"
            return
        }
        clearLocalMirror(of: note, removeHighlight: deletedBookmark)
        await refreshNotes()

        // 刷新失败时列表还是旧数据，不能把「请求发出去了」当成「已经删掉」。
        if deletedReview, !ownReviewsLoaded {
            deleteError = "删除想法请求已发出，但想法索引刷新失败，无法确认；请刷新列表或到官方 App 确认"
            return
        }
        if deletedBookmark, notesError != nil {
            deleteError = "划线删除请求已发出，但重新拉取失败，无法确认；请刷新列表或到官方 App 确认"
            return
        }
        var reviewStillThere = false
        if deletedReview, let reviewId {
            reviewStillThere = cloudNoteEntries.contains { $0.reviewId == reviewId }
        }
        var bookmarkStillThere = false
        if deletedBookmark, let bookmarkId {
            bookmarkStillThere = cloudNoteEntries.contains { $0.bookmarkId == bookmarkId }
        }
        if reviewStillThere || bookmarkStillThere {
            deleteError = "微信读书返回成功，但重新拉取仍看到这条笔记；请到官方 App 确认后再试"
        }
    }

    /// 只清理内存里的划线镜像，不写本机。
    /// 删除想法时只清 note，删除整条时把内存镜像一起移除；真正的删除
    /// 结果以随后 `refreshNotes()` 拉到的云端数据为准。
    private func clearLocalMirror(of note: WereadCloudNote, removeHighlight: Bool) {
        let chapterUid = note.chapterUid
        guard chapterUid > 0 else { return }
        var list = highlights[chapterUid] ?? WereadLegacyHighlightStore.load(
            bookId: target.book.id,
            chapterUid: chapterUid
        )
        guard !list.isEmpty else { return }
        let text = normalizedText(note.text)
        let ids = Set([note.id, note.bookmarkId, note.reviewId].compactMap { $0 })
        let matches: (WereadHighlight) -> Bool = { item in
            ids.contains(item.id) || (!text.isEmpty && normalizedText(item.text) == text)
        }
        if removeHighlight {
            let filtered = list.filter { !matches($0) }
            guard filtered.count != list.count else { return }
            list = filtered
        } else {
            var changed = false
            for position in list.indices where matches(list[position]) {
                if !list[position].note.isEmpty {
                    list[position] = WereadHighlight(
                        id: list[position].id,
                        text: list[position].text,
                        note: "",
                        range: list[position].range
                    )
                    changed = true
                }
            }
            guard changed else { return }
        }
        highlights[chapterUid] = list
    }

    // MARK: - 加载

    /// 通过官方 `/web/trans/pdfepub` 在 PDF / 电子书之间切换。
    ///
    /// 入口只在 `formatInfo.canSwitch` 时出现；纯 PDF 没有 `otherType`，
    /// 不显示按钮，也不在本机 OCR 或伪造文本层。PDF 转电子书可能还受
    /// 会员/付费权益限制，失败时按官方错误如实提示。
    @MainActor
    private func requestFormatSwitch(to newFormat: WereadBookFormatKind) async {
        guard let info = formatInfo else {
            formatMessage = "还没拿到官方格式信息，暂时无法切换。请稍后重试。"
            return
        }
        guard info.canSwitch, info.current != newFormat else {
            formatMessage = "官方没有提供可切换的另一种格式。纯 PDF 无法在本机生成文本版。"
            return
        }
        guard !formatBusy else { return }
        formatBusy = true
        formatMessage = nil
        defer { formatBusy = false }

        let bookId = target.book.id
        var chapterUid = current?.uid ?? 0
        var offset = max(scrollOffset, 0)
        if !isPDF, offset <= 0, scrollFraction > 0.001, let chapter = current {
            offset = Int(Double(max(chapter.wordCount, 1)) * scrollFraction)
        }
        // PDF 画布没有原生章节目录，切换位置以官方同步的阅读进度为准。
        if isPDF || chapterUid <= 0 {
            if let progress = await store.progress(for: bookId) {
                chapterUid = progress.chapterUid
                offset = progress.chapterOffset
            }
        }
        // 官方只要求回包的 `chapterUid >= 0`，请求侧没有进度时也照样
        // 发 `uid = 0`，由服务端决定切到哪一章；不要在本机提前判死。

        do {
            let service = WereadService.shared
            let result = try await service.switchBookFormat(
                bookId: bookId,
                to: newFormat,
                chapterUid: chapterUid,
                offset: offset,
                cookie: store.cookie
            )
            formatInfo = info.switching(to: newFormat)
            if newFormat == .pdf {
                webURLOverride = service.readerURLString(
                    bookId: bookId,
                    chapterUid: result.chapterUid,
                    jumpType: "switchFormat",
                    offset: result.chapterOffset
                )
                pdfZoomScale = 1
                isPDF = true
                showWeb = true
            } else {
                webURLOverride = nil
                showWeb = false
                isPDF = false
                pdfZoomScale = 1
                await load(force: true, restore: result)
            }
        } catch {
            formatMessage =
                "切换失败：\(error.localizedDescription)\n" +
                "只有官方已提供另一种格式且有阅读权益的书才能切换；" +
                "纯 PDF 不会在本机生成文本层。"
        }
    }

    /// 普通电子书首开不等格式详情，后台补一次；拿到双格式信息后才
    /// 显示 EPUB → PDF 入口。
    @MainActor
    private func refreshFormatInfo(bookId: String) async {
        let fetched = await WereadService.shared.bookFormat(
            bookId: bookId,
            cookie: store.cookie
        )
        guard let fetched, formatInfo == nil else { return }
        formatInfo = fetched
        // 书架没标记、但详情确认是 PDF 的书：后台拿到结果后转 PDF 画布，
        // 不能让正文接口返回空 HTML 后停在白屏。
        if fetched.current == .pdf, !isPDF {
            loadToken += 1
            notesToken += 1
            loading = false
            errorMessage = nil
            isPDF = true
            showWeb = true
        }
    }

    @MainActor
    private func load(
        force: Bool = false,
        restore: WereadFormatSwitchResult? = nil
    ) async {
        if !force, !chapters.isEmpty { return }
        let service = WereadService.shared
        let bookId = target.book.id
        // 只有已标记为 PDF 的书才在首开阻塞等 `/web/book/info`。普通
        // 电子书的首开不能被一个可选入口拖慢一次网络往返。
        let pdfMarker = service.isPDFBook(id: bookId)
        var format = service.bookFormatIfCached(bookId: bookId)
        if pdfMarker || format?.current == .pdf {
            format = await service.bookFormat(
                bookId: bookId,
                cookie: store.cookie
            ) ?? format
        } else if format == nil {
            Task { await refreshFormatInfo(bookId: bookId) }
        }
        formatInfo = format
        let isPDFNow =
            format?.current == .pdf
            || (format?.current != .epub && pdfMarker)
        if isPDFNow {
            loadToken += 1
            notesToken += 1
            chapters = []
            html = ""
            cache = [:]
            cacheOrder = []
            highlights = [:]
            serverNotes = [:]
            serverNotesLoaded = false
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
            serverNotesLoaded = false
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
            // 旧本机划线迁移不挡正文：等云端索引可用后再在后台补一次。
            Task { await migrateLegacyHighlightsIfNeeded() }

            var start = 0
            // 续读位置：章由 chapterUid 定位，章内位置优先用字符偏移。
            // 以前只把 offset 换成比例、比例又依赖 wordCount，wordCount 为 0
            // 时会直接算成 1.0 跳到章尾；这里把 offset 原样交给 WebView，
            // 由 JS 按正文文本长度定位，比例只做兜底（见 restoreOffset）。
            var resumeOffset = 0
            var resumeFraction: Double = 0
            let progress = await progressTask
            if let restore, restore.chapterUid >= 0,
               let position = list.firstIndex(where: { $0.uid == restore.chapterUid })
            {
                start = position
                resumeOffset = restore.chapterOffset
            } else if let progress {
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
            serverNotesLoaded = true
            notesError = nil
            notesLoading = false
            // 云端索引到手后再迁移旧本机数据，避免把云端已有的笔记重复上传。
            await migrateLegacyHighlightsIfNeeded()
        } catch {
            guard token == notesToken else { return }
            notesLoading = false
            notesError = error.localizedDescription
        }
    }

    /// 编辑 / 删除后重新拉全书划线和「我的想法」索引，供列表与核对使用。
    @MainActor
    private func refreshNotes() async {
        notesToken += 1
        let token = notesToken
        notesError = nil
        await loadBookmarks(bookId: target.book.id, token: token)
        await loadOwnReviews()
    }

    /// 旧版本把划线和想法写在 UserDefaults。6S 存储硬约束下不再新增落盘，
    /// 但也不能静默丢弃：每本书首次打开时读一次旧 key，逐条对照云端补传；
    /// 只有整章都确认在云端（或上传成功）后才删除该章旧 key。缺 range、
    /// 未登录、网络或想法索引失败时原样保留，下次打开继续尝试。
    @MainActor
    private func migrateLegacyHighlightsIfNeeded() async {
        guard !legacyMigrationStarted else { return }
        guard !chapters.isEmpty, serverNotesLoaded else { return }
        let bookId = target.book.id
        guard !bookId.isEmpty else { return }

        let cookie = store.cookie
        guard !cookie.isEmpty else {
            let line = "旧划线迁移跳过 book=\(bookId) 未登录，旧数据保留"
            WereadService.screenDiag(line)
            FlareDiagnostics.shared.record(.weread, "WARN", line)
            return
        }
        legacyMigrationStarted = true

        var pending: [(chapter: WereadChapter, highlights: [WereadHighlight])] = []
        // 按目录逐章查旧 key，不再整份 `dictionaryRepresentation()` 拷贝；
        // 6S 上章节多时也更省内存。
        for chapter in chapters {
            let legacy = WereadLegacyHighlightStore.load(
                bookId: bookId,
                chapterUid: chapter.uid
            )
            guard !legacy.isEmpty else { continue }
            pending.append((chapter, legacy))
        }
        guard !pending.isEmpty else { return }

        // 想法只在能确认云端索引时迁移；否则可能把已有想法重复上传。
        let needsReviewIndex = pending.contains { entry in
            entry.highlights.contains { item in
                !normalizedText(item.note).isEmpty
                    && !legacyItemIsInServerNotes(item, chapterUid: entry.chapter.uid)
            }
        }
        var reviews: [WereadOwnReview]? = nil
        if needsReviewIndex {
            reviews = await WereadService.shared.ownReviews(
                bookId: bookId,
                cookie: cookie
            )
        }

        var uploaded = 0
        var kept = 0
        for entry in pending {
            var allSynced = true
            for item in entry.highlights {
                if legacyItemIsInServerNotes(item, chapterUid: entry.chapter.uid) {
                    continue
                }
                if !normalizedText(item.note).isEmpty {
                    guard let reviews else {
                        // 想法索引没拿到，无法判断云端是否已有，保留旧 key。
                        allSynced = false
                        kept += 1
                        continue
                    }
                    if legacyItemIsInReviews(
                        item,
                        chapterUid: entry.chapter.uid,
                        reviews: reviews
                    ) {
                        continue
                    }
                }
                let ok = await WereadService.shared.uploadHighlight(
                    bookId: bookId,
                    chapterUid: entry.chapter.uid,
                    chapterIdx: entry.chapter.index,
                    range: item.range ?? "",
                    markText: item.text,
                    note: item.note,
                    cookie: cookie
                )
                if ok {
                    uploaded += 1
                } else {
                    allSynced = false
                    kept += 1
                }
            }
            if allSynced {
                WereadLegacyHighlightStore.remove(
                    bookId: bookId,
                    chapterUid: entry.chapter.uid
                )
            }
        }

        let line =
            "旧划线迁移 book=\(bookId) chapters=\(pending.count) " +
            "uploaded=\(uploaded) 保留=\(kept)"
        WereadService.screenDiag(line)
        FlareDiagnostics.shared.record(.weread, kept == 0 ? "RES" : "WARN", line)
        if uploaded > 0 {
            await refreshNotes()
        }
    }

    /// 旧镜像条目是否已经能从云端划线索引里对上。
    private func legacyItemIsInServerNotes(
        _ item: WereadHighlight,
        chapterUid: Int
    ) -> Bool {
        let text = normalizedText(item.text)
        let note = normalizedText(item.note)
        let range = (item.range ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !note.isEmpty else { return false }
        return (serverNotes[chapterUid] ?? []).contains { bookmark in
            let sameRange = !range.isEmpty && bookmark.range == range
            let sameText = !text.isEmpty && normalizedText(bookmark.markText) == text
            guard sameRange || sameText else { return false }
            guard !note.isEmpty else { return true }
            let cloudNote = normalizedText(bookmark.note)
            return !cloudNote.isEmpty && (cloudNote == note || cloudNote.contains(note))
        }
    }

    /// 旧镜像里的想法是否已经在云端「我的想法」索引里。
    ///
    /// 同一位置只要云端已有想法就算迁移过：本机镜像可能是上传时的旧稿，
    /// 用户后来在官方端改过，这时应保留云端版本，不能拿旧稿再传一条。
    private func legacyItemIsInReviews(
        _ item: WereadHighlight,
        chapterUid: Int,
        reviews: [WereadOwnReview]
    ) -> Bool {
        let text = normalizedText(item.text)
        let note = normalizedText(item.note)
        let range = (item.range ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return true }
        return reviews.contains { review in
            guard review.chapterUid == chapterUid else { return false }
            let sameRange = !range.isEmpty && review.range == range
            let sameText = !text.isEmpty && normalizedText(review.abstract) == text
            let sameContent = normalizedText(review.content) == note
            return sameRange || sameText || sameContent
        }
    }

    @MainActor
    private func reloadChapter() async {
        guard let current else { return }
        // 重载有可能发生在弱网下：先把上一段时长取成快照再后台上报，
        // 不能像以前那样在 loadChapter 里 await 网络，点一下要等十几秒。
        let leaveToken = loadToken
        let timeReport = makeReadingTimeReport()
        stopReadingTimer()
        if let timeReport {
            _ = enqueueReadingTime(
                timeReport,
                token: leaveToken,
                fallback: nil
            )
        }
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
        // 翻章进行中（含正文还没排版完）不接第二次点击，避免连点排出一串
        // 网络请求；按钮同时会显示为禁用态。
        guard !loading else { return }
        // 先落本机并快照旧章位置 / 时长。下面会立刻切 index，之后不能再
        // 回头读 `current` 和 `scrollOffset`，所以这两个快照必须在这里取。
        let fallback = persistLocalProgress()
        let timeReport = makeReadingTimeReport()
        let leaveToken = loadToken
        stopReadingTimer()

        // 在 `loadToken` 进到下一章前**同步入队**，旧章请求因此一定排在
        // 新章请求之前；真正的切章只等本地状态准备和正文请求，不等网络。
        if let timeReport {
            let queued = enqueueReadingTime(
                timeReport,
                token: leaveToken,
                fallback: fallback
            )
            if !queued, let fallback {
                reportLegacyProgress(fallback, token: leaveToken)
            }
        } else if let fallback {
            reportLegacyProgress(fallback, token: leaveToken)
        }

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
    /// 打开笔记面板。能按文字对上一条笔记时只记诊断，面板里可直接看。
    private func handleAnnotationLink(_ text: String, href: String = "") {
        let link = href.isEmpty ? "-" : String(href.prefix(120))
        let key = normalizedText(text)
        let matched = !key.isEmpty && cloudNoteEntries.contains {
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
        // 时长上报已由调用方在切 index 前取好快照、放到后台发送。
        // 这里不再 await 网络，否则弱网下按钮会像「按不动」。
        stopReadingTimer()
        readingFlushAnchor = nil
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
        // 新章还没回报译文节点数，菜单不能拿上一章的数字当真。
        translationNodeCount = -1

        let chapter = chapters[position]
        if highlights[chapter.uid] == nil {
            // 旧本机镜像只读兼容：能迁移的会在 `migrateLegacyHighlightsIfNeeded`
            // 上传云端后删掉旧 key，这里不再新增任何落盘。
            highlights[chapter.uid] = WereadLegacyHighlightStore.load(
                bookId: target.book.id,
                chapterUid: chapter.uid
            )
        }
        if !translationOn, let cached = cache[chapter.uid] {
            html = cached
            await waitForRender(token: token)
            restoreScrollIfNeeded(token: token)
            if token == loadToken {
                chapterReady = true
                startReadingTimer()
            }
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
            if token == loadToken {
                chapterReady = true
                startReadingTimer()
            }
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
        // 双语译文会让一章 HTML 接近翻倍；翻译开启期间一律不进缓存，
        // 避免 6S 的内存被「原文 + 译文 + 预取」顶满。
        guard !translationOn else { return }
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
        // 这里不再回写本机：恢复目标要么刚从本机读出，要么刚由
        // `progress(for:)` 把服务端进度 remember 下来，缓存已经是它；
        // 再用当前时间写一遍只会抬高 savedAt，压过后来的官方进度。
        // 之后的位置落盘统一走 onScroll / persistLocalProgress。
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
        guard !translationOn else { return }
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

    // MARK: - 翻译（实验）

    /// 译文由官方随章节正文返回，Swift 侧只切 CSS 显隐并统计节点数。
    /// 没有本地机翻、没有译文落盘/日志正文，也没有新增缓存。
    @MainActor
    private func startTranslation() {
        translationTask?.cancel()
        translationTask = Task { await enableTranslation() }
    }

    @MainActor
    private func startCancellingTranslation() {
        translationTask?.cancel()
        translationTask = Task { await cancelTranslation() }
    }

    @MainActor
    private func enableTranslation() async {
        guard !translationBusy else { return }
        translationBusy = true
        defer { translationBusy = false }
        translationMessage = nil
        translationStatus = "正在开启官方翻译…"
        translationNodeCount = -1

        let cookie = store.cookie
        guard !cookie.isEmpty else {
            translationStatus = nil
            translationMessage = "未登录微信读书，请先在微读页重新扫码登录。"
            return
        }

        var warning: String?
        do {
            let ack = try await WereadService.shared.setTranslation(
                bookId: target.book.id,
                enabled: true,
                cookie: cookie
            )
            switch ack {
            case .accepted:
                break
            case .uncertain(let message):
                warning = message
            case .rejected(let message):
                translationStatus = nil
                translationMessage = message
                return
            }
        } catch is CancellationError {
            translationStatus = nil
            return
        } catch {
            guard !Task.isCancelled else {
                translationStatus = nil
                return
            }
            translationStatus = nil
            translationMessage = "开启翻译失败：\(error.localizedDescription)"
            return
        }

        // 官方开关已经发出去。先按「可能产生双倍正文」处理：
        // 清缓存，翻译期间不写缓存、不预取。
        translationOn = true
        translationVisible = false
        cache = [:]
        cacheOrder = []

        guard let chapter = current else {
            translationStatus = nil
            translationMessage = warning ?? "当前章节还没就绪，已开启翻译；翻到正文后再试。"
            return
        }

        var tip: String?
        var pollNote: String?
        // 未翻译章节的官方原版本是 0；发送版本也从章节真实版本开始，
        // 之后只跟回包/curStatus 的新版本递增，绝不用 1 冒充已持有译文。
        let chapterVersion = chapter.translateVersion
        var version = chapterVersion
        var completed = false
        // 官方每 2 秒轮询一次；给生成留 90 秒，超时后仍然重载数节点，
        // 节点为 0 就如实报失败，不把「轮询次数用完」当成完成。
        let deadline = Date().addingTimeInterval(90)
        do {
            var attempt = 0
            while Date() < deadline {
                try Task.checkCancellation()
                attempt += 1
                translationStatus = "官方正在生成译文（第 \(attempt) 次）…"
                let trigger = try await WereadService.shared.requestTranslation(
                    bookId: target.book.id,
                    uid: chapter.uid,
                    chapterVersion: chapterVersion,
                    translateVersion: version,
                    cookie: cookie
                )
                tip = trigger.tip ?? tip
                if let next = trigger.translateVersion, next > version {
                    version = next
                }
                if trigger.state == .completed {
                    completed = true
                    break
                }
                if trigger.state == .stop {
                    pollNote = "官方已停止轮询，但回包未确认译文已生成。"
                    break
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if !completed, Date() >= deadline {
                pollNote = "官方译文生成超过 90 秒仍未完成（轮询超时）。"
            }
        } catch is CancellationError {
            translationStatus = nil
            return
        } catch {
            guard !Task.isCancelled else {
                translationStatus = nil
                return
            }
            pollNote = "触发译文生成失败：\(error.localizedDescription)"
        }
        guard !Task.isCancelled else {
            translationStatus = nil
            return
        }

        translationStatus = "正在读取官方译文…"
        let count = await reloadForTranslation()
        guard !Task.isCancelled else {
            translationStatus = nil
            return
        }
        var lines: [String] = []
        if let warning { lines.append(warning) }
        if let pollNote { lines.append(pollNote) }
        if let tip, !tip.isEmpty { lines.append("官方提示：\(tip)") }
        if count > 0 {
            translationVisible = true
            translationStatus = nil
            return
        }

        // 节点数为 0 就是失败：不把「请求已发出」冒充成「已取到译文」。
        translationStatus = "正在核对失败原因…"
        if let member = await WereadService.shared.memberCardStatus(cookie: cookie) {
            lines.append(
                member
                    ? "会员摘要显示有会员记录，但本书/本章仍未返回译文。"
                    : "会员摘要未显示会员记录；本功能不据此拦截，仅作提示。"
            )
        }
        lines.append(
            "官方未返回译文（本章 .wr-translation 节点为 0）。"
                + "可能原因：本书/本章不支持翻译、账号没有对应权益，或请求被风控。"
                + "未使用本地机翻替代。"
        )
        translationMessage = lines.joined(separator: "\n")
        translationStatus = nil
    }

    @MainActor
    private func cancelTranslation() async {
        translationVisible = false
        translationBusy = true
        translationStatus = "正在关闭官方翻译…"
        translationMessage = nil
        defer { translationBusy = false }

        let cookie = store.cookie
        guard !cookie.isEmpty else {
            translationStatus = nil
            translationMessage = "未登录微信读书，无法确认关闭官方翻译；本页译文已隐藏。"
            return
        }

        do {
            let ack = try await WereadService.shared.setTranslation(
                bookId: target.book.id,
                enabled: false,
                cookie: cookie
            )
            switch ack {
            case .accepted:
                // 只有官方明确接受才恢复缓存/预取，并重载回不带译文的正文。
                translationOn = false
                translationStatus = "正在恢复原文…"
                let count = await reloadForTranslation()
                guard !Task.isCancelled else {
                    translationStatus = nil
                    return
                }
                translationNodeCount = count
            case .uncertain(let message):
                translationMessage = message
                    + "\n译文已隐藏，翻译期间仍不缓存章节；可再试一次或到网页版关闭。"
            case .rejected(let message):
                translationMessage = message
                    + "\n译文已隐藏，但官方可能仍在开启翻译。"
            }
        } catch is CancellationError {
            translationStatus = nil
            return
        } catch {
            guard !Task.isCancelled else {
                translationStatus = nil
                return
            }
            translationMessage = "关闭翻译失败：\(error.localizedDescription)"
                + "\n译文已隐藏，但官方可能仍在开启翻译。"
        }
        translationStatus = nil
    }

    @MainActor
    private func showTranslation() {
        guard translationNodeCount > 0 else {
            translationMessage = translationNodeCount < 0
                ? "还没收到本页译文状态，请稍后再试。"
                : "当前章节没有官方译文节点。请先开启自动翻译，或换一本支持翻译的外语书。"
            return
        }
        translationVisible = true
    }

    /// 重载当前章并等 WebView 回报译文节点数。翻译期间
    /// `rememberInCache` 会拒绝写入，双倍 HTML 不会留在内存缓存里。
    @MainActor
    private func reloadForTranslation() async -> Int {
        guard let chapter = current else { return 0 }
        let offset = scrollOffset
        let fraction = scrollFraction
        // 重载同一章也会走 loadChapter 的 stopReadingTimer/清 anchor；
        // 先把这段前台时长并进 pending，避免白丢最多 30 秒。
        _ = peekReadingSeconds()
        cache[chapter.uid] = nil
        cacheOrder.removeAll { $0 == chapter.uid }
        translationNodeCount = -1
        restoreOffset = offset
        restoreFraction = fraction
        loadToken += 1
        await loadChapter(at: index, token: loadToken)
        return await waitForTranslationCount()
    }

    @MainActor
    private func waitForTranslationCount() async -> Int {
        for _ in 0..<50 {
            if Task.isCancelled { break }
            if translationNodeCount >= 0 { return translationNodeCount }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return max(translationNodeCount, 0)
    }

    /// 把从锚点到现在的秒数记进 `pendingReadingSeconds`，但不扣减。
    /// 单次最多报 60 秒，多出的留给后面的上报。
    @MainActor
    private func peekReadingSeconds() -> Int {
        if let anchor = readingFlushAnchor {
            let now = Date()
            let seconds = Int(now.timeIntervalSince(anchor))
            if seconds > 0 {
                readingFlushAnchor = now
                pendingReadingSeconds += seconds
            }
        }
        return min(max(pendingReadingSeconds, 0), 60)
    }

    /// 服务端确认收到后才扣掉这一段；失败时保留，下一轮原样重发。
    @MainActor
    private func consumeReadingSeconds(_ rt: Int) {
        pendingReadingSeconds = max(pendingReadingSeconds - rt, 0)
    }

    /// 把当前章待报的时长取成快照；必须在切 index / 清滚动之前调用。
    ///
    /// 快照里的章、位置、秒数都是取的那一刻的值，后台网络期间视图可以继续
    /// 换章，不会再读错章节。未登录时清掉累计秒数，避免登录后补报离线时长。
    @MainActor
    private func makeReadingTimeReport() -> WereadReadingTimeReport? {
        // 已有一条时长上报在队列里等待或正在发送时，pending 还没扣减；
        // 再取一次快照会把同一段秒数重复入队。
        guard !readingFlushInFlight else { return nil }
        guard !isPDF, chapterReady, let chapter = current, chapter.uid > 0 else {
            return nil
        }
        guard !store.cookie.isEmpty else {
            readingFlushAnchor = Date()
            pendingReadingSeconds = 0
            return nil
        }
        let rt = peekReadingSeconds()
        guard rt > 0 else { return nil }
        var offset = max(scrollOffset, 0)
        if offset <= 0, scrollFraction > 0.001 {
            offset = Int(Double(max(chapter.wordCount, 1)) * scrollFraction)
        }
        return WereadReadingTimeReport(
            bookId: target.book.id,
            chapterUid: chapter.uid,
            chapterIndex: chapter.index,
            offset: offset,
            percent: Int((scrollFraction * 100).rounded()),
            rt: rt
        )
    }

    /// 把快照发出去。调用方必须已经把它排进统一上报队列。
    @MainActor
    @discardableResult
    private func sendReadingTime(
        _ report: WereadReadingTimeReport
    ) async -> WereadReadReportOutcome {
        let outcome = await store.report(
            bookId: report.bookId,
            chapterUid: report.chapterUid,
            offset: report.offset,
            chapterIndex: report.chapterIndex,
            percent: report.percent,
            rt: report.rt,
            // 快照不是当前视图：只发网络，绝不回写本机。
            cacheLocal: false
        )
        switch outcome {
        case .accepted:
            consumeReadingSeconds(report.rt)
        case .uncertain:
            // 官方成功回调就是 2xx `{}`（诊断实测 200·2B·{}）。按「已发送」
            // 扣掉这段，避免每 30 秒重复累加；但它没有 succ/errCode，
            // 只能标成未确认，真机再看阅读时长是否增加。
            consumeReadingSeconds(report.rt)
            WereadService.screenDiag(
                "阅读时长未确认（2xx {}），不重复发也未宣称已计入 rt=\(report.rt)"
            )
        case .missingToken, .failed, .rejected:
            // peek 没扣减，pending 原样保留；调用方继续发旧进度兜底。
            break
        }
        return outcome
    }

    /// 把阅读时长快照追加到统一串行队列。
    ///
    /// `fallback` 只在这个任务里、且时长没有明确 accepted 时才补发，因此
    /// 时长与旧进度天然一前一后，不会另起一条并发请求。已有上报在队列中
    /// 时返回 false，调用方可以把 fallback 单独入队（仍排在它后面）。
    @MainActor
    @discardableResult
    private func enqueueReadingTime(
        _ report: WereadReadingTimeReport,
        token: Int,
        fallback: WereadProgressReport? = nil
    ) -> Bool {
        guard !readingFlushInFlight else { return false }
        readingFlushInFlight = true
        let queued = enqueueReadReport(token: token, label: "阅读时长") {
            defer { readingFlushInFlight = false }
            let outcome = await sendReadingTime(report)
            if case .accepted = outcome { return }
            if let fallback {
                await postLegacyProgress(fallback)
            }
        }
        if !queued {
            readingFlushInFlight = false
        }
        return queued
    }

    /// 把累计的前台阅读时长追加到串行队列。
    @MainActor
    private func flushReadingTime() {
        guard let report = makeReadingTimeReport() else { return }
        _ = enqueueReadingTime(report, token: loadToken)
    }

    /// 所有 `/web/book/read` 的唯一入口：先验代次，再按调用顺序串行执行。
    ///
    /// 入队发生在 MainActor 上，因此旧章后台任务若在换章后才醒来，会因
    /// `token != loadToken` 在这里被丢弃；已经排在前面的旧章请求则一定在
    /// 新章请求之前完整结束。
    @MainActor
    @discardableResult
    private func enqueueReadReport(
        token: Int,
        label: String,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard token == loadToken else {
            WereadService.screenDiag(
                "\(label)丢弃过期代次 token=\(token) current=\(loadToken)"
            )
            return false
        }
        let previous = reportTail
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        reportTail = next
        return true
    }

    /// 前台每 30 秒上报一次阅读时长；切后台、翻章、退出都会先 flush。
    @MainActor
    private func startReadingTimer() {
        if let existing = readingTimer, !existing.isCancelled { return }
        readingTimer = nil
        guard !isPDF, !showWeb, chapterReady, scenePhase == .active,
              let chapter = current, chapter.uid > 0,
              !store.cookie.isEmpty
        else { return }
        readingFlushAnchor = Date()
        readingTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                guard scenePhase == .active, !showWeb, chapterReady, !isPDF else { continue }
                flushReadingTime()
            }
        }
    }

    private func stopReadingTimer() {
        readingTimer?.cancel()
        readingTimer = nil
    }

    /// 把当前章的位置取成快照，供异步上报使用。
    @MainActor
    private func progressReport() -> WereadProgressReport? {
        guard chapterReady, hasReadingPosition, let current else { return nil }
        var offset = scrollOffset
        if offset <= 0, scrollFraction > 0.001 {
            offset = Int(Double(max(current.wordCount, 1)) * scrollFraction)
        }
        return WereadProgressReport(
            bookId: target.book.id,
            chapterUid: current.uid,
            chapterIndex: current.index,
            offset: max(offset, 0),
            percent: Int((scrollFraction * 100).rounded())
        )
    }

    /// 把进度兜底追加到统一串行队列；不再允许旧章在换章后补发。
    @MainActor
    @discardableResult
    private func reportLegacyProgress(
        _ report: WereadProgressReport,
        token: Int
    ) -> Bool {
        enqueueReadReport(token: token, label: "进度保存") {
            await postLegacyProgress(report)
        }
    }

    @MainActor
    private func postLegacyProgress(_ report: WereadProgressReport) async {
        WereadService.screenDiag(
            "进度保存 book=\(report.bookId) chapter=\(report.chapterUid) offset=\(report.offset) percent=\(report.percent)"
        )
        _ = await store.report(
            bookId: report.bookId,
            chapterUid: report.chapterUid,
            offset: report.offset,
            chapterIndex: report.chapterIndex,
            percent: report.percent,
            // 兜底上报的是快照，不是当前视图：只发网络，绝不回写本机。
            cacheLocal: false
        )
    }

    /// 只把当前阅读位置同步落本机，不发网络。
    ///
    /// 退出/切后台时系统可能在网络 `await` 期间就挂起进程，所以必须先落盘；
    /// 返回值是这次快照，供调用方在异步上报里继续兜底，避免网络期间翻章
    /// 后把旧位置写进新章。
    @MainActor
    @discardableResult
    private func persistLocalProgress() -> WereadProgressReport? {
        guard let report = progressReport() else { return nil }
        store.cacheProgress(
            bookId: report.bookId,
            chapterUid: report.chapterUid,
            offset: report.offset,
            percent: report.percent
        )
        return report
    }

    @MainActor
    private func saveProgress() async {
        // 先落本机：后面的 flush 要等 getConfig / 阅读器页 / POST，
        // 切后台或退出时不能保证 await 之后还有机会写 UserDefaults。
        let token = loadToken
        let snapshot = persistLocalProgress()
        // 有时长就把快照和兜底放进同一个队列任务；没有时长或已有上报
        // 在队列中时，兜底也单独入队，绝不绕过串行链直接发。
        if let timeReport = makeReadingTimeReport() {
            let queued = enqueueReadingTime(
                timeReport,
                token: token,
                fallback: snapshot
            )
            if !queued, let snapshot {
                reportLegacyProgress(snapshot, token: token)
            }
        } else if let snapshot {
            reportLegacyProgress(snapshot, token: token)
        }
    }
}

/// 翻章按钮的按压反馈：即时轻微缩小，不做动画。
private struct PageTurnButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: - 划线 / 想法

struct WereadHighlight: Codable, Hashable, Identifiable {
    let id: String
    let text: String
    let note: String
    /// 章内文本偏移 `start-end`，用于回传服务端划线 / 想法。
    /// 官方按自己的渲染对象算 offset，这里用 DOM 文本长度近似，位置可能有偏差，
    /// 需真机校准。旧版本本机镜像里没有这个字段，Optional 解码会得到 nil。
    let range: String?

    init(id: String, text: String, note: String, range: String? = nil) {
        self.id = id
        self.text = text
        self.note = note
        self.range = range
    }
}

/// 笔记面板里的一条**服务端**笔记。只由 `serverNotes` / `ownReviews`
/// 构造，不读也不写 UserDefaults；6S 存储硬约束下笔记只留云端。
private struct WereadCloudNote: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case thought
        case highlight

        var title: String {
            switch self {
            case .thought: return "想法"
            case .highlight: return "划线"
            }
        }
    }

    let id: String
    let chapterUid: Int
    let chapterIndex: Int
    let chapterTitle: String
    let text: String
    let note: String
    let range: String
    let createTime: TimeInterval
    let kind: Kind
    let bookmarkId: String?
    let reviewId: String?
}

/// 旧版本把划线和想法写在 `UserDefaults`。6S 存储硬约束下不再新增落盘：
/// 这里只保留「读一次旧数据 + 迁移成功后删除旧 key」的能力，**不再提供写回**。
/// 迁移失败的旧数据原样留在本机，下次打开这本书继续尝试，不静默丢弃。
enum WereadLegacyHighlightStore {
    private static let prefix = "weread.highlights."

    private static func key(bookId: String, chapterUid: Int) -> String {
        "\(prefix)\(bookId).\(chapterUid)"
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

    /// 迁移确认云端已有后清理旧 key。这是本类型唯一的写操作，且只删不写笔记。
    static func remove(bookId: String, chapterUid: Int) {
        UserDefaults.standard.removeObject(forKey: key(bookId: bookId, chapterUid: chapterUid))
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
    /// 编辑云端条目时必须带上条目自己的章节，不能读当前阅读章。
    var chapterUid: Int = 0
    var chapterIdx: Int = 0
    /// 编辑已有想法；否则是给划线补想法（或新建）。
    var isEditing: Bool = false
}

/// 上报进度用的位置快照。退出/翻章后视图状态会变，异步任务不能回头再读。
private struct WereadProgressReport: Sendable {
    let bookId: String
    let chapterUid: Int
    let chapterIndex: Int
    let offset: Int
    let percent: Int
}

/// 离开当前章时的阅读时长快照。取完后视图可以立刻切到下一章，
/// 后台只用这份值上报，不再读 `current` / `scrollOffset`。
private struct WereadReadingTimeReport: Sendable {
    let bookId: String
    let chapterUid: Int
    let chapterIndex: Int
    let offset: Int
    let percent: Int
    let rt: Int
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

/// 章节正文用的 WKWebView。
///
/// 长按选中文字时，UIKit 会额外弹一个系统编辑菜单（iOS 15 是
/// `UIMenuController`，iOS 16+ 是 `UIEditMenuInteraction`）。它在独立的
/// 系统窗口里，层级高于整个 WKWebView，网页里的 `z-index` 再大也压不住，
/// 正好盖住网页自己的「划线 / 想法」工具条，导致按钮看得见却点不到。
///
/// 这里只在「正文有选区且 `#wr-tools` 已显示、焦点不在输入框」时暂时收起
/// 系统编辑菜单；其余状态仍交给系统，保留正文的拷贝 / 查询等能力，也不影响
/// 写想法浮层里的 SwiftUI `TextEditor`。
private final class WereadChapterWKWebView: WKWebView {
    /// 网页工具条是否已显示（由 JS 上报）。
    private var selectionToolsVisible = false
    /// 工具条仍在使用的正文选区（点工具条时选区可能临时收成光标）。
    private var bodyHasSelection = false

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        observeEditMenu()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeEditMenu()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// JS 上报工具条显示状态和正文选区状态。
    func updateSelectionTools(visible: Bool, hasSelection: Bool) {
        selectionToolsVisible = visible
        bodyHasSelection = hasSelection
        hideSystemEditMenuIfNeeded()
    }

    private func observeEditMenu() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleEditMenuWillShow(_:)),
            name: UIMenuController.willShowMenuNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleEditMenuDidShow(_:)),
            name: UIMenuController.didShowMenuNotification,
            object: nil
        )
    }

    @objc private func handleEditMenuWillShow(_ notification: Notification) {
        hideSystemEditMenuIfNeeded()
    }

    @objc private func handleEditMenuDidShow(_ notification: Notification) {
        hideSystemEditMenuIfNeeded()
    }

    /// 系统发完通知后还会再摆一次菜单：先同步收，再补一轮异步。
    private func hideSystemEditMenuIfNeeded() {
        guard shouldSuppressSystemEditMenu else { return }
        UIMenuController.shared.setMenuVisible(false, animated: false)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.shouldSuppressSystemEditMenu else { return }
            UIMenuController.shared.setMenuVisible(false, animated: false)
        }
    }

    /// 只有「正文选区 + 工具条可见 + 当前焦点不在输入框」才拦截系统菜单。
    private var shouldSuppressSystemEditMenu: Bool {
        guard selectionToolsVisible, bodyHasSelection, window != nil else { return false }
        guard let responder = currentFirstResponder() else { return false }
        // 写想法浮层里的 SwiftUI TextEditor 或网页输入框拿焦点时放行。
        if responder is UITextView || responder is UITextField { return false }
        guard let view = responder as? UIView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    private func currentFirstResponder() -> UIResponder? {
        guard let window = window else { return nil }
        return Self.firstResponder(in: window)
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) { return responder }
        }
        return nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if shouldSuppressSystemEditMenu { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// iOS 16+ 的标准编辑菜单走 UIMenuBuilder，不走 canPerformAction；
    /// 只在拦截状态下临时移除，工具条收起后仍保留系统菜单。
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard shouldSuppressSystemEditMenu else { return }
        if #available(iOS 16.0, *) {
            if builder.menu(for: .standardEdit) != nil {
                builder.remove(menu: .standardEdit)
            }
        }
    }
}

private struct WereadChapterWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    let cookie: String
    /// 正文字号（px）。只改页面 CSS 变量，不缩放 WKWebView。
    let fontSize: CGFloat
    /// 官方译文默认隐藏，打开时只切 CSS class；译文文本始终留在 DOM 里。
    let translationVisible: Bool
    let highlights: [WereadHighlight]
    let onHighlight: (WereadHighlight) -> Void
    let onScroll: (Double, Int) -> Void
    /// 章节内相对链接（epub/azw3 的 partNNNN.html#...）被点击。
    /// 参数是原始 href 和链接文字，由 Swift 侧对回目录再跳章。
    let onChapterLink: (String, String) -> Void
    /// 正文里批注/想法/高亮的蓝色可点元素被点击。
    /// 参数是原始 href 和元素文字，由 Swift 侧打开笔记面板。
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
    /// 本次页面 `.wr-translation` 节点数；0 表示官方没给译文。
    let onTranslationCount: (Int) -> Void

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

        let webView = WereadChapterWKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 字号放大后正文只纵向重排，禁止任何横向弹性滚动。
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.showsHorizontalScrollIndicator = false
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
        context.coordinator.applyFontSize(fontSize, in: webView)
        context.coordinator.applyTranslation(translationVisible, in: webView)
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
        private var lastFontSize: CGFloat?
        private var lastTranslationVisible: Bool?
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
            lastFontSize = nil
            lastTranslationVisible = nil
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
                // 先按当前字号重排，再执行挂起的续读滚动，落点才是最终排版。
                // 这时续读位置还没恢复，用 silent 只排版，不锚定也不上报，
                // 否则会把刚恢复的滚动状态冲成章首。
                applyFontSize(parent.fontSize, in: webView, silent: true)
                applyTranslation(parent.translationVisible, in: webView)
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

        /// 应用正文字号。页面还没 ready 时先跳过，等 `markReady` 再补；
        /// 值没变化时不重复 evaluate，避免无谓的整页重排。
        func applyFontSize(
            _ size: CGFloat,
            in webView: WKWebView,
            silent: Bool = false
        ) {
            guard loaded else { return }
            let clamped = min(
                max(size, WereadFontSize.minimum),
                WereadFontSize.maximum
            )
            guard lastFontSize != clamped else { return }
            lastFontSize = clamped
            let px = Int(clamped.rounded())
            let silentArg = silent ? "true" : "false"
            webView.evaluateJavaScript(
                "window.__wrSetFont(\(px), \(silentArg));"
            ) { _, error in
                guard let error = error else { return }
                // 脚本尚未装好时下次页面更新还可以重试，不能把失败值记成已应用。
                self.lastFontSize = nil
                Self.log.error(
                    "weread apply font size failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        /// 只切页面的译文显隐 class，并回报节点数；不把译文文本带回 Swift。
        func applyTranslation(_ visible: Bool, in webView: WKWebView) {
            guard loaded else { return }
            guard lastTranslationVisible != visible else { return }
            lastTranslationVisible = visible
            let value = visible ? "true" : "false"
            webView.evaluateJavaScript(
                "window.__wrSetTranslation(\(value));"
            ) { result, error in
                if let error = error {
                    // 脚本没装好时下次更新还能重试，不能把失败值记成已应用。
                    self.lastTranslationVisible = nil
                    Self.log.error(
                        "weread apply translation failed: \(String(describing: error), privacy: .public)"
                    )
                    return
                }
                let count = (result as? NSNumber)?.intValue ?? 0
                DispatchQueue.main.async {
                    self.parent.onTranslationCount(count)
                }
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
            case "selectionTools":
                // 只同步工具条状态，由 WebView 自己决定是否收起系统菜单；
                // 工具条隐藏或选区清空后必须放行系统菜单。
                let visible = (body["visible"] as? Bool) ?? false
                let hasSelection = (body["hasSelection"] as? Bool) ?? visible
                (message.webView as? WereadChapterWKWebView)?
                    .updateSelectionTools(visible: visible, hasSelection: hasSelection)
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
        :root {
            color-scheme: light dark;
            /* 正文字号只改这个变量，由浏览器重排；不缩放整页。 */
            --wr-font-size: \(Int(WereadFontSize.initial))px;
        }
        html {
            font-size: var(--wr-font-size);
            max-width: 100%;
            overflow-x: hidden;
        }
        html, body {
            margin: 0;
            /* 左右留白尽量小，把屏宽让给正文；底部留出翻页栏的空间。 */
            padding: 8px 8px 48px;
            background: transparent;
            color: #1c1c1e;
            box-sizing: border-box;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", sans-serif;
            line-height: 1.85;
            -webkit-text-size-adjust: 100%;
            max-width: 100%;
            overflow-x: hidden;
            word-wrap: break-word;
            overflow-wrap: break-word;
            word-break: break-word;
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
        /* 字号放大到上限时，长英文 / URL / 代码 / 表格 / 图片都不能把正文
           撑出屏幕。正文整体只纵向重排，横向溢出直接裁掉，不出现左右滚动。 */
        #wr-content {
            box-sizing: border-box;
            font-size: var(--wr-font-size);
            line-height: 1.85;
            max-width: 100%;
            overflow-x: hidden;
            overflow-wrap: break-word;
            word-break: break-word;
        }
        /* 官方译文随章节正文返回，节点带 class="wr-translation"。
           默认隐藏；只有翻译开关打开时才用 CSS 显示，不复制、不落本地。 */
        #wr-content .wr-translation {
            display: none !important;
        }
        html.wr-translation-on #wr-content .wr-translation {
            display: block !important;
        }
        #wr-content pre, #wr-content code {
            max-width: 100% !important;
            white-space: pre-wrap !important;
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        #wr-content table {
            max-width: 100% !important;
            width: 100% !important;
            table-layout: fixed;
        }
        #wr-content th, #wr-content td {
            overflow-wrap: break-word !important;
            word-break: break-word !important;
        }
        img, svg, video, canvas, iframe, embed, object {
            max-width: 100% !important;
            height: auto !important;
        }
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
            var lastSelectionMenuPost = 0;
            var toolsShown = false;
            // 只上报两种状态：工具条显示/隐藏，以及工具条是否还持有正文选区。
            // Swift 只在「两者都为真且焦点不在输入框」时收起系统编辑菜单。
            function reportTools(visible, hasSelection) {
                try {
                    window.webkit.messageHandlers.weread.postMessage({
                        type: 'selectionTools',
                        visible: !!visible,
                        hasSelection: !!hasSelection
                    });
                } catch (e) {}
            }

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
            // 打开笔记面板。脚注（data-wr-footernote）是原地气泡，不拦。
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
                if (toolsShown) {
                    toolsShown = false;
                    reportTools(false, false);
                }
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
                        if (!savedRange) {
                            // 选区和暂存 Range 都清空：工具条收起，停止拦截系统菜单。
                            hideTools();
                        } else if (toolsShown) {
                            // 工具条仍持有暂存 Range，选区按未清空处理。
                            reportTools(true, true);
                        }
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
                    toolsShown = true;
                    savedRange = current.range.cloneRange();
                    // 工具条已经显示。iOS 15 的编辑菜单偶尔由 WKContentView
                    // 直接询问，canPerformAction 兜不住；通知 Swift 再收一次，
                    // 避免菜单压住按钮。节流，拖选择手柄时不刷消息。
                    var now = Date.now();
                    if (now - lastSelectionMenuPost > 250) {
                        lastSelectionMenuPost = now;
                        reportTools(true, true);
                    }
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
                // 想法浮层马上覆盖阅读页：收起工具条并停止拦截系统菜单，
                // 让 TextEditor 的拷贝/粘贴菜单保持可用。
                savedRange = null;
                hideTools();
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

            // —— 正文字号 ——
            // 只改 :root 的 CSS 变量，由浏览器按新字号重排；不缩放整页，
            // 也不产生横向滚动。改前先记住视口顶部那一行的字符偏移，
            // 改完按同一锚点恢复，避免每点一次就跳回章首。
            // silent = true 用于章节加载完成时先按当前字号排版：
            // 此时续读位置还没恢复，只改字号并重排，不锚定也不上报。
            window.__wrSetFont = function (px, silent) {
                var size = Math.round(Number(px) || 0);
                var min = \(Int(WereadFontSize.minimum));
                var max = \(Int(WereadFontSize.maximum));
                size = Math.min(Math.max(size, min), max);
                var root = document.documentElement;
                var next = size + 'px';
                var current = window.getComputedStyle(root)
                    .getPropertyValue('--wr-font-size')
                    .trim();
                if (current === next) {
                    return true;
                }
                if (silent) {
                    root.style.setProperty('--wr-font-size', next);
                    void document.documentElement.offsetHeight;
                    return true;
                }
                // 续读落点已经用过后，用户改字号即视为接管位置：
                // 清掉旧锚点，下面的上报才不会被 restoring() 吞掉，
                // 图片加载完也不会再按旧锚点把人拉回去。
                if (pendingRestore && pendingRestore.applied) {
                    pendingRestore = null;
                }
                var content = document.getElementById('wr-content');
                var offset = currentOffset();
                var oldMax = root.scrollHeight - window.innerHeight;
                var fraction = oldMax > 0
                    ? Math.min(Math.max(window.scrollY / oldMax, 0), 1)
                    : 0;
                root.style.setProperty('--wr-font-size', next);
                // 读一次高度，强制在量新位置前完成重排。
                void document.documentElement.offsetHeight;
                var target = null;
                if (content) {
                    var position = textNodeAt(content, offset);
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
                            // currentOffset 取样在 progressProbeY，这里用同一
                            // 个锚点落回去，连续点按也不会逐次漂移。
                            target = window.scrollY + rect.top - progressProbeY;
                        } catch (e) { target = null; }
                    }
                }
                if (target === null) {
                    var newMax = root.scrollHeight - window.innerHeight;
                    target = newMax > 0 ? newMax * fraction : 0;
                }
                var limit = root.scrollHeight - window.innerHeight;
                if (limit < 0) limit = 0;
                window.scrollTo(
                    0,
                    Math.round(Math.min(Math.max(target, 0), limit))
                );
                // 字号变了，旧的滚动比例已经不准，立即上报新 offset。
                reportScroll(true);
                return true;
            };

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

            // —— 官方译文显隐 ——
            // 译文节点由微读正文接口随章节返回（class="wr-translation"）。
            // 这里只切 CSS class，不抽取、不复制文本；返回节点数给 Swift
            // 用来判断「官方到底有没有给译文」，0 不能冒充成功。
            window.__wrSetTranslation = function (visible) {
                var root = document.documentElement;
                if (visible) {
                    root.classList.add('wr-translation-on');
                } else {
                    root.classList.remove('wr-translation-on');
                }
                return document.querySelectorAll('#wr-content .wr-translation').length;
            };

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

// MARK: - PDF 画布缩放

/// PDF 画布缩放的上下限与步长。
private enum WereadPDFZoomLimits {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 3
    static let step: CGFloat = 0.25
}

/// PDF 全屏阅读器 + 未缩放的关闭/缩放控件。
///
/// 只给 PDF 用。EPUB 文字书继续走 `WereadNativeReaderView.reader` 里的
/// `fontSize` 重排，不经过这里。
private struct WereadPDFCanvasReader<Content: View>: View {
    @Binding var zoomScale: CGFloat
    let canSwitchFormat: Bool
    let formatBusy: Bool
    @Binding var formatMessage: String?
    let onSwitchFormat: () -> Void
    let onClose: () -> Void
    private let content: Content

    init(
        zoomScale: Binding<CGFloat>,
        canSwitchFormat: Bool,
        formatBusy: Bool,
        formatMessage: Binding<String?>,
        onSwitchFormat: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self._zoomScale = zoomScale
        self.canSwitchFormat = canSwitchFormat
        self.formatBusy = formatBusy
        self._formatMessage = formatMessage
        self.onSwitchFormat = onSwitchFormat
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WereadPDFCanvasHost(zoomScale: $zoomScale) { content }
                .ignoresSafeArea()

            // 外层关闭按钮不跟着画布缩放，放大后也一定能退出。位置和样式
            // 对齐内层网页阅读器自带的关闭按钮：那个按钮在手动宿主的
            // UIHostingController 里拿不到全屏 cover 的 dismiss，会点不动，
            // 这里用同位置的按钮接住它。
            VStack {
                HStack {
                    if canSwitchFormat {
                        Button(action: onSwitchFormat) {
                            HStack(spacing: 5) {
                                if formatBusy {
                                    ProgressView()
                                        .tint(.white)
                                        .scaleEffect(0.7)
                                }
                                Text(formatBusy ? "正在切换…" : "切换为电子书")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Color.black.opacity(0.32))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(formatBusy)
                        .accessibilityLabel("切换为电子书")
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.32))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭 PDF")
                }
                Spacer()
            }
            .padding(.trailing, 10)
            .padding(.top, 6)

            zoomControls
                .padding(.trailing, 14)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .statusBar(hidden: true)
        .alert(
            "切换格式",
            isPresented: Binding(
                get: { formatMessage != nil },
                set: { if !$0 { formatMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(formatMessage ?? "")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton(
                "−",
                label: "缩小 PDF 页面",
                enabled: zoomScale > WereadPDFZoomLimits.minScale + 0.01
            ) {
                zoomScale = max(
                    WereadPDFZoomLimits.minScale,
                    zoomScale - WereadPDFZoomLimits.step
                )
            }

            Button {
                zoomScale = WereadPDFZoomLimits.minScale
            } label: {
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复 PDF 原始大小")
            .accessibilityValue("\(Int((zoomScale * 100).rounded()))%")

            zoomButton(
                "+",
                label: "放大 PDF 页面",
                enabled: zoomScale < WereadPDFZoomLimits.maxScale - 0.01
            ) {
                zoomScale = min(
                    WereadPDFZoomLimits.maxScale,
                    zoomScale + WereadPDFZoomLimits.step
                )
            }
        }
        .background(Color(uiColor: .systemGray5))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }

    private func zoomButton(
        _ title: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// 把整个网页阅读器放进 `UIScrollView` 做 zoom。
///
/// 这里缩放的是承载 WKWebView 的 hosting view，canvas 和页面一起做
/// GPU transform；没有改字号、没有改 DOM，所以不会重排。1x 时单指滚动
/// 仍交给网页；放大后单指仍滚网页，双指拖动平移画布查看边缘。
private struct WereadPDFCanvasHost<Content: View>: UIViewControllerRepresentable {
    @Binding var zoomScale: CGFloat
    private let content: Content

    init(zoomScale: Binding<CGFloat>, @ViewBuilder content: () -> Content) {
        self._zoomScale = zoomScale
        self.content = content()
    }

    func makeUIViewController(
        context: Context
    ) -> WereadPDFCanvasController<Content> {
        let controller = WereadPDFCanvasController(content: content)
        bindZoomHandler(on: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: WereadPDFCanvasController<Content>,
        context: Context
    ) {
        // 不替换 `hosting.rootView`：内容就是网页阅读器本身，重建会把
        // WKWebView 和正在读的页面一起重置。
        bindZoomHandler(on: controller)
        controller.applyZoom(zoomScale)
    }

    /// 手势缩放结束后把倍数回写给 SwiftUI 的百分比控件。
    private func bindZoomHandler(
        on controller: WereadPDFCanvasController<Content>
    ) {
        let binding = $zoomScale
        controller.onZoomChanged = { scale in
            guard abs(binding.wrappedValue - scale) > 0.001 else { return }
            binding.wrappedValue = scale
        }
    }
}

private final class WereadPDFCanvasController<Content: View>: UIViewController, UIScrollViewDelegate {
    private let hosting: UIHostingController<Content>
    private let scrollView = UIScrollView()
    private weak var nestedScrollView: UIScrollView?
    private var lastLayoutSize: CGSize = .zero
    private var requestedScale: CGFloat = WereadPDFZoomLimits.minScale
    private var userZooming = false
    var onZoomChanged: ((CGFloat) -> Void)?

    init(content: Content) {
        hosting = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.minimumZoomScale = WereadPDFZoomLimits.minScale
        scrollView.maximumZoomScale = WereadPDFZoomLimits.maxScale
        scrollView.zoomScale = WereadPDFZoomLimits.minScale
        scrollView.bouncesZoom = false
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        // 外层画布只吃双指拖动：1x 时单指留给网页滚动，放大后单指仍滚网页，
        // 双指负责在放大后的整页里平移。
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if size != lastLayoutSize {
            lastLayoutSize = size
            resizeCanvas(to: size)
        }
        configureNestedScrollViewIfNeeded()
        updateInteractionMode()
        if !userZooming, abs(scrollView.zoomScale - requestedScale) > 0.01 {
            applyZoom(requestedScale)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        configureNestedScrollViewIfNeeded()
        // 网页阅读器的 WKWebView 可能晚一拍才挂进 hosting view；
        // 等首屏稳定后再找一次，确保关掉网页自带的 pinch。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.configureNestedScrollViewIfNeeded()
        }
    }

    func applyZoom(_ scale: CGFloat) {
        let clamped = min(
            max(scale, WereadPDFZoomLimits.minScale),
            WereadPDFZoomLimits.maxScale
        )
        requestedScale = clamped
        // 用户双指缩放期间不要被 SwiftUI 的刷新回写打断。
        guard !userZooming else { return }
        guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
            return
        }
        guard abs(clamped - scrollView.zoomScale) > 0.01 else {
            updateInteractionMode()
            return
        }
        if clamped <= WereadPDFZoomLimits.minScale + 0.001 {
            scrollView.setZoomScale(WereadPDFZoomLimits.minScale, animated: false)
            scrollView.setContentOffset(.zero, animated: false)
        } else {
            let current = max(scrollView.zoomScale, WereadPDFZoomLimits.minScale)
            let center = CGPoint(
                x: (scrollView.contentOffset.x + scrollView.bounds.width / 2) / current,
                y: (scrollView.contentOffset.y + scrollView.bounds.height / 2) / current
            )
            let width = max(scrollView.bounds.width / clamped, 1)
            let height = max(scrollView.bounds.height / clamped, 1)
            let rect = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: false)
        }
        updateInteractionMode()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        hosting.view
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let insetX = max(
            (scrollView.bounds.width - scrollView.contentSize.width) / 2,
            0
        )
        let insetY = max(
            (scrollView.bounds.height - scrollView.contentSize.height) / 2,
            0
        )
        scrollView.contentInset = UIEdgeInsets(
            top: insetY,
            left: insetX,
            bottom: insetY,
            right: insetX
        )
        updateInteractionMode()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        userZooming = true
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        userZooming = false
        requestedScale = min(
            max(scale, WereadPDFZoomLimits.minScale),
            WereadPDFZoomLimits.maxScale
        )
        updateInteractionMode()
        // 只在手势结束时回写一次，缩放过程中不逐帧刷新 SwiftUI。
        onZoomChanged?(requestedScale)
    }

    private func configureNestedScrollViewIfNeeded() {
        if let nestedScrollView {
            nestedScrollView.pinchGestureRecognizer?.isEnabled = false
            return
        }
        guard let nested = Self.findWebScrollView(in: hosting.view) else { return }
        nestedScrollView = nested
        // 外层统一接管双指缩放，关掉网页自带的 pinch，避免两套 zoom 打架。
        nested.pinchGestureRecognizer?.isEnabled = false
        updateInteractionMode()
    }

    /// 尺寸变化（旋转 / 分屏）时重设画布大小。
    ///
    /// 放大状态下 hosting.view 带 zoom transform，不能直接改 frame；
    /// 先回到 1x 再量尺寸，最后恢复原来的倍数。
    private func resizeCanvas(to size: CGSize) {
        let scale = scrollView.zoomScale
        let zoomed = scale > WereadPDFZoomLimits.minScale + 0.001
        if zoomed {
            scrollView.setZoomScale(WereadPDFZoomLimits.minScale, animated: false)
        }
        hosting.view.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        if zoomed {
            let restored = min(scale, WereadPDFZoomLimits.maxScale)
            scrollView.setZoomScale(restored, animated: false)
            requestedScale = restored
        } else {
            scrollView.contentOffset = .zero
            requestedScale = WereadPDFZoomLimits.minScale
        }
    }

    private func updateInteractionMode() {
        // 外层画布始终只认双指，避免抢走网页的单指滚动。
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2
        // 网页滚动始终只认单指；双指全部让给外层的缩放 / 平移。
        nestedScrollView?.panGestureRecognizer.minimumNumberOfTouches = 1
        nestedScrollView?.panGestureRecognizer.maximumNumberOfTouches = 1
    }

    private static func findWebScrollView(in view: UIView) -> UIScrollView? {
        if let web = view as? WKWebView { return web.scrollView }
        for sub in view.subviews {
            if let found = findWebScrollView(in: sub) {
                return found
            }
        }
        return nil
    }
}

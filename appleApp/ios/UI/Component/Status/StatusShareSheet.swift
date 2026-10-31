import SwiftUI
import UIKit
import Combine
import KotlinSharedUI
import UniformTypeIdentifiers
import FlareAppleCore
import FlareAppleUI
import Kingfisher

private enum SharePreviewStyle: Hashable {
    case card
    case content
}

struct StatusShareSheet: View {
    let statusKey: MicroBlogKey
    let accountType: AccountType
    let shareUrl: String
    let fxShareUrl: String?
    let fixvxShareUrl: String?
    let onCrossPost: (ComposePrefill) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: KotlinPresenter<StatusState>
    @StateObject private var commentsPresenter: KotlinPresenter<ScreenshotCommentsState>
    @State private var theme: ColorScheme? = nil
    @State private var previewStyle: SharePreviewStyle = .card
    @StateObject private var renderer = ScreenshotRenderCoordinator()
    @State private var selectedComments: [UiTimelineV2] = []
    @State private var showCommentPicker = false
    @State private var showPreview = false

    /// 渲染出来的长图。真正持有它的是 `renderer`，这里只是转发一下，
    /// 让下面所有用到 `image` 的地方保持原样。
    private var image: UIImage? { renderer.image }

    init(
        statusKey: MicroBlogKey,
        accountType: AccountType,
        shareUrl: String,
        fxShareUrl: String?,
        fixvxShareUrl: String?,
        onCrossPost: @escaping (ComposePrefill) -> Void
    ) {
        self.statusKey = statusKey
        self.accountType = accountType
        self.shareUrl = shareUrl
        self.fxShareUrl = fxShareUrl
        self.fixvxShareUrl = fixvxShareUrl
        self.onCrossPost = onCrossPost
        self._presenter = .init(wrappedValue: .init(presenter: StatusPresenter(accountType: accountType, statusKey: statusKey)))
        self._commentsPresenter = .init(
            wrappedValue: .init(
                presenter: ScreenshotCommentsPresenter(accountType: accountType, statusKey: statusKey)
            )
        )
    }

    /// 选中评论的指纹，用来触发重新渲染。
    private var selectionSignature: String {
        selectedComments.map { "\($0.statusKey.id)|\($0.statusKey.host)" }.joined(separator: ",")
    }

    private var availableCommentCount: Int {
        commentsPresenter.state.comments.count
    }

    var body: some View {
        List {
            StateView(state: presenter.state.status) { data in
                previewSection
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)

                Section {
                    // 截图放在最前面：这是这个面板的主功能。
                    if let image, renderer.isFinal {
                        BackportShareLink(item: image) {
                            Label("share_screenshot", systemImage: "photo")
                        }
                    } else {
                        // 渲染中保留占位，避免「分享截图」按钮突然消失、看起来像没有截图功能。
                        HStack(spacing: 12) {
                            Label("share_screenshot", systemImage: "photo")
                            Spacer(minLength: 0)
                            ProgressView()
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        saveImage()
                    } label: {
                        Label("save_screenshot", systemImage: "arrow.down.circle")
                    }
                    .disabled(image == nil || !renderer.isFinal)

                    Button {
                        showCommentPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Label {
                                Text("screenshot_comments_pick")
                            } icon: {
                                Image(systemName: "text.bubble")
                            }
                            Spacer(minLength: 0)
                            Group {
                                if commentsPresenter.state.isLoading {
                                    ProgressView()
                                } else if selectedComments.isEmpty {
                                    Text("screenshot_comments_none")
                                } else {
                                    Text(String(format: String(localized: "screenshot_comments_selected"), selectedComments.count))
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(commentsPresenter.state.isLoading || availableCommentCount == 0)

                    // 保存博文里带的原图（不是截图）。长按图片也有同样入口，
                    // 这里放一份是因为长按不容易被发现。
                    if let post = StatusShareSheet.postOf(data), !post.images.isEmpty {
                        Button {
                            saveOriginalImages(post: post)
                        } label: {
                            Label {
                                if post.images.count > 1 {
                                    Text("media_menu_download_all")
                                } else {
                                    Text("media_menu_download")
                                }
                            } icon: {
                                Image(systemName: "arrow.down.to.line")
                            }
                        }
                    }

                    Button {
                        crossPost()
                    } label: {
                        Label {
                            Text("share_crosspost")
                        } icon: {
                            Image(fontAwesome: .retweet)
                        }
                    }
                    .disabled(image == nil || !renderer.isFinal)

                    if let url = URL(string: shareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_link", systemImage: "link")
                        }
                    }

                    if let fxShareUrl, let url = URL(string: fxShareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_via_fxembed", systemImage: "link")
                        }
                    }

                    if let fixvxShareUrl, let url = URL(string: fixvxShareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_via_fixvx", systemImage: "link")
                        }
                    }
                }

                Picker("appearance_theme", selection: $theme) {
                    Text("appearance_theme_system").tag(nil as ColorScheme?)
                    Text("appearance_theme_light").tag(Optional(ColorScheme.light))
                    Text("appearance_theme_dark").tag(Optional(ColorScheme.dark))
                }

                Picker("appearance_layout_group_title", selection: $previewStyle) {
                    Text("appearance_timeline_display_mode_card").tag(SharePreviewStyle.card)
                    Text("status_share_sheet_preview_content").tag(SharePreviewStyle.content)
                }
            } loadingContent: {
                TimelinePlaceholderView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    role: .cancel
                ) {
                    dismiss()
                } label: {
                    Label {
                        Text("Cancel")
                    } icon: {
                        Image(fontAwesome: .xmark)
                    }
                }
            }
        }
        .navigationTitle("fx_share")
        .sheet(isPresented: $showCommentPicker) {
            ScreenshotCommentPickerView(
                accountType: accountType,
                statusKey: statusKey,
                selected: $selectedComments
            )
        }
        .sheet(isPresented: $showPreview) {
            ScrollView {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
            }
            .background(Color(.systemBackground))
        }
        .onSuccessOf(of: presenter.state.status) { data in
            render(data: data)
        }
        .backportOnChange(of: theme) { _, _ in
            if case .success(let data) = onEnum(of: presenter.state.status) {
                render(data: data.data)
            }
        }
        .backportOnChange(of: previewStyle) { _, _ in
            if case .success(let data) = onEnum(of: presenter.state.status) {
                render(data: data.data)
            }
        }
        .backportOnChange(of: selectionSignature) { _, _ in
            if case .success(let data) = onEnum(of: presenter.state.status) {
                render(data: data.data)
            }
        }
    }

    private func render(data: UiTimelineV2) {
        var sources = Self.sources(of: data)
        for comment in selectedComments {
            sources.merge(Self.sources(of: comment))
        }
        renderer.render(
            item: data,
            comments: selectedComments,
            showsCard: previewStyle == .card,
            colorScheme: theme ?? colorScheme,
            urls: sources.urls,
            headers: sources.headers
        )
    }

    /// 已经渲染好的长图预览。点一下可以放大看细节，确认没问题再保存/分享。
    @ViewBuilder
    private var previewSection: some View {
        if let image {
            VStack(spacing: 8) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.flareSeparator, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showPreview = true
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // 第一帧先让用户看到东西，配图还在补的时候给个小提示，
                        // 免得他以为这就是最终效果。
                        if !renderer.isFinal {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("share_screenshot_rendering")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("share_screenshot_rendering")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private func saveImage() {
        guard let image = image else { return }
        MediaSaver.shared.saveImage(image)
        dismiss()
    }

    /// 把这条博文里的图片/动图原图存进相册（多图一次性批量写入，避免只存进去一两张）。
    private func saveOriginalImages(post: UiTimelineV2.Post) {
        let items = post.images.compactMap { MediaSaver.imageSaveItem(for: $0) }
        guard !items.isEmpty else { return }
        MediaSaver.shared.saveImages(items)
        dismiss()
    }

    private func crossPost() {
        guard let imageData = image?.pngData() else { return }
        onCrossPost(
            ComposePrefill(
                text: "\n\n\(shareUrl)",
                cursorPosition: 0,
                imageData: imageData,
                fileName: "flare-crosspost.png"
            )
        )
    }
}

// MARK: - 图片预加载

extension StatusShareSheet {
    static func postOf(_ item: UiTimelineV2) -> UiTimelineV2.Post? {
        switch onEnum(of: item) {
        case .post(let post):
            return post
        case .timelinePostItem(let wrapped):
            return wrapped.post
        default:
            return nil
        }
    }

    /// 截图要预载的图片，以及它们各自需要的请求头。
    ///
    /// 微博原图、毛象媒体都校验 `Referer`：时间线里的 `KFImage` 一直带着这些头，
    /// 截图这边之前直接裸请求，原图被拒 → 悄悄退回 600px 的缩略图 → 存出来糊。
    struct ScreenshotSources {
        var urls: [URL] = []
        var headers: [String: [String: String]] = [:]

        mutating func append(_ value: String?, headers customHeaders: [String: String]?) {
            guard let value, let url = URL(string: value) else { return }
            urls.append(url)
            if let customHeaders, !customHeaders.isEmpty {
                headers[url.absoluteString] = customHeaders
            }
        }

        mutating func merge(_ other: ScreenshotSources) {
            urls.append(contentsOf: other.urls)
            headers.merge(other.headers) { current, _ in current }
        }
    }

    static func sources(of item: UiTimelineV2) -> ScreenshotSources {
        var result = ScreenshotSources()

        func walk(_ post: UiTimelineV2.Post) {
            result.append(post.user?.avatar?.url, headers: post.user?.avatar?.customHeaders)
            for media in post.images {
                switch onEnum(of: media) {
                case .image(let image):
                    result.append(image.previewUrl, headers: image.customHeaders)
                    result.append(image.url, headers: image.customHeaders)
                case .gif(let gif):
                    result.append(gif.previewUrl, headers: gif.customHeaders)
                    result.append(gif.url, headers: gif.customHeaders)
                case .video(let video):
                    result.append(video.thumbnailUrl, headers: video.customHeaders)
                case .ugoira(let ugoira):
                    result.append(ugoira.previewUrl, headers: ugoira.customHeaders)
                default:
                    break
                }
            }
        }

        if let post = postOf(item) {
            walk(post)
        }
        // 长截图里会把转发的原微博一起画出来，它的头像和配图也要预载。
        if case .timelinePostItem(let wrapped) = onEnum(of: item) {
            for quote in wrapped.presentation.quotes {
                walk(quote)
            }
        }
        return result
    }

    static func preload(urls: [URL]) async {
        let unique = Array(Set(urls))
        guard !unique.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in unique {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        KingfisherManager.shared.retrieveImage(
                            with: url,
                            options: [.backgroundDecode]
                        ) { _ in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 评论选择

private struct ScreenshotCommentPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: KotlinPresenter<ScreenshotCommentsState>
    @Binding var selected: [UiTimelineV2]

    init(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        selected: Binding<[UiTimelineV2]>
    ) {
        _presenter = .init(
            wrappedValue: .init(
                presenter: ScreenshotCommentsPresenter(accountType: accountType, statusKey: statusKey)
            )
        )
        _selected = selected
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("screenshot_comments_title")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("screenshot_comments_done")
                }
            }
            .padding()
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if presenter.state.isLoading {
            VStack {
                ProgressView()
                Text("screenshot_comments_loading")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = presenter.state.error {
            ListErrorView(error: error, onRetry: {})
        } else if presenter.state.comments.isEmpty {
            ListEmptyView()
        } else {
            List {
                ForEach(0..<presenter.state.comments.count, id: \.self) { index in
                    let comment = presenter.state.comments[index]
                    Button {
                        toggle(comment)
                    } label: {
                        row(comment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ comment: UiTimelineV2) -> some View {
        let post = StatusShareSheet.postOf(comment)
        let isSelected = isSelected(comment)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(post?.user?.name.innerText ?? "")
                    .font(.footnote.weight(.semibold))
                if let text = post?.content.original.innerText {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func isSelected(_ comment: UiTimelineV2) -> Bool {
        selected.contains { $0.statusKey.id == comment.statusKey.id && $0.statusKey.host == comment.statusKey.host }
    }

    private func toggle(_ comment: UiTimelineV2) {
        if let index = selected.firstIndex(where: { $0.statusKey.id == comment.statusKey.id && $0.statusKey.host == comment.statusKey.host }) {
            selected.remove(at: index)
        } else {
            selected.append(comment)
        }
    }
}


// MARK: - 截图渲染调度
//
// 之前是「等所有图片下载完 → 挂 window → 固定等 500ms → 截图」，图一多就要
// 用户干等好几秒。现在拆成两段：
//   第一段只用内存缓存里已有的图（时间线刚显示过，同步就能拿到），立刻出一版；
//   第二段把缓存里缺的图补下来，再出一版更完整的覆盖上去。
// 用户感知上就是「点一下马上有图」，跟 VVebo 一样。

@MainActor
private final class ScreenshotRenderCoordinator: ObservableObject {
    @Published private(set) var image: UIImage?
    /// 图里的配图是不是都到位了。第一帧可能还有图没下下来，
    /// 这时候允许保存就会存出一张缺图的截图。
    @Published private(set) var isFinal = false

    private var task: Task<Void, Never>?

    func render(
        item: UiTimelineV2,
        comments: [UiTimelineV2],
        showsCard: Bool,
        colorScheme: ColorScheme,
        urls: [URL],
        headers: [String: [String: String]] = [:]
    ) {
        task?.cancel()
        isFinal = false

        // 第一帧的素材：纯内存查表，不碰网络。
        let cached = ScreenshotImageLoader.cached(urls: urls)
        // 一张缓存都没有时先别画：那样只能画出一版灰块，比直接转圈更难看。
        let showsQuickFrame = !cached.isEmpty || urls.isEmpty
        if !showsQuickFrame {
            image = nil
        }

        task = Task { [weak self] in
            guard let self else { return }

            // 下载和第一帧渲染**同时**开始。
            // 之前是先画完 quick frame 才去发请求，白白多等一次完整布局的时间；
            // 图多的时候这一下就是好几秒，用户感觉「点了没反应」。
            async let pending = ScreenshotImageLoader.load(
                urls: urls,
                skipping: Set(cached.keys),
                headers: headers
            )

            if showsQuickFrame {
                let quick = await Self.makeImage(
                    item: item,
                    comments: comments,
                    showsCard: showsCard,
                    colorScheme: colorScheme,
                    images: cached,
                    fastPreview: true
                )
                guard !Task.isCancelled else { return }
                if let quick { self.image = quick }
            }

            // 第二帧：补齐缓存里没有的图。没有缺失就不必再渲染一次。
            let missing = await pending
            guard !Task.isCancelled else { return }
            if !showsQuickFrame || !missing.isEmpty {
                let merged = cached.merging(missing) { current, _ in current }
                let full = await Self.makeImage(
                    item: item,
                    comments: comments,
                    showsCard: showsCard,
                    colorScheme: colorScheme,
                    images: merged
                )
                guard !Task.isCancelled else { return }
                if let full { self.image = full }
            }
            self.isFinal = true
        }
    }

    private static func makeImage(
        item: UiTimelineV2,
        comments: [UiTimelineV2],
        showsCard: Bool,
        colorScheme: ColorScheme,
        images: [String: UIImage],
        fastPreview: Bool = false
    ) async -> UIImage? {
        await ScreenshotPostView(
            item: item,
            comments: comments,
            contentWidth: 390,
            showsCard: showsCard
        )
        .environment(\.screenshotImages, images)
        .environment(\.colorScheme, colorScheme)
        .snapshot(
            colorScheme: colorScheme,
            // 第一帧只是让用户先看到东西，1x 渲染快一个数量级（像素少 7 倍）。
            // 原图到位后第二帧才按 2.8x 出成品。
            delay: fastPreview ? 0.01 : 0.05,
            scaleOverride: fastPreview ? 1 : nil
        )
    }
}

/// 截图输出倍率的计算。
private enum ScreenshotRenderMetrics {
    /// 目标输出宽度（像素）。1080 是社交平台通用的清晰度门槛，
    /// 低于这个数在原尺寸下看就会觉得糊。
    private static let targetWidthPixels: CGFloat = 1080

    /// 位图内存预算。9 张图的 3:4 长截图按 2.8x 渲染约 120MB，这里给到
    /// 160MB 留余量；6s 这类 2GB 内存的机器也不至于被系统杀掉。
    private static let pixelBudget: CGFloat = 160 * 1024 * 1024 / 4

    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 2 }
        // 390pt 宽 → 1080/390 ≈ 2.77，和屏幕 3x 基本一致，最锐利。
        let preferred = min(max(targetWidthPixels / size.width, 1), 3)
        var scale = preferred
        while scale > 1, size.width * scale * size.height * scale > pixelBudget {
            scale -= 0.25
        }
        // 最低 1x：再往下就真看不清了。极端长图宁可让 drawHierarchy 失败后
        // 走 layer 兜底，也不要把整张图的字全糊掉。
        return max(scale, 1)
    }
}

extension View {
    @MainActor
    func snapshot(
        colorScheme: ColorScheme,
        delay: TimeInterval = 0.05,
        scaleOverride: CGFloat? = nil
    ) async -> UIImage? {
        let controller = UIHostingController(rootView: self.edgesIgnoringSafeArea(.top))
        controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard let view = controller.view else { return nil }

        // UIHostingController 的 intrinsicContentSize 有时会是 -1 或 0（内含
        // UIViewRepresentable 时尤其常见），直接用会渲染出一张空图。
        var targetSize = view.intrinsicContentSize
        if targetSize.width < 1 || targetSize.height < 1 {
            targetSize = controller.sizeThatFits(
                in: CGSize(
                    width: UIView.layoutFittingCompressedSize.width,
                    height: UIView.layoutFittingCompressedSize.height
                )
            )
        }
        guard targetSize.width >= 1,
              targetSize.height >= 1,
              targetSize.width.isFinite,
              targetSize.height.isFinite
        else {
            return nil
        }

        view.bounds = CGRect(origin: .zero, size: targetSize)
        view.backgroundColor = .systemGroupedBackground
        view.layoutIfNeeded()

        // SwiftUI 的 onAppear 只有在 view 真正挂进 window 后才会触发，
        // 而 KFImage / AsyncImage 是在 onAppear 里才去取图的。离屏的
        // UIHostingController 直接截图，图片永远停在占位色块上。
        // 这里挂一个几乎透明、层级最高的临时 window，截完立刻销毁。
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: targetSize)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: targetSize))
        }
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        window.alpha = 0.01
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // 图片已经是预加载好的 UIImage 了，这里不需要等网络，只要等 SwiftUI
        // 走完一次布局 + 提交渲染。之前固定等 0.5s 纯属浪费。
        await Task.yield()
        CATransaction.flush()
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        CATransaction.flush()

        // 输出倍率：先保宽度清晰度，再按位图内存预算退让。
        //
        // 之前是按「像素高度超过 12000 就降倍率」砍的，9 张 3:4 竖图铺开约
        // 9700pt，9700×3 = 29000 超了 → 降到 2 → 还超 → 直接砍到 1x，
        // 390pt 宽的截图只剩 390px，原图里的水印和小字全糊。
        // 真正该限制的是位图内存，不是高度 —— 长图本来就该长。
        let scale = scaleOverride ?? ScreenshotRenderMetrics.scale(for: targetSize)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let drawn = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if !Self.isBlank(drawn) { return drawn }

        // drawHierarchy 在超高视图上会整张画成黑的，退回 layer 渲染再来一次。
        let layered = renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
        return Self.isBlank(layered) ? drawn : layered
    }

    /// 采样几个点判断是不是整张黑（drawHierarchy 失败时的典型表现）。
    static func isBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return true }
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return false }
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 1)
        let points: [(Int, Int)] = [
            (width / 2, height / 2),
            (width / 2, height / 4),
            (width / 2, height * 3 / 4),
            (width / 4, height / 2),
        ]
        for (x, y) in points {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { continue }
            if bytes[offset] > 12 || bytes[offset + 1] > 12 || bytes[offset + 2] > 12 {
                return false
            }
        }
        return true
    }
}

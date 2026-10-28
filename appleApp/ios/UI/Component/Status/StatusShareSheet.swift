import SwiftUI
import UIKit
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
    @Environment(\.timelineAppearance) private var timelineAppearance
    @StateObject private var presenter: KotlinPresenter<StatusState>
    @StateObject private var commentsPresenter: KotlinPresenter<ScreenshotCommentsState>
    @State private var theme: ColorScheme? = nil
    @State private var previewStyle: SharePreviewStyle = .card
    @State private var image: UIImage? = nil
    @State private var selectedComments: [UiTimelineV2] = []
    @State private var showCommentPicker = false

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
                ViewBox {
                    ZStack {
                        previewView(data: data)
                            .padding()
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                            }
                    }
                }
                .frame(minHeight: 200, maxHeight: 360)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)

                Section {
                    // 截图放在最前面：这是这个面板的主功能。
                    if let image {
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
                    .disabled(image == nil)

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
                    .disabled(image == nil)

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
        image = nil
        Task {
            image = await renderImage(data: data)
        }
    }

    @ViewBuilder
    private func previewView(data: UiTimelineV2) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(data: data, detailStatusKey: statusKey, showTranslate: false)
            if !selectedComments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<selectedComments.count, id: \.self) { index in
                        ScreenshotCommentRow(data: selectedComments[index])
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(width: 360)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .if(previewStyle == .card) { view in
            view
                .clipShape(.rect(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)
                .padding(64)
        }
        .background(Color(.systemGroupedBackground))
        .environment(\.colorScheme, theme ?? colorScheme)
        .environment(\.timelineAppearance, timelineAppearance.withSharePreviewDefaults())
    }

    private func renderImage(data: UiTimelineV2) async -> UIImage? {
        // 先把要出现在图里的图片全部拉进 Kingfisher 缓存，
        // 否则 UIHostingController 刚布局完就去截图，图片还是占位色块。
        let urls = Self.imageURLs(of: data) + selectedComments.flatMap(Self.imageURLs(of:))
        await Self.preload(urls: urls)
        return await previewView(data: data).snapshot(
            colorScheme: theme ?? colorScheme,
            delay: 0.45
        )
    }

    private func saveImage() {
        guard let image = image else { return }
        MediaSaver.shared.saveImage(image)
        dismiss()
    }

    /// 把这条博文里的图片/动图原图存进相册（多图会逐张保存）。
    private func saveOriginalImages(post: UiTimelineV2.Post) {
        for media in post.images {
            switch onEnum(of: media) {
            case .image(let image):
                MediaSaver.shared.saveImage(url: image.url, customHeaders: image.customHeaders)
            case .gif(let gif):
                MediaSaver.shared.saveImage(url: gif.url, customHeaders: gif.customHeaders)
            default:
                break
            }
        }
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

    static func imageURLs(of item: UiTimelineV2) -> [URL] {
        guard let post = postOf(item) else { return [] }
        var urls: [URL] = []
        if let avatar = post.user?.avatar?.url, let url = URL(string: avatar) {
            urls.append(url)
        }
        for media in post.images {
            switch onEnum(of: media) {
            case .image(let image):
                if let url = URL(string: image.previewUrl) { urls.append(url) }
                if let url = URL(string: image.url) { urls.append(url) }
            case .gif(let gif):
                if let url = URL(string: gif.url) { urls.append(url) }
            default:
                break
            }
        }
        return urls
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

// MARK: - 评论行（截图里用）

private struct ScreenshotCommentRow: View {
    let data: UiTimelineV2

    var body: some View {
        if let post = StatusShareSheet.postOf(data) {
            HStack(alignment: .top, spacing: 8) {
                NetworkImage(data: post.user?.avatar?.url, contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.user?.name.innerText ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    RichText(text: post.content.original)
                        .font(.system(size: 12))
                }
                Spacer(minLength: 0)
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

private extension TimelineAppearance {
    func withSharePreviewDefaults() -> TimelineAppearance {
        doCopy(
            avatarShape: avatarShape,
            showMedia: showMedia,
            showSensitiveContent: showSensitiveContent,
            expandContentWarning: true,
            expandMediaSize: expandMediaSize,
            mediaLayout: mediaLayout,
            limitMediaGridToNine: limitMediaGridToNine,
            videoAutoplay: .never,
            showLinkPreview: showLinkPreview,
            compatLinkPreview: compatLinkPreview,
            showEmojiReactions: showEmojiReactions,
            showNumbers: showNumbers,
            postActionStyle: postActionStyle,
            postActionLayout: postActionLayout,
            postActionFixedWidth: postActionFixedWidth,
            fullWidthPost: fullWidthPost,
            absoluteTimestamp: absoluteTimestamp,
            showPlatformLogo: showPlatformLogo,
            timelineDisplayMode: timelineDisplayMode,
            aiConfig: aiConfig,
            lineLimit: lineLimit,
            showTranslateButton: showTranslateButton
        )
    }
}

extension View {
    @MainActor
    func snapshot(
        colorScheme: ColorScheme,
        delay: TimeInterval = 0.1
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

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        // 图片是异步解码的，等一帧再布局一次，保证截到的是真图而不是占位块。
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 80_000_000)
        view.layoutIfNeeded()

        // 超长微博降采样，避免 3x 渲染长图时爆内存。
        var scale: CGFloat = 3
        if targetSize.height * scale > 12_000 { scale = 2 }
        if targetSize.height * scale > 12_000 { scale = 1 }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }
}

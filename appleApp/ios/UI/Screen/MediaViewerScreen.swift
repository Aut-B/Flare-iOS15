import SwiftUI
import FlareAppleUI
import KotlinSharedUI
import LazyPager
import AVKit
import UIKit
import FlareAppleCore
import NavigationBackport

struct MediaViewerShareContext {
    let statusKey: String?
    let userHandle: String?
}

struct MediaViewerScreen: View {
    @Environment(\.globalAppearance.showPostInMediaViewer) private var showPostInMediaViewer
    @Environment(\.timelineAppearance.postActionStyle) private var postActionStyle
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    let medias: [any UiMedia]
    let initialIndex: Int
    let preview: String?
    let previewAspectRatio: CGFloat?
    let previewIsImage: Bool
    let shareContext: MediaViewerShareContext?
    let post: UiTimelineV2.Post?
    let quotes: [UiTimelineV2.Post]

    @State private var selectedIndex: Int
    @State private var isPlaying: Bool = true
    @State private var videoState: VideoState = .idle
    @State private var playbackTimes: [String: CMTime] = [:]
    @State private var opacity: CGFloat = 1
    @State private var dismissOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var showData = true
    @State private var protectInitialPagerSelection: Bool
    @State private var didApplyInitialSelection = false
    @State private var isPreparingShare = false
    @State private var playbackRate: Float = 1
    @State private var isLandscapeViewing = false
    /// 「查看这条帖子」的全文 sheet 是否展开（点底部紧凑卡片打开）。
    /// iOS 15 回退：PresentationDetent 是 iOS 16 API，.sheet 在 iOS 15 只有
    /// 全屏 large 一档——原来的 detent sheet 会把整张图片盖住，所以折叠态
    /// 改用 ZStack 内的底部紧凑卡片，只有展开阅读才用全屏 sheet。
    @State private var postExpanded = false

    init(
        medias: [any UiMedia],
        initialIndex: Int,
        preview: String?,
        previewAspectRatio: CGFloat? = nil,
        previewIsImage: Bool = true,
        shareContext: MediaViewerShareContext? = nil,
        post: UiTimelineV2.Post? = nil,
        quotes: [UiTimelineV2.Post] = []
    ) {
        self.medias = medias
        self.initialIndex = initialIndex
        self.preview = preview
        self.previewAspectRatio = previewAspectRatio
        self.previewIsImage = previewIsImage
        self.shareContext = shareContext
        self.post = post
        self.quotes = quotes
        self.selectedIndex = max(0, initialIndex)
        self.protectInitialPagerSelection = initialIndex > 0
    }

    var body: some View {
        ZStack {
            Group {
                if medias.isEmpty {
                    Group {
                        if let preview {
                            LazyPager(data: [preview]) { preview in
                                Group {
                                    switch MediaViewerImageLayoutPolicy.previewLayout(isImage: previewIsImage) {
                                    case .adaptiveImage:
                                        AdaptiveKFImage(
                                            data: preview,
                                            placeholder: nil,
                                            mediaAspectRatio: previewAspectRatio
                                        )
                                    case .aspectFit:
                                        NetworkImage(data: preview)
                                            .scaledToFit()
                                    }
                                }
                                .modifier(MediaViewerDismissOffset(offset: $dismissOffset))
                            }
                            .zoomable(min: 1, max: 5, doubleTapGesture: .scale(2))
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    // LazyPager 1.2.1 only supports downward dismissal.
                    ZStack(alignment: .bottom) {
                        LazyPager(data: medias, page: pagerSelectedIndex) { media in
                            mediaContent(media)
                                .accessibilityLabel(Text(verbatim: media.accessibleDescription))
                                .contextMenu {
                                    // Video long presses are reserved for temporary double-speed playback.
                                    if !media.isVideoMedia {
                                        MediaViewerContextMenu(
                                            media: media,
                                            showsDownloadAll: medias.count > 1,
                                            isPreparingShare: isPreparingShare,
                                            onDownload: {
                                                saveMedia(media)
                                            },
                                            onDownloadAll: {
                                                saveAllMedia()
                                            },
                                            onShareImage: {
                                                shareSelectedImage(media)
                                            },
                                            onCopyLink: {
                                                UIPasteboard.general.string = media.url
                                            }
                                        )
                                    }
                                }
                                // Move the content, keeping the pager's safe-area insets stable.
                                .modifier(MediaViewerDismissOffset(offset: $dismissOffset))
                        }
                        .onTap {
                            withAnimation {
                                showData.toggle()
                            }
                        }
                        .onDoubleTap {}
                        .onDrag {
                            protectInitialPagerSelection = false
                        }
                        .zoomable { item in
                            if item.isVideoMedia {
                                return .disabled
                            } else {
                                return .custom(min: 1, max: 5, doubleTap: .scale(2))
                            }
                        }
                        .settings { config in
                            // iOS 15 回退：99 会让 LazyPager 预载全部媒体页，在
                            // iPhone 6S（2GB）上直接触发内存压力（崩溃日志
                            // ktriageinfo 连续 5 次 "VM - Fault hit memory shortage"），
                            // 且瀑布流/分页在内存不足时做批量更新会抛断言。
                            // 1 页预载足够连续滑动，内存占用回归正常水平。
                            config.preloadAmount = 1
                        }

                        if shouldShowBottomOverlay, !showPostCard {
                            bottomOverlay
                                .offset(
                                    y: MediaViewerDismissGesturePolicy.verticalOffset(
                                        for: .bottomOverlay,
                                        translationY: dismissOffset
                                    )
                                )
                                .opacity(opacity)
                        }
                    }
                }
            }
            .ignoresSafeArea()

            MediaViewerDismissGestureHost(
                enabled: !postExpanded,
                onChanged: updateDismissGesture,
                onEnded: endDismissGesture,
                onCancelled: cancelDismissGesture
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            // 关键修复：让这个全屏覆盖层在 iOS 15 上也可靠地透传触摸。
            // 上游仅靠 point(inside:) 返回 false，但 iOS 15 的 SwiftUI 宿主视图不尊重该覆写，
            // 导致整屏触摸被覆盖层截走——横滑翻页 / 捏合缩放 / 点按隐藏底栏全部失效，
            // 而下滑关闭仍可工作（关闭手势挂在 UIWindow 上、独立收触摸）。
            // .allowsHitTesting(false) 由 SwiftUI 跨版本可靠地关闭底层宿主视图的命中，
            // 触摸遂透传给下方 LazyPager；窗口级关闭手势不受影响。
            .allowsHitTesting(false)

            if showData {
                topOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(opacity)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(!isDismissing)
                    .zIndex(3)
            }
            if showPostCard, let post {
                compactPostCard(post)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .offset(
                        y: MediaViewerDismissGesturePolicy.verticalOffset(
                            for: .bottomOverlay,
                            translationY: dismissOffset
                        )
                    )
                    .opacity(opacity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(!isDismissing)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .videoPlaybackPresentation(mediaURLs: medias.map(\.url), selectedMediaURL: selectedMedia?.url)
        .ugoiraExportStatus()
        .onAppear {
            applyInitialSelectionIfNeeded()
        }
        .backportOnChange(of: mediaSignature) { _, _ in
            applyInitialSelectionIfNeeded()
        }
        .backportOnChange(of: selectedIndex) { _, _ in
            isPlaying = true
            videoState = .idle
            playbackRate = 1
        }
        .backportOnChange(of: isLandscapeViewing) { _, newValue in
            MediaOrientationController.setLandscape(newValue)
        }
        .onDisappear {
            if isLandscapeViewing {
                MediaOrientationController.setLandscape(false)
            }
        }
        .sheet(isPresented: $postExpanded) {
            postDetailSheet
        }
        .background(.black.opacity(opacity))
        .background(ClearFullScreenBackground())
        .flareNavigationBarHidden()
    }

    @ViewBuilder
    private func mediaContent(_ media: any UiMedia) -> some View {
        switch onEnum(of: media) {
        case .ugoira(let animation):
            UgoiraPlayer(media: animation, active: selectedMedia?.url == animation.url)
        case .image(let image):
            AdaptiveKFImage(
                data: image.url,
                placeholder: image.previewUrl,
                customHeader: image.customHeaders,
                mediaAspectRatio: CGFloat(image.aspectRatio)
            )
        case .video(let video):
            if medias.indices.contains(selectedIndex), medias[selectedIndex].url == video.url {
                StatusMediaVideoView(
                    data: video,
                    play: $isPlaying,
                    videoState: $videoState,
                    time: timeBinding(for: video.url),
                    playbackRate: $playbackRate
                )
            } else {
                NetworkImage(data: video.thumbnailUrl, customHeader: video.customHeaders)
                    .scaledToFit()
            }
        case .gif(let gif):
            NetworkImage(data: gif.url, placeholder: gif.previewUrl, customHeader: gif.customHeaders)
                .scaledToFit()
        case .audio:
            EmptyView()
        }
    }

    private var topOverlay: some View {
        HStack(spacing: 8) {
            topOverlayButton(width: 44, action: {
                dismiss()
            }) {
                Image(fontAwesome: .xmark)
            }
            .accessibilityLabel("Close")

            Spacer()

            if !medias.isEmpty {
                HStack(spacing: 0) {
                    topOverlayButton {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isLandscapeViewing.toggle()
                        }
                    } label: {
                        Image(systemName: isLandscapeViewing ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel(Text(verbatim: isLandscapeViewing ? "Exit landscape view" : "Landscape view"))

                    if let selectedMedia, case .image = onEnum(of: selectedMedia) {
                        topOverlayButton {
                            saveMedia(selectedMedia)
                        } label: {
                            Image(fontAwesome: .download)
                        }
                        .accessibilityLabel(
                            Text("media_menu_download", bundle: .main)
                        )

                        topOverlayButton {
                            shareSelectedImage(selectedMedia)
                        } label: {
                            Image(fontAwesome: .shareNodes)
                        }
                        .disabled(isPreparingShare)
                        .accessibilityLabel("Share image")
                    } else if let selectedMedia, selectedMedia is UiMediaVideo || selectedMedia is UiMediaUgoira {
                        topOverlayButton {
                            saveMedia(selectedMedia)
                        } label: {
                            Image(fontAwesome: .download)
                        }
                        .accessibilityLabel(
                            Text("media_menu_download", bundle: .main)
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func topOverlayButton<Label: View>(
        width: CGFloat = 48,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action, label: label)
            .frame(width: width, height: 44)
            .font(.body)
            .imageScale(.large)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var bottomOverlay: some View {
        if #available(iOS 26.0, *) {
            bottomOverlayContent
                .padding()
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            bottomOverlayContent
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var bottomOverlayContent: some View {
        VStack(spacing: 8) {
            if showData, !isLandscapeViewing, medias.count > 1 {
                if post == nil, medias.count > 10 {
                    MediaPageSlider(count: medias.count, page: $selectedIndex)
                } else {
                    LazyPagerIndicator(count: medias.count, page: $selectedIndex)
                }
            }

            if let selectedMedia, case .video = onEnum(of: selectedMedia) {
                VideoControlView(
                    isPlaying: $isPlaying,
                    currentTime: timeBinding(for: selectedMedia.url),
                    videoState: videoState,
                    playbackRate: $playbackRate
                )
                .id(selectedMedia.url)
            }

        }
    }

    /// 折叠态紧凑帖子卡片的显示条件。点图片切换 showData 时它跟着隐藏/出现，
    /// 这就是「点击图片就不显示」的开关。
    private var showPostCard: Bool {
        showPostInMediaViewer && post != nil && showData && !isLandscapeViewing && !isDismissing
    }

    /// 折叠态紧凑帖子卡片：iOS 15 上 .sheet 只有全屏 large detent，
    /// 原来的 detent sheet（用户信息 + 互动按钮，约 140pt，在 iOS 15 上更是
    /// 直接全屏）会把图片挡得严严实实。这里压成一条 ~54pt 的底部卡片：
    /// 页面指示器/视频控制 + 小头像 + 名称 + 互动按钮，点卡片展开全文。
    @ViewBuilder
    private func compactPostCard(_ post: UiTimelineV2.Post) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .padding(.bottom, 8)

            if !isLandscapeViewing, medias.count > 1 {
                LazyPagerIndicator(count: medias.count, page: $selectedIndex)
            }

            if let selectedMedia, case .video = onEnum(of: selectedMedia) {
                VideoControlView(
                    isPlaying: $isPlaying,
                    currentTime: timeBinding(for: selectedMedia.url),
                    videoState: videoState,
                    playbackRate: $playbackRate
                )
                .id(selectedMedia.url)
            }

            if let user = post.user {
                HStack(spacing: 8) {
                    AvatarView(data: user.avatar?.url, customHeader: user.avatar?.customHeaders)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        RichText(text: user.name)
                        Text(user.handle.canonical)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        user.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
                    }
                    if postActionStyle != .hidden {
                        StatusActionsView(data: Array(post.actions), useText: false)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.72))
        .onTapGesture {
            postExpanded = true
        }
    }

    /// 展开态：全屏阅读这条帖子（点紧凑卡片打开）。
    @ViewBuilder
    private var postDetailSheet: some View {
        if let post {
            NBNavigationStack {
                ScrollView {
                    StatusView(
                        data: post,
                        isDetail: true,
                        isClickable: false,
                        showAttachments: false,
                        forceHideActions: postActionStyle == .hidden,
                        showParents: false,
                        quotes: quotes
                    )
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .padding(.top, 24)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            postExpanded = false
                        } label: {
                            Label {
                                Text("Close")
                            } icon: {
                                Image(systemName: "xmark")
                            }
                        }
                    }
                }
            }
            .flarePresentationDragIndicatorVisible()
            .flarePresentationCompactAdaptationNone()
            .flarePresentationContentInteractionResizes()
            .preferredColorScheme(.dark)
        }
    }

    private var pagerSelectedIndex: Binding<Int> {
        Binding(
            get: {
                selectedIndex
            },
            set: { newValue in
                let nextIndex = clampedIndex(newValue, count: medias.count)
                if protectInitialPagerSelection,
                   selectedIndex > 0,
                   nextIndex < selectedIndex {
                    return
                }
                protectInitialPagerSelection = false
                selectedIndex = nextIndex
            }
        )
    }

    private func timeBinding(for url: String?) -> Binding<CMTime> {
        guard let url else { return .constant(.zero) }
        return Binding(
            get: { playbackTimes[url] ?? CMTime(seconds: MediaPlaybackMemory.shared.position(for: url), preferredTimescale: 600) },
            set: {
                playbackTimes[url] = $0
                VideoPlaybackSession.setPosition(for: url, seconds: $0.seconds)
            }
        )
    }

    private var selectedMedia: (any UiMedia)? {
        guard medias.indices.contains(selectedIndex) else {
            return nil
        }
        return medias[selectedIndex]
    }

    private var selectedMediaIsVideo: Bool {
        selectedMedia?.isVideoMedia == true
    }

    private var shouldShowBottomOverlay: Bool {
        if selectedMediaIsVideo {
            return showData
        }
        return showData && !isLandscapeViewing && (medias.count > 1)
    }

    private var mediaSignature: String {
        medias.map { $0.url }.joined(separator: "\n")
    }

    private func applyInitialSelectionIfNeeded() {
        guard !medias.isEmpty else {
            return
        }
        if !didApplyInitialSelection || selectedIndex >= medias.count {
            let initialSelection = clampedIndex(initialIndex, count: medias.count)
            selectedIndex = initialSelection
            protectInitialPagerSelection = initialSelection > 0
            didApplyInitialSelection = true
        }
    }

    private func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }
        return min(max(index, 0), count - 1)
    }

    private func updateDismissGesture(translationY: CGFloat, containerHeight: CGFloat) {
        guard !isDismissing else { return }
        dismissOffset = translationY
        opacity = 1 - MediaViewerDismissGesturePolicy.progress(
            translationY: translationY,
            containerHeight: containerHeight
        )
    }

    private func endDismissGesture(
        translationY: CGFloat,
        velocityY: CGFloat,
        containerHeight: CGFloat
    ) -> Bool {
        guard !isDismissing else { return true }
        guard MediaViewerDismissGesturePolicy.shouldDismiss(
            translationY: translationY,
            velocityY: velocityY,
            containerHeight: containerHeight
        ) else {
            cancelDismissGesture()
            return false
        }

        isDismissing = true
        let direction = MediaViewerDismissGesturePolicy.dismissDirection(
            translationY: translationY,
            velocityY: velocityY
        )
        withAnimation(.linear(duration: 0.2)) {
            dismissOffset = direction * containerHeight
            opacity = 0
        }
        // iOS 15 回退：withAnimation(_:completionCriteria:_:completion:) 是 iOS 17 API，
        // 这里按动画时长延迟收尾，效果一致。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dismiss()
            }
        }
        return true
    }

    private func cancelDismissGesture() {
        guard !isDismissing else { return }
        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) {
            dismissOffset = 0
            opacity = 1
        }
    }

    private func saveMedia(
        _ media: any UiMedia,
        showsDownloadStarted: Bool = true,
        showsSaveResult: Bool = true,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        switch onEnum(of: media) {
        case .ugoira(let animation):
            MediaSaver.shared.saveUgoira(animation, fileName: fileName(for: media), showsSaveResult: showsSaveResult, completion: completion)
        case .image(let image):
            MediaSaver.shared.saveImage(
                url: image.url,
                customHeaders: image.customHeaders,
                showsDownloadStarted: showsDownloadStarted,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        case .gif(let gif):
            MediaSaver.shared.saveImage(
                url: gif.url,
                customHeaders: gif.customHeaders,
                showsDownloadStarted: showsDownloadStarted,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        case .video(let video):
            MediaSaver.shared.saveVideo(
                url: video.urlForDownload,
                customHeaders: video.customHeaders,
                showsDownloadStarted: showsDownloadStarted,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        case .audio(let audio):
            MediaSaver.shared.saveFile(
                url: audio.url,
                fileName: fileName(for: media),
                customHeaders: audio.customHeaders,
                showsDownloadStarted: showsDownloadStarted,
                showsSaveResult: showsSaveResult,
                completion: completion
            )
        }
    }

    private func saveAllMedia() {
        guard !medias.isEmpty else {
            return
        }

        // 纯图片的帖子一次性批量写入相册（单个 performChanges），
        // 逐张并发写会让系统只接受其中一个，表现就是「下载全部」只存进去一部分。
        let imageItems = medias.compactMap { MediaSaver.imageSaveItem(for: $0) }
        if imageItems.count == medias.count {
            MediaSaver.shared.saveImages(imageItems)
            return
        }

        MediaSaver.shared.showDownloadStarted()
        let tracker = MediaViewerBatchSaveTracker(count: medias.count)

        let onComplete: @Sendable (Bool) -> Void = { success in
            Task {
                if let batchSuccess = await tracker.complete(success: success) {
                    await MainActor.run {
                        MediaSaver.shared.showBatchSaveResult(success: batchSuccess)
                    }
                }
            }
        }

        for media in medias {
            saveMedia(
                media,
                showsDownloadStarted: false,
                showsSaveResult: false,
                completion: onComplete
            )
        }
    }

    private func fileName(for media: any UiMedia) -> String {
        if let statusKey = shareContext?.statusKey {
            let mediaIndex = medias.firstIndex { $0.url == media.url } ?? 0
            return MediaFileNamePolicy.shared.statusMediaFileName(
                statusKey: statusKey,
                userHandle: shareContext?.userHandle ?? "unknown",
                media: media,
                mediaIndex: Int32(mediaIndex)
            )
        }
        return MediaFileNamePolicy.shared.rawMediaFileName(media: media)
    }

    private func shareSelectedImage(_ media: any UiMedia) {
        guard !isPreparingShare,
              case .image(let image) = onEnum(of: media) else {
            return
        }

        let sourceURL = image.url
        let customHeaders = image.customHeaders
        isPreparingShare = true
        Task {
            defer {
                isPreparingShare = false
            }
            do {
                let fileURL = try await OriginalImageShareFile.make(
                    url: sourceURL,
                    customHeaders: customHeaders,
                    statusKey: shareContext?.statusKey,
                    userHandle: shareContext?.userHandle,
                    onPreparingNeeded: {
                        MediaSaver.showPreparingMedia()
                    }
                )
                guard !Task.isCancelled,
                      selectedMedia?.url == sourceURL,
                      let presenter = topViewController() else {
                    return
                }
                let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                controller.popoverPresentationController?.sourceView = presenter.view
                controller.popoverPresentationController?.sourceRect = presenter.view.bounds
                presenter.present(controller, animated: true)
            } catch {
                return
            }
        }
    }

    private func topViewController() -> UIViewController? {
        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }?
            .rootViewController
        return topViewController(from: rootViewController)
    }

    private func topViewController(from viewController: UIViewController?) -> UIViewController? {
        if let navigationController = viewController as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController)
        }
        if let presentedViewController = viewController?.presentedViewController {
            return topViewController(from: presentedViewController)
        }
        return viewController
    }
}

private struct MediaViewerDismissOffset: ViewModifier {
    // LazyPager hosts pages in separate SwiftUI trees. Reading the binding here
    // preserves the animation transaction when the dismiss gesture settles.
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: MediaViewerDismissGesturePolicy.verticalOffset(for: .media, translationY: offset))
    }
}

private struct MediaViewerDismissGestureHost: UIViewRepresentable {
    let enabled: Bool
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat, CGFloat) -> Bool
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> MediaViewerDismissGestureHostView {
        let view = MediaViewerDismissGestureHostView()
        view.backgroundColor = .clear
        view.onWindowChanged = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.installGesture(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: MediaViewerDismissGestureHostView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onCancelled = onCancelled
        DispatchQueue.main.async {
            context.coordinator.installGesture(from: uiView)
        }
    }

    static func dismantleUIView(
        _ uiView: MediaViewerDismissGestureHostView,
        coordinator: Coordinator
    ) {
        coordinator.uninstallGesture()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true
        var onChanged: (CGFloat, CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat, CGFloat) -> Bool
        var onCancelled: () -> Void

        private weak var sourceView: UIView?
        private weak var installedWindow: UIWindow?
        private weak var touchedZoomScrollView: UIScrollView?
        private weak var touchedVerticalScrollView: UIScrollView?
        private var touchedZoomScrollViewInitialOffset: CGPoint?
        private var panRecognizer: UIPanGestureRecognizer?

        init(
            onChanged: @escaping (CGFloat, CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat, CGFloat) -> Bool,
            onCancelled: @escaping () -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        func installGesture(from view: UIView?) {
            sourceView = view
            guard let window = view?.window, installedWindow !== window else { return }
            uninstallGesture()
            sourceView = view

            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = false
            // iOS 15 回退：默认 delaysTouchesEnded=true 会让窗口级手势在判定期间
            // 扣留"抬起"事件，导致下方 PagerView/ZoomableView 的捏合与点按识别器
            // 收不到完整触摸序列而失效。显式关掉，让缩放与点按正常触发。
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)

            installedWindow = window
            panRecognizer = recognizer
        }

        func uninstallGesture() {
            if let panRecognizer {
                installedWindow?.removeGestureRecognizer(panRecognizer)
            }
            installedWindow = nil
            touchedZoomScrollView = nil
            touchedVerticalScrollView = nil
            touchedZoomScrollViewInitialOffset = nil
            panRecognizer = nil
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let sourceView else { return }
            let translationY = recognizer.translation(in: sourceView).y
            let containerHeight = sourceView.bounds.height

            switch recognizer.state {
            case .began, .changed:
                onChanged(translationY, containerHeight)
            case .ended:
                let didDismiss = onEnded(
                    translationY,
                    recognizer.velocity(in: sourceView).y,
                    containerHeight
                )
                finishTrackingTouchedScrollView(didDismiss: didDismiss)
            case .cancelled, .failed:
                onCancelled()
                finishTrackingTouchedScrollView(didDismiss: false)
            default:
                break
            }
        }

        private func owningViewController(of view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, gestureRecognizer === panRecognizer,
                  let panRecognizer,
                  let sourceView else { return false }
            let velocity = panRecognizer.velocity(in: sourceView)
            guard MediaViewerDismissGesturePolicy.shouldBegin(
                velocityX: velocity.x,
                velocityY: velocity.y,
                zoomScale: touchedZoomScrollView?.zoomScale,
                minimumZoomScale: touchedZoomScrollView?.minimumZoomScale
            ) else {
                return false
            }
            return MediaViewerDismissGesturePolicy.shouldBeginDismissPan(
                in: touchedVerticalScrollView,
                velocityY: velocity.y
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, let sourceView,
                  let window = installedWindow else { return false }
            // The recognizer is installed on UIWindow, so screen bounds alone also include sheets.
            guard let viewer = owningViewController(of: sourceView)?.view,
                  let touchedView = touch.view,
                  MediaViewerDismissGesturePolicy.belongsToViewer(touchedView, viewer: viewer) else {
                return false
            }
            let point = touch.location(in: window)
            guard sourceView.convert(sourceView.bounds, to: window).contains(point) else {
                return false
            }
            let touchedScrollViews = ancestorScrollViews(from: touch.view)
            touchedZoomScrollView = touchedScrollViews.first {
                $0.maximumZoomScale > $0.minimumZoomScale
            }
            touchedVerticalScrollView = touchedScrollViews.first {
                MediaViewerDismissGesturePolicy.hasScrollableVerticalContent($0)
            }
            touchedZoomScrollViewInitialOffset = touchedZoomScrollView?.contentOffset
            return true
        }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 与查看器内部手势（PagerView 翻页、捏合、点按、ZoomableView 纵向 pan）同时识别。
        // 窗口级关闭手势仅通过 shouldBegin（严格竖向）约束自身，不抢占内容手势。
        // 覆盖视图已通过 SwiftUI .allowsHitTesting(false) 彻底透传触摸，
        // 因此内容手势可正常接收触摸并工作。
        true
    }

        private func ancestorScrollViews(from view: UIView?) -> [UIScrollView] {
            var scrollViews: [UIScrollView] = []
            var candidate = view
            while let current = candidate, current !== installedWindow {
                if let scrollView = current as? UIScrollView {
                    scrollViews.append(scrollView)
                }
                candidate = current.superview
            }
            return scrollViews
        }

        private func finishTrackingTouchedScrollView(didDismiss: Bool) {
            if MediaViewerDismissGesturePolicy.shouldRestoreTouchedScrollPosition(
                didDismiss: didDismiss
            ),
               let touchedZoomScrollView,
               let touchedZoomScrollViewInitialOffset {
                DispatchQueue.main.async { [weak touchedZoomScrollView] in
                    touchedZoomScrollView?.setContentOffset(
                        touchedZoomScrollViewInitialOffset,
                        animated: false
                    )
                }
            }
            touchedZoomScrollView = nil
            touchedVerticalScrollView = nil
            touchedZoomScrollViewInitialOffset = nil
        }
    }
}

private final class MediaViewerDismissGestureHostView: UIView {
    var onWindowChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChanged?()
    }

    // iOS 16/17 上 SwiftUI 会尊重此覆写让覆盖层透传触摸；iOS 15 的可靠透传
    // 由 SwiftUI 侧的 .allowsHitTesting(false) 保证（见 body 中对该宿主的使用）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}

private struct MediaViewerContextMenu: View {
    let media: any UiMedia
    let showsDownloadAll: Bool
    let isPreparingShare: Bool
    let onDownload: () -> Void
    let onDownloadAll: () -> Void
    let onShareImage: () -> Void
    let onCopyLink: () -> Void

    var body: some View {
        Button(action: onDownload) {
            Label {
                Text("media_menu_download", bundle: .main)
            } icon: {
                Image(fontAwesome: .download)
            }
        }

        if showsDownloadAll {
            Button(action: onDownloadAll) {
                Label {
                    Text("media_menu_download_all", bundle: .main)
                } icon: {
                    Image(fontAwesome: .download)
                }
            }
        }

        if case .image = onEnum(of: media) {
            Button(action: onShareImage) {
                Label {
                    Text("media_menu_share_image", bundle: .main)
                } icon: {
                    Image(fontAwesome: .shareNodes)
                }
            }
            .disabled(isPreparingShare)
        }

        Button(action: onCopyLink) {
            Label {
                Text("media_menu_copy_link", bundle: .main)
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
    }
}

private actor MediaViewerBatchSaveTracker {
    private var remainingCount: Int
    private var hasFailure = false

    init(count: Int) {
        remainingCount = count
    }

    func complete(success: Bool) -> Bool? {
        hasFailure = hasFailure || !success
        remainingCount -= 1
        guard remainingCount == 0 else {
            return nil
        }
        return !hasFailure
    }
}

private struct MediaPageSlider: View {
    let count: Int
    @Binding var page: Int

    var body: some View {
        let maxPage = max(count - 1, 0)
        let displayedPage = clampedPage(page, maxPage: maxPage)

        HStack(spacing: 10) {
            Text(verbatim: "\(displayedPage + 1)")
                .frame(minWidth: 24, alignment: .trailing)

            Slider(
                value: Binding(
                    get: {
                        Double(displayedPage)
                    },
                    set: { newValue in
                        page = clampedPage(Int(newValue.rounded()), maxPage: maxPage)
                    }
                ),
                in: 0...Double(maxPage),
                step: 1
            )
            .accessibilityLabel(
                Text("media_page_position", bundle: .main)
            )
            .accessibilityValue(Text(verbatim: "\(displayedPage + 1) of \(count)"))

            Text(verbatim: "\(count)")
                .frame(minWidth: 24, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .frame(minWidth: 220, maxWidth: 360)
    }

    private func clampedPage(_ value: Int, maxPage: Int) -> Int {
        min(max(value, 0), maxPage)
    }
}

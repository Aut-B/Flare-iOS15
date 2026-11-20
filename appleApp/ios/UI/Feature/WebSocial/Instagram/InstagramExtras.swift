import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine
import Drops
import FlareAppleCore
import FlareAppleUI
import KotlinSharedUI

/// Instagram 的 CDN 视频同样会校验 Referer / UA / 登录 cookie。
/// 直接 `AVPlayer(url:)` 在 6s 上就是一直转圈，所以统一从这里造播放器。
enum IGVideoFactory {
    static func player(for urlString: String) -> AVPlayer? {
        guard let url = URL(string: urlString) else { return nil }
        var headers: [String: String] = [
            "Referer": "https://www.instagram.com/",
            "User-Agent": WebPlatformUserAgent.desktop,
        ]
        let cookie = InstagramStore.shared.cookie
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        // 用字符串 key：`AVURLAssetHTTPHeaderFieldsKey` 在部分 SDK 里不是
        // Swift 可见符号，直接引用会编译失败。
        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = false
        return player
    }
}

/// 轻量提示。Instagram 的点赞 / 评论失败时用，免得整页弹一个 alert。
enum IGToast {
    static func error(_ text: String) {
        Drops.show(.init(title: text, icon: UIImage(fontAwesome: .circleExclamation)))
    }

    static func success(_ text: String) {
        Drops.show(.init(title: text, icon: UIImage(fontAwesome: .circleCheck)))
    }
}

/// Instagram 正文和项目里的时间线共用同一套翻译 Presenter。
///
/// 设置里开了「自动翻译」就直接显示译文；没开时保留「翻译 / 显示原文」按钮，
/// 不需要用户离开 App 去复制文本。
struct IGCaptionView: View {
    let text: String
    var fontSize: CGFloat = 14
    var lineLimit: Int? = nil
    var onOpen: (() -> Void)? = nil

    @Environment(\.translateConfig) private var translateConfig
    @State private var showTranslation = false

    private var shouldTranslate: Bool {
        translateConfig.preTranslate || showTranslation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if shouldTranslate {
                IGTranslatedText(text: text, fontSize: fontSize, lineLimit: lineLimit)
                    .id(text)
                if translateConfig.showOriginalWithTranslation {
                    originalText
                }
            } else {
                originalText
            }
            if !translateConfig.preTranslate {
                Button(showTranslation ? "显示原文" : "翻译") {
                    showTranslation.toggle()
                }
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var originalText: some View {
        Text(text)
            .font(.system(size: fontSize))
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
    }
}

private struct IGTranslatedText: View {
    let text: String
    let fontSize: CGFloat
    let lineLimit: Int?

    @StateObject private var presenter: KotlinPresenter<UiState<UiRichText>>

    init(text: String, fontSize: CGFloat, lineLimit: Int?) {
        self.text = text
        self.fontSize = fontSize
        self.lineLimit = lineLimit
        _presenter = StateObject(
            wrappedValue: KotlinPresenter(
                presenter: TranslatePresenter(
                    source: Self.richText(text),
                    targetLanguage: flareCurrentLanguageCode
                )
            )
        )
    }

    var body: some View {
        StateView(state: presenter.state) { translated in
            RichText(text: translated)
                .font(.system(size: fontSize))
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } errorContent: { error in
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: fontSize))
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                Text("翻译失败：\(error.message ?? "未知错误")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } loadingContent: {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("翻译中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func richText(_ text: String) -> UiRichText {
        UiRichText(
            renderRuns: [
                RenderContent.Text(
                    runs: [
                        RenderRun.Text(
                            text: text,
                            style: RenderTextStyle(
                                link: nil,
                                bold: false,
                                italic: false,
                                strikethrough: false,
                                monospace: false,
                                code: false,
                                underline: false,
                                small: false,
                                time: false,
                                imageLink: nil
                            )
                        ),
                    ],
                    block: RenderBlockStyle()
                ),
            ],
            isRtl: false,
            raw: text,
            innerText: text,
            imageUrls: []
        )
    }
}

/// 内联 IG 视频的音频会话持有者。
///
/// App 启动时 `FlareApp` 把会话固定为 `.ambient`（尊重静音拨片、可与其他
/// App 混音）。只有视频真正开始播放时才通过 `AudioSessionManager` 的引用
/// 计数切到 `.playback`，暂停 / 离场 / 交给全屏播放器时立刻归还，避免 IG
/// 把整个 App 永久留在 `.playback` 并掐断后台音乐。
@MainActor
final class IGVideoAudioController: ObservableObject {
    private var subscription: AnyCancellable?
    private var holdsSession = false
    private var suspendedForFullscreen = false
    private var lastPlaying = false

    func watch(_ player: AVPlayer) {
        subscription = player.publisher(for: \.timeControlStatus, options: [.initial])
            .sink { @Sendable [weak self] status in
                let playing = status != .paused
                Task { @MainActor [weak self] in
                    self?.update(playing: playing)
                }
            }
    }

    /// 全屏播放器接管前调用：先归还会话，全屏期间忽略内联播放器状态。
    func suspendForFullscreen(_ player: AVPlayer) {
        suspendedForFullscreen = true
        player.pause()
        lastPlaying = false
        setHolding(false)
    }

    /// 全屏退出后恢复观察，内联播放器仍保持暂停。
    func resumeAfterFullscreen() {
        suspendedForFullscreen = false
        setHolding(lastPlaying)
    }

    func stop(_ player: AVPlayer) {
        subscription = nil
        suspendedForFullscreen = false
        player.pause()
        setHolding(false)
    }

    private func update(playing: Bool) {
        lastPlaying = playing
        guard !suspendedForFullscreen else { return }
        setHolding(playing)
    }

    private func setHolding(_ holding: Bool) {
        guard holding != holdsSession else { return }
        holdsSession = holding
        if holding {
            AudioSessionManager.shared.beginPlayback()
        } else {
            AudioSessionManager.shared.endPlayback()
        }
    }
}

/// 视频播放。`VideoPlayer` 自带播放 / 进度 / 全屏控件，够用。
struct IGVideoPlayer: View {
    let url: String
    var autoPlay: Bool = true
    /// 全屏画廊里本身就是全屏，再放一个全屏键会和关闭键叠在一起。
    var showsFullscreenButton: Bool = true

    @State private var player: AVPlayer?
    @StateObject private var audio = IGVideoAudioController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player = player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(.white)
            }
            if showsFullscreenButton {
                Button {
                    // 全屏那个播放器会自己播，这里先停掉，免得两路声音叠在一起。
                    let position = player?.currentTime().seconds ?? 0
                    if let player {
                        audio.suspendForFullscreen(player)
                    }
                    let presented = IGFullscreenVideoPresenter.present(url: url, from: position) { [weak audio] in
                        audio?.resumeAfterFullscreen()
                    }
                    if !presented {
                        // 没弹出来就别把内联播放器挂起，否则用户点播放也不会有声音。
                        audio.resumeAfterFullscreen()
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("全屏播放")
            }
        }
        .onAppear {
            guard player == nil, let created = IGVideoFactory.player(for: url) else { return }
            audio.watch(created)
            player = created
            if autoPlay {
                created.play()
            }
        }
        .onDisappear {
            if let player {
                audio.stop(player)
            }
            player = nil
        }
    }
}

/// 直接铺一个系统全屏播放器。
///
/// 帖子详情本身就在 sheet 里，再叠 SwiftUI 的 `fullScreenCover` 在 iOS 15
/// 上有概率点了不弹（或被父级 presentation 吃掉）。这里改成从当前最上层
/// controller 直接 present，绕开 SwiftUI 的 presentation 链。
/// 全屏播放器在真正出现时申请音频会话，消失时归还；
/// 这样 presentation 失败也不会留下孤立的 `.playback` 持有。
@MainActor
private final class IGFullscreenPlayerViewController: AVPlayerViewController {
    var onFinish: (@MainActor () -> Void)?
    private var holdsSession = false
    private var didFinish = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !holdsSession else { return }
        holdsSession = true
        AudioSessionManager.shared.beginPlayback()
        player?.play()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if holdsSession {
            holdsSession = false
            player?.pause()
            AudioSessionManager.shared.endPlayback()
        }
        guard !didFinish else { return }
        didFinish = true
        onFinish?()
    }
}

@MainActor
enum IGFullscreenVideoPresenter {
    @discardableResult
    static func present(url: String, from seconds: Double, onFinish: (@MainActor () -> Void)? = nil) -> Bool {
        guard let host = topViewController() else {
            print("IG fullscreen: no foreground view controller")
            return false
        }
        guard let player = IGVideoFactory.player(for: url) else {
            print("IG fullscreen: invalid video url")
            return false
        }
        let controller = IGFullscreenPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.modalPresentationStyle = .fullScreen
        controller.onFinish = onFinish
        if seconds.isFinite, seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        host.present(controller, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let navigation = controller as? UINavigationController {
            controller = navigation.visibleViewController ?? navigation
        }
        if let tabs = controller as? UITabBarController {
            controller = tabs.selectedViewController ?? tabs
        }
        return controller
    }
}

/// Instagram 图片缓存。
///
/// `AsyncImage` 不认 Instagram 图床的 UA / Referer，也不做跨页面缓存：
/// 6s 上表现就是「一直灰着 / 滚回来又重下」。这里和 `XhsImageCache` 一样
/// 用 NSCache + URLCache，并带上桌面 UA、Referer 和登录 cookie。
final class IGImageCache {
    static let shared = IGImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024,
            diskPath: "ig-images"
        )
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func image(for url: String, completion: @escaping (UIImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSString) {
            completion(cached)
            return
        }
        if waiters[url] != nil {
            waiters[url]?.append(completion)
            return
        }
        waiters[url] = [completion]
        load(url, original: url, withCookie: false)
    }

    /// 首屏先并发拉前几张封面。只预取封面、不预取轮播里的全部子图，
    /// 免得登录后刚拿到时间线就把 6S 的网络和图片解码占满。
    func prefetch(_ urls: [String], limit: Int = 4) {
        for url in urls.prefix(limit) where !url.isEmpty {
            if cache.object(forKey: url as NSString) == nil {
                image(for: url) { _ in }
            }
        }
    }

    /// 图床是带签名的 CDN 直链，通常不需要网页 cookie。以前先带整段
    /// Instagram cookie，6S 上经常会卡到超时才回落；现在先无 cookie 取，
    /// 失败再带 cookie 重试，私密账号的图仍然能显示。
    private func load(_ raw: String, original: String, withCookie: Bool) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        guard let target = URL(string: value) else {
            finish(original, image: nil)
            return
        }
        var request = URLRequest(url: target)
        request.setValue(WebPlatformUserAgent.desktop, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if withCookie {
            let cookie =
                InstagramStore.shared.cookie
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        session.dataTask(with: request) { [weak self] data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if image == nil, !withCookie, !InstagramStore.shared.cookie.isEmpty {
                    self.load(raw, original: original, withCookie: true)
                    return
                }
                self.finish(original, image: image)
            }
        }.resume()
    }

    private func finish(_ url: String, image: UIImage?) {
        if let image = image {
            cache.setObject(image, forKey: url as NSString)
        }
        let list = waiters[url] ?? []
        waiters[url] = nil
        for item in list {
            item(image)
        }
    }
}

/// 全屏看图：左右翻页 + 双指放大 + 直接存原图。
struct IGImageGalleryView: View {
    let items: [IGMediaItem]
    let caption: String

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(items: [IGMediaItem], startIndex: Int, caption: String = "") {
        self.items = items
        self.caption = caption
        let bounded = min(max(startIndex, 0), max(items.count - 1, 0))
        _index = State(initialValue: bounded)
    }

    init(images: [String], startIndex: Int, caption: String = "") {
        self.init(
            items: images.map {
                IGMediaItem(id: $0, image: $0, video: nil, aspect: 1)
            },
            startIndex: startIndex,
            caption: caption
        )
    }

    private var currentItem: IGMediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    Group {
                        if let video = item.video {
                            IGVideoPlayer(
                                url: video,
                                autoPlay: false,
                                showsFullscreenButton: false
                            )
                        } else {
                            IGZoomableImage(url: item.image ?? "")
                        }
                    }
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    if currentItem?.image != nil {
                        Button {
                            save()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer(minLength: 0)

                if items.count > 1 {
                    Text("\(index + 1) / \(items.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard let image = currentItem?.image, !image.isEmpty else { return }
        MediaSaver.shared.saveImages([MediaImageSaveItem(url: image)])
    }
}

/// 单张可缩放的图。双击在 1x / 2.5x 之间切，捏合到 4x，放大后可拖动。
struct IGZoomableImage: View {
    let url: String

    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                guard scale > 1 else { return }
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                            if scale == 1 {
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let cached = IGImageCache.shared.cached(url) {
            image = cached
            return
        }
        IGImageCache.shared.image(for: url) { loaded in
            if let loaded = loaded {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// 系统分享面板（转发到微信 / 复制链接 / 存到文件都走它）。
struct IGShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 点赞按钮。状态统一从 `InstagramStore` 读：Store 先乐观更新，失败再回滚，
/// 时间线和详情里的同一篇帖子不会各翻各的。
struct IGLikeButton: View {
    let media: IGMedia
    var showsCount: Bool = true

    @ObservedObject private var store = InstagramStore.shared
    @State private var busy = false

    init(media: IGMedia, showsCount: Bool = true) {
        self.media = media
        self.showsCount = showsCount
    }

    private var state: IGLikeState { store.likeState(for: media) }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.liked ? "heart.fill" : "heart")
                    .foregroundStyle(state.liked ? Color.red : Color.primary)
                if showsCount {
                    Text("\(state.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(state.liked ? "取消点赞" : "点赞")
    }

    private func toggle() {
        guard !busy else { return }
        let target = !state.liked
        busy = true
        Task {
            do {
                if target {
                    try await store.likePost(media)
                } else {
                    try await store.unlikePost(media)
                }
            } catch {
                IGToast.error(error.localizedDescription)
            }
            busy = false
        }
    }
}

/// 帖子底部的一排操作：点赞 / 评论 / 转发 / 保存 / 更多。
struct IGActionBar: View {
    let media: IGMedia
    /// 点评论：详情页用来聚焦输入框，列表里用来打开详情。
    var onComment: (() -> Void)? = nil
    /// 点「更多」：列表里打开详情；详情页不传就不显示。
    var onMore: (() -> Void)? = nil

    @State private var showShare = false

    var body: some View {
        HStack(spacing: 18) {
            IGLikeButton(media: media)

            Button {
                onComment?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                    Text("\(media.commentCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("评论")

            Button {
                showShare = true
            } label: {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("转发")

            Spacer(minLength: 0)

            Button {
                saveImages()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("保存图片")

            if let onMore = onMore {
                Button {
                    onMore()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showShare) {
            IGShareSheet(items: shareItems)
        }
    }

    private var shareItems: [Any] {
        var items: [Any] = []
        if let url = URL(string: media.webURL) {
            items.append(url)
        }
        if let cover = media.cover, let url = URL(string: cover) {
            items.append(url)
        }
        return items
    }

    private func saveImages() {
        let urls = media.images
        guard !urls.isEmpty else { return }
        MediaSaver.shared.saveImages(urls.map { MediaImageSaveItem(url: $0) })
    }
}

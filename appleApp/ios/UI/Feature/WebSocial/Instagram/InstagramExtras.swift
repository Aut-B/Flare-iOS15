import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Drops
import FlareAppleCore
import FlareAppleUI

/// 轻量提示。Instagram 的点赞 / 评论失败时用，免得整页弹一个 alert。
enum IGToast {
    static func error(_ text: String) {
        Drops.show(.init(title: text, icon: UIImage(fontAwesome: .circleExclamation)))
    }

    static func success(_ text: String) {
        Drops.show(.init(title: text, icon: UIImage(fontAwesome: .circleCheck)))
    }
}

/// 视频播放。`VideoPlayer` 自带播放 / 进度 / 全屏控件，够用。
struct IGVideoPlayer: View {
    let url: String
    var autoPlay: Bool = true

    @State private var player: AVPlayer?
    @State private var fullscreen = false

    var body: some View {
        ZStack {
            Color.black
            if let player = player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                // 全屏那个播放器会自己播，这里先停掉，免得两路声音叠在一起。
                player?.pause()
                fullscreen = true
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
        .fullScreenCover(isPresented: $fullscreen, onDismiss: {
            if autoPlay {
                player?.play()
            }
        }) {
            IGFullscreenVideo(url: url)
        }
        .onAppear {
            guard player == nil, let target = URL(string: url) else { return }
            let created = AVPlayer(url: target)
            player = created
            if autoPlay {
                created.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

/// 全屏播放：铺一个系统 `AVPlayerViewController`，进度条 / 音量 / 画中画都在。
struct IGFullscreenVideo: View {
    let url: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            IGPlayerControllerView(url: url)
                .ignoresSafeArea()
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
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .preferredColorScheme(.dark)
    }
}

private struct IGPlayerControllerView: UIViewControllerRepresentable {
    let url: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        if let target = URL(string: url) {
            let player = AVPlayer(url: target)
            controller.player = player
            player.play()
        }
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// 全屏看图：左右翻页 + 双指放大 + 直接存原图。
struct IGImageGalleryView: View {
    let images: [String]
    let caption: String

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int

    init(images: [String], startIndex: Int, caption: String = "") {
        self.images = images
        self.caption = caption
        let bounded = min(max(startIndex, 0), max(images.count - 1, 0))
        _index = State(initialValue: bounded)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { offset, url in
                    IGZoomableImage(url: url)
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
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer(minLength: 0)

                if images.count > 1 {
                    Text("\(index + 1) / \(images.count)")
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
        guard images.indices.contains(index) else { return }
        MediaSaver.shared.saveImages([MediaImageSaveItem(url: images[index])])
    }
}

/// 单张可缩放的图。双击在 1x / 2.5x 之间切，捏合到 4x，放大后可拖动。
struct IGZoomableImage: View {
    let url: String

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: URL(string: url)) { phase in
                if let image = phase.image {
                    image
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
                } else if phase.error != nil {
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

/// 点赞按钮。先改本地状态再发请求，失败回滚 —— 点赞必须立刻有反馈。
struct IGLikeButton: View {
    let media: IGMedia
    var showsCount: Bool = true

    @State private var liked: Bool
    @State private var count: Int
    @State private var busy = false

    init(media: IGMedia, showsCount: Bool = true) {
        self.media = media
        self.showsCount = showsCount
        _liked = State(initialValue: media.hasLiked)
        _count = State(initialValue: media.likeCount)
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? Color.red : Color.primary)
                if showsCount {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(liked ? "取消点赞" : "点赞")
    }

    private func toggle() {
        guard !busy else { return }
        let target = !liked
        busy = true
        liked = target
        count = max(0, count + (target ? 1 : -1))
        Task {
            do {
                try await InstagramService.shared.setLiked(target, mediaId: media.id)
            } catch {
                liked = !target
                count = max(0, count + (target ? -1 : 1))
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

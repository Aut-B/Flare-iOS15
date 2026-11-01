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

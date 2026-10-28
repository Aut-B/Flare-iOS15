import SwiftUI
import UIKit
import Kingfisher
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI

// MARK: - 预加载好的图片
//
// 离屏渲染时 KFImage 的异步加载不一定来得及，截出来就是灰色占位块。
// 这里先把所有图片下载好塞进环境，渲染时直接用 UIImage 画，绝不会出现灰块。

private struct ScreenshotImageStoreKey: EnvironmentKey {
    static let defaultValue: [String: UIImage] = [:]
}

extension EnvironmentValues {
    var screenshotImages: [String: UIImage] {
        get { self[ScreenshotImageStoreKey.self] }
        set { self[ScreenshotImageStoreKey.self] = newValue }
    }
}

enum ScreenshotImageLoader {
    static func load(urls: [URL]) async -> [String: UIImage] {
        let unique = Array(Set(urls))
        guard !unique.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, UIImage?).self) { group in
            for url in unique {
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<(String, UIImage?), Never>) in
                        KingfisherManager.shared.retrieveImage(
                            with: url,
                            options: [.backgroundDecode]
                        ) { result in
                            switch result {
                            case .success(let value):
                                continuation.resume(returning: (url.absoluteString, value.image))
                            case .failure:
                                continuation.resume(returning: (url.absoluteString, nil))
                            }
                        }
                    }
                }
            }
            var images: [String: UIImage] = [:]
            for await (key, image) in group {
                if let image {
                    images[key] = image
                }
            }
            return images
        }
    }
}

/// 长截图版式：把「贴文正文 + 全部配图（整张显示，不裁剪）+ 引用的微博 + 选中的评论」
/// 合成到一张竖图里，效果类似 VVebo 的微博截图。
///
/// 只用于离屏渲染，不参与交互，所以这里不处理点击、不做行数限制。
struct ScreenshotPostView: View {
    let item: UiTimelineV2
    let comments: [UiTimelineV2]
    var contentWidth: CGFloat = 390
    var showsCard: Bool = true

    var body: some View {
        if showsCard {
            content
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(18)
                .background(Color(.systemGroupedBackground))
        } else {
            content
                .background(Color(.systemBackground))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenshotPostBlock(item: item, depth: 0)
            if !comments.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<comments.count, id: \.self) { index in
                        ScreenshotCommentRow(data: comments[index])
                    }
                }
            }
            ScreenshotCountsRow(actions: actionsOf(item))
        }
        .padding(16)
        .frame(width: contentWidth, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func actionsOf(_ item: UiTimelineV2) -> [ActionMenu] {
        guard let post = StatusShareSheet.postOf(item) else { return [] }
        return Array(post.actions)
    }
}

// MARK: - 一条微博

private struct ScreenshotPostBlock: View {
    let item: UiTimelineV2
    let depth: Int

    var body: some View {
        if let post = StatusShareSheet.postOf(item) {
            VStack(alignment: .leading, spacing: 10) {
                ScreenshotPostHeader(post: post, compact: depth > 0)
                if !post.content.original.isEmpty {
                    RichText(text: post.content.original)
                        .font(.system(size: depth > 0 ? 14 : 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScreenshotMediaStack(images: Array(post.images))
                if depth == 0 {
                    ForEach(0..<quotedPosts.count, id: \.self) { index in
                        ScreenshotQuoteCard(post: quotedPosts[index])
                    }
                }
            }
        }
    }

    /// 转发的原微博（微博的 retweetedStatus 会被映射成 quotes）。
    private var quotedPosts: [UiTimelineV2.Post] {
        if case .timelinePostItem(let wrapped) = onEnum(of: item) {
            return Array(wrapped.presentation.quotes)
        }
        return []
    }
}

private struct ScreenshotPostHeader: View {
    let post: UiTimelineV2.Post
    let compact: Bool

    private var avatarSize: CGFloat { compact ? 30 : 40 }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ScreenshotAvatar(
                url: post.user?.avatar?.url,
                customHeaders: post.user?.avatar?.customHeaders,
                size: avatarSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(post.user?.name.innerText ?? "")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let handle = post.user?.handle.canonical, !handle.isEmpty {
                        Text("@\(handle)")
                            .lineLimit(1)
                    }
                    if let location = post.ipLocation, !location.isEmpty {
                        Text(location)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            DateTimeText(data: post.createdAt, fullTime: true)
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 配图（整张显示，不裁剪）

private struct ScreenshotAvatar: View {
    let url: String?
    let customHeaders: [String: String]?
    let size: CGFloat

    @Environment(\.screenshotImages) private var images

    var body: some View {
        Group {
            if let url, let image = images[url] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarView(data: url, customHeader: customHeaders)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct ScreenshotMediaStack: View {
    let images: [any UiMedia]

    @Environment(\.screenshotImages) private var loadedImages

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<images.count, id: \.self) { index in
                    mediaView(images[index])
                }
            }
        }
    }

    @ViewBuilder
    private func mediaView(_ media: any UiMedia) -> some View {
        switch onEnum(of: media) {
        case .image(let image):
            let source = image.url.isEmpty ? image.previewUrl : image.url
            mediaImage(source: source, customHeaders: image.customHeaders, ratio: image.aspectRatio)
        case .gif(let gif):
            let source = gif.url.isEmpty ? gif.previewUrl : gif.url
            mediaImage(source: source, customHeaders: gif.customHeaders, ratio: gif.aspectRatio)
        case .video(let video):
            ZStack {
                mediaImage(source: video.thumbnailUrl, customHeaders: video.customHeaders, ratio: video.aspectRatio)
                Image(fontAwesome: .circlePlay)
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
        case .ugoira(let ugoira):
            mediaImage(source: ugoira.previewUrl, customHeaders: ugoira.customHeaders, ratio: ugoira.aspectRatio)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaImage(source: String, customHeaders: [String: String]?, ratio: Float) -> some View {
        Group {
            if let image = loadedImages[source] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                NetworkImage(data: source, customHeader: customHeaders, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(Self.ratio(ratio), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 微博给的尺寸偶尔是 0，兜一个 1:1，避免除零把高度算成无穷大。
    private static func ratio(_ value: Float) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return CGFloat(min(max(value, 0.15), 8))
    }
}

// MARK: - 引用的微博

private struct ScreenshotQuoteCard: View {
    let post: UiTimelineV2.Post

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScreenshotPostHeader(post: post, compact: true)
            if !post.content.original.isEmpty {
                RichText(text: post.content.original)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScreenshotMediaStack(images: Array(post.images))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 评论行

private struct ScreenshotCommentRow: View {
    let data: UiTimelineV2

    var body: some View {
        if let post = StatusShareSheet.postOf(data) {
            HStack(alignment: .top, spacing: 8) {
                ScreenshotAvatar(
                    url: post.user?.avatar?.url,
                    customHeaders: post.user?.avatar?.customHeaders,
                    size: 22
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.user?.name.innerText ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !post.content.original.isEmpty {
                        RichText(text: post.content.original)
                            .font(.system(size: 12))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 底部互动数（转发 / 评论 / 赞）

private struct ScreenshotCountsRow: View {
    let actions: [ActionMenu]

    var body: some View {
        let items = flattened
        if !items.isEmpty {
            HStack(spacing: 20) {
                ForEach(0..<items.count, id: \.self) { index in
                    HStack(spacing: 5) {
                        StatusActionIcon(icon: items[index].icon)
                        Text(items[index].count?.humanized ?? "")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    private var flattened: [ActionMenu.Item] {
        var result: [ActionMenu.Item] = []
        for action in actions {
            switch onEnum(of: action) {
            case .item(let item):
                appendIfCountable(item, into: &result)
            case .group(let group):
                for nested in group.actions {
                    if case .item(let item) = onEnum(of: nested) {
                        appendIfCountable(item, into: &result)
                    }
                }
            case .divider:
                break
            }
        }
        return result
    }

    private func appendIfCountable(_ item: ActionMenu.Item, into result: inout [ActionMenu.Item]) {
        guard item.count != nil, item.actionFamily != .screenshot else { return }
        result.append(item)
    }
}

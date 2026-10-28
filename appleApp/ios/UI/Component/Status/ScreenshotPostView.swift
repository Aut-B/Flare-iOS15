import SwiftUI
import UIKit
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI

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
            AvatarView(data: post.user?.avatar?.url, customHeader: post.user?.avatar?.customHeaders)
                .frame(width: avatarSize, height: avatarSize)
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

private struct ScreenshotMediaStack: View {
    let images: [any UiMedia]

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
            NetworkImage(data: source, customHeader: image.customHeaders, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .aspectRatio(Self.ratio(image.aspectRatio), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .gif(let gif):
            let source = gif.url.isEmpty ? gif.previewUrl : gif.url
            NetworkImage(data: source, customHeader: gif.customHeaders, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .aspectRatio(Self.ratio(gif.aspectRatio), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .video(let video):
            ZStack {
                NetworkImage(data: video.thumbnailUrl, customHeader: video.customHeaders, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(Self.ratio(video.aspectRatio), contentMode: .fit)
                Image(fontAwesome: .circlePlay)
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .ugoira(let ugoira):
            NetworkImage(data: ugoira.previewUrl, customHeader: ugoira.customHeaders, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .aspectRatio(Self.ratio(ugoira.aspectRatio), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        default:
            EmptyView()
        }
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
                AvatarView(data: post.user?.avatar?.url, customHeader: post.user?.avatar?.customHeaders)
                    .frame(width: 22, height: 22)
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

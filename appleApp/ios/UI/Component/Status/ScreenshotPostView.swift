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
    /// 渲染时单张图的宽度上限。
    ///
    /// 截图是按满宽（约 358pt）显示的，最终输出宽度按 1080px 起算，所以这里
    /// 留 1.3 倍余量取 1400 —— 二次缩放不会糊。之前取 1200 是按九宫格单格
    /// 大小定的，改成满宽铺排后就不够了。
    private static let maxPixelWidth: CGFloat = 1400

    /// 单张图的高度上限。只对超长竖图（长截图、漫画条）生效，避免一张图
    /// 就吃掉几十 MB。
    private static let maxPixelHeight: CGFloat = 12000

    /// 同时下载的图片数。
    ///
    /// 之前是几十张图一起打出去，TCP 连接互相抢带宽、解码线程也互相抢占，
    /// 反而比排队慢，峰值内存还不可控。
    private static let maxConcurrentLoads = 6

    /// **同步**从 Kingfisher 内存缓存里取图。
    ///
    /// 时间线刚刚把这条微博的配图都显示过一遍，这些 UIImage 就躺在内存缓存里，
    /// 一次查表就能拿到，不需要网络、不需要解码。这是「像 VVebo 一样立刻出图」
    /// 的关键：第一帧先用手上已有的图渲染，别等下载。
    static func cached(urls: [URL]) -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for url in Set(urls) {
            let key = url.absoluteString
            guard result[key] == nil else { continue }
            if let image = ImageCache.default.retrieveImageInMemoryCache(forKey: key) {
                result[key] = downsampleIfNeeded(image)
            }
        }
        return result
    }

    /// 把内存缓存里没有的补齐。
    ///
    /// **故意不加 `DownsamplingImageProcessor`**：Kingfisher 的缓存 key 会带上
    /// 处理器的标识，一旦加了处理器，时间线里已经下载过的图会全部 miss、
    /// 重新走一遍网络——这正是之前「图多的时候要渲染半天」的原因。
    /// 不加处理器时 key 就是 URL 本身，能和 `KFImage` 共用同一份磁盘缓存。
    ///
    /// `headers` 按 URL 给请求加头（微博原图、毛象媒体都需要 Referer）。
    /// 时间线里的 `KFImage` 一直带着这些头，截图这边之前漏了，导致原图
    /// 请求被拒、只能退到 600px 的缩略图。
    static func load(
        urls: [URL],
        skipping: Set<String> = [],
        headers: [String: [String: String]] = [:]
    ) async -> [String: UIImage] {
        let unique = Array(Set(urls)).filter { !skipping.contains($0.absoluteString) }
        guard !unique.isEmpty else { return [:] }

        var images: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            var next = 0
            let initial = min(maxConcurrentLoads, unique.count)
            for index in 0..<initial {
                let url = unique[index]
                group.addTask { await fetch(url, headers: headers[url.absoluteString]) }
            }
            next = initial

            while let (key, image) = await group.next() {
                if let image {
                    images[key] = downsampleIfNeeded(image)
                }
                if next < unique.count {
                    let url = unique[next]
                    next += 1
                    group.addTask { await fetch(url, headers: headers[url.absoluteString]) }
                }
            }
        }
        return images
    }

    private static func fetch(
        _ url: URL,
        headers: [String: String]?
    ) async -> (String, UIImage?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(String, UIImage?), Never>) in
            var options: KingfisherOptionsInfo = [.backgroundDecode]
            if let headers, !headers.isEmpty {
                let modifier = AnyModifier { request in
                    var request = request
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    return request
                }
                options.append(.requestModifier(modifier))
            }
            KingfisherManager.shared.retrieveImage(with: url, options: options) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (url.absoluteString, value.image))
                case .failure:
                    continuation.resume(returning: (url.absoluteString, nil))
                }
            }
        }
    }

    /// 超大图在内存里缩一次。
    ///
    /// 按**宽度**约束而不是最长边：图在截图里是满宽铺开的，宽度才决定清晰度。
    /// 之前按最长边算，3000×4000 的竖图被缩成 1050×1400，宽度反而不够输出
    /// 1080px，白缩一次还更糊。
    private static func downsampleIfNeeded(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0 else {
            return image
        }
        let ratio = min(maxPixelWidth / pixelWidth, maxPixelHeight / pixelHeight, 1)
        // 只缩一点点的话不值得重绘，直接原样用。
        guard ratio < 0.85 else { return image }
        let target = CGSize(
            width: max((pixelWidth * ratio).rounded(), 1),
            height: max((pixelHeight * ratio).rounded(), 1)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
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
        let innerWidth = contentWidth - 32
        return VStack(alignment: .leading, spacing: 14) {
            ScreenshotPostBlock(item: item, depth: 0, contentWidth: innerWidth)
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
    let contentWidth: CGFloat

    var body: some View {
        if let post = StatusShareSheet.postOf(item) {
            VStack(alignment: .leading, spacing: 10) {
                ScreenshotPostHeader(post: post, compact: depth > 0)
                if !post.content.original.isEmpty {
                    RichText(text: post.content.original)
                        .font(.system(size: depth > 0 ? 14 : 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScreenshotMediaStack(images: Array(post.images), width: contentWidth)
                if depth == 0 {
                    ForEach(0..<quotedPosts.count, id: \.self) { index in
                        ScreenshotQuoteCard(post: quotedPosts[index], contentWidth: contentWidth - 24)
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

/// 配图区：**每张图都单独占满整行宽度**，按原比例纵向依次排下来。
///
/// 之前多图走九宫格，三张竖图被压成三个窄条，图里的字根本看不清 ——
/// 这正是「这能看清图里啥啊」。VVebo 的截图是多图也一张一张全宽铺开：
/// 截图会很长，但每张图都保持原比例、都是能看清的。
///
/// 比例优先取自**已经加载好的 UIImage**，而不是接口里的 `aspectRatio`：
/// 微博的多图帖子经常不返回图片宽高，`UiMedia.aspectRatio` 就退化成 1:1，
/// 竖图会被排成正方形。加载不到图时再退回接口给的字段。
///
/// 宽高都显式算出来（`frame(width:height:)`）：只给宽度再叠 `aspectRatio`
/// 时，父视图提的是 nil 高度，SwiftUI 会退回子视图的 ideal size，比例不保证生效。
/// 每张图按原比例完整显示，不裁切、不限张数 —— 用户要的是「什么图都存全」。
private struct ScreenshotMediaStack: View {
    let images: [any UiMedia]
    let width: CGFloat

    @Environment(\.screenshotImages) private var loadedImages

    private let spacing: CGFloat = 8

    /// 整张截图的配图区最多这么高（pt）。九张 1:10 的超长图全宽铺开能到三万多 pt，
    /// `UIGraphicsImageRenderer` 会画不出来，所以超过上限时把所有图等比缩窄。
    private static let maxTotalHeight: CGFloat = 12000

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(0..<images.count, id: \.self) { index in
                    tile(images[index], width: itemWidth, corner: images.count == 1 ? 12 : 10)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// 正常情况就是满宽。只有总高爆掉时才整体缩窄，保证还能画出来。
    private var itemWidth: CGFloat {
        guard images.count > 1 else { return width }
        let total =
            images.reduce(CGFloat(0)) { partial, media in
                partial + width / displayRatio(media, source: sourceOf(media))
            } + spacing * CGFloat(images.count - 1)
        guard total.isFinite, total > Self.maxTotalHeight else { return width }
        return max(width * (Self.maxTotalHeight / total), 40)
    }

    private func tile(_ media: any UiMedia, width: CGFloat, corner: CGFloat) -> some View {
        let source = sourceOf(media)
        let ratio = displayRatio(media, source: source)
        return content(media, source: source, corner: corner)
            .frame(width: width, height: max(width / ratio, 1))
    }

    @ViewBuilder
    private func content(
        _ media: any UiMedia,
        source: String,
        corner: CGFloat
    ) -> some View {
        Group {
            if let image = loadedImages[source] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                NetworkImage(data: source, customHeader: headersOf(media), contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if case .video(_) = onEnum(of: media) {
                Image(fontAwesome: .circlePlay)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
        }
    }

    private func sourceOf(_ media: any UiMedia) -> String {
        switch onEnum(of: media) {
        case .image(let image):
            return resolvedSource(image.url, image.previewUrl)
        case .gif(let gif):
            return resolvedSource(gif.url, gif.previewUrl)
        case .video(let video):
            return video.thumbnailUrl
        case .ugoira(let ugoira):
            return resolvedSource(ugoira.previewUrl, ugoira.previewUrl)
        default:
            return ""
        }
    }

    private func headersOf(_ media: any UiMedia) -> [String: String]? {
        switch onEnum(of: media) {
        case .image(let image): return image.customHeaders
        case .gif(let gif): return gif.customHeaders
        case .video(let video): return video.customHeaders
        case .ugoira(let ugoira): return ugoira.customHeaders
        default: return nil
        }
    }

    /// 原图还没到位时先用缩略图顶上：时间线里显示的就是缩略图，它一定在内存
    /// 缓存里。这样第一帧就能出真图，而不是等原图下载完才有内容。
    private func resolvedSource(_ primary: String, _ fallback: String) -> String {
        if !primary.isEmpty, loadedImages[primary] != nil { return primary }
        if !fallback.isEmpty, loadedImages[fallback] != nil { return fallback }
        return primary.isEmpty ? fallback : primary
    }

    /// 真实比例优先。UIImage 的 size 已经包含 orientation，竖图不会算成横的。
    private func displayRatio(_ media: any UiMedia, source: String) -> CGFloat {
        if let image = loadedImages[source],
           image.size.width > 0,
           image.size.height > 0 {
            return Self.ratio(Float(image.size.width / image.size.height))
        }
        return ratioOf(media)
    }

    private func ratioOf(_ media: any UiMedia) -> CGFloat {
        let value: Float =
            switch onEnum(of: media) {
            case .image(let image): image.aspectRatio
            case .gif(let gif): gif.aspectRatio
            case .video(let video): video.aspectRatio
            case .ugoira(let ugoira): ugoira.aspectRatio
            default: 1
            }
        return Self.ratio(value)
    }

    /// 微博给的尺寸偶尔是 0（多图帖尤其常见），兜一个 1:1，避免除零把高度算成无穷大。
    /// 上下限同时防止超长图把整张截图撑到画不出来。
    private static func ratio(_ value: Float) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return CGFloat(min(max(value, 0.1), 8))
    }
}

// MARK: - 引用的微博

private struct ScreenshotQuoteCard: View {
    let post: UiTimelineV2.Post
    let contentWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScreenshotPostHeader(post: post, compact: true)
            if !post.content.original.isEmpty {
                RichText(text: post.content.original)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScreenshotMediaStack(images: Array(post.images), width: contentWidth)
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

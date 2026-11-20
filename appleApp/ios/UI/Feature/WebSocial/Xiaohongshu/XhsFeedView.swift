import SwiftUI
import UIKit
import ImageIO

/// 小红书首页：真·瀑布流。
///
/// 数据来自 `XhsStore`（由隐藏网页把 homefeed 的响应搬回来），版式完全原生：
/// 每张卡片按图片真实宽高比算高度，新卡片放进「当前最矮」的那一列，
/// 这才是网页版那个错落感；按奇偶分两列只是看着像，图片一高一矮就穿帮。
struct XhsFeedView: View {
    @ObservedObject private var store = XhsStore.shared
    @State private var showLogin = false
    @State private var selected: XhsNote?
    @State private var userTarget: XhsUserTarget?
    @State private var actionError: String?
    /// 下拉刷新是否已经触发过，防止一次手势连发多次请求。
    @State private var pullArmed = true

    var body: some View {
        Group {
            if store.isLoggedIn {
                feed
            } else {
                loginPrompt
            }
        }
        .navigationTitle("小红书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 独立的刷新按钮：之前刷新藏在「头像 → 菜单」里，用户根本找不到。
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoggedIn {
                    Button {
                        Task { await store.retry() }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoading)
                    .accessibilityLabel("刷新")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoggedIn {
                    Menu {
                        Button {
                            store.setFollowing(false)
                        } label: {
                            Label("推荐", systemImage: "sparkles")
                        }
                        Button {
                            store.setFollowing(true)
                        } label: {
                            Label("关注", systemImage: "person.2")
                        }
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button {
                            // 空 id = 先调 selfinfo 拿自己的 id，再看自己的笔记。
                            userTarget = XhsUserTarget(id: "", name: "我的主页")
                        } label: {
                            Label("我的主页", systemImage: "person.circle")
                        }
                        Button(role: .destructive) {
                            store.logout()
                        } label: {
                            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            CookieLoginView(
                url: "https://www.xiaohongshu.com/login",
                title: "扫码登录小红书",
                userAgent: XhsSigner.desktopUserAgent,
                requiredCookieName: "web_session",
                cookieDomainSuffix: "xiaohongshu.com",
                // 重新登录必须先把旧会话清掉：不清的话网页认为「已经登录」，
                // 直接跳回首页，永远拿不到新的 web_session，sheet 就会一开一关。
                clearCookies: true,
                // 按 1280 宽排版再整体缩小：不这么做，手机 UA / 窄视口下
                // 小红书会渲染成手机版登录页，没有二维码，只能手机号收短信。
                desktopLayout: true,
                onCancel: { store.restoreSignerCookies() }
            ) { cookies in
                store.adopt(cookies: cookies)
                Task { await store.refresh() }
            }
        }
        .sheet(item: $selected) { note in
            NavigationView {
                XhsNoteView(note: note)
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $userTarget) { target in
            NavigationView {
                XhsUserView(userId: target.id, name: target.name, showsClose: true)
            }
            .navigationViewStyle(.stack)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await store.refreshIfNeeded()
        }
    }

    private var feed: some View {
        ScrollView {
            VStack(spacing: 0) {
                // iOS 15 的 ScrollView 没有 .refreshable，用偏移量自己判断下拉。
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: XhsPullOffsetKey.self,
                        value: proxy.frame(in: .named("xhsFeed")).minY
                    )
                }
                .frame(height: 0)

                if store.isLoading, store.notes.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在从网页版取首页…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if let message = store.errorMessage, store.notes.isEmpty {
                    errorState(message)
                } else {
                    VStack(spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, bucket in
                                column(bucket)
                            }
                        }
                        loadMoreFooter
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                }
            }
        }
        .coordinateSpace(name: "xhsFeed")
        .onPreferenceChange(XhsPullOffsetKey.self) { value in
            handlePull(value)
        }
    }

    /// 下拉超过 80pt 触发一次刷新；回弹到顶部附近才重新上膛，避免一次下拉连发。
    private func handlePull(_ offset: CGFloat) {
        if offset < 20 {
            pullArmed = true
            return
        }
        guard offset > 80, pullArmed, !store.isLoading else { return }
        pullArmed = false
        Task { await store.refresh() }
    }

    /// 按累计高度分列。列数跟着屏宽走：6s 竖屏两列，iPad 上三列。
    private var columns: [[XhsNote]] {
        let count = columnCount
        var buckets = Array(repeating: [XhsNote](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for note in store.notes {
            var target = 0
            for index in 1..<count where heights[index] < heights[target] {
                target = index
            }
            buckets[target].append(note)
            heights[target] += estimatedHeight(note)
        }
        return buckets
    }

    private var columnCount: Int {
        max(2, min(4, Int(UIScreen.main.bounds.width / 200)))
    }

    private var cardWidth: CGFloat {
        (UIScreen.main.bounds.width - CGFloat(columnCount - 1) * 10 - 20) / CGFloat(columnCount)
    }

    private func estimatedHeight(_ note: XhsNote) -> CGFloat {
        let imageHeight = cardWidth / max(note.aspect, 0.28)
        let textHeight: CGFloat = note.displayTitle.isEmpty ? 36 : 62
        return imageHeight + textHeight + 10
    }

    private func column(_ bucket: [XhsNote]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(bucket) { note in
                XhsNoteCard(
                    note: note,
                    width: cardWidth,
                    onOpen: { selected = note },
                    onUser: { openUser(note) },
                    onLike: { toggleLike(note) }
                )
                // 每列最后一张卡出现在屏幕上时再要下一页。
                // 以前是底部一个 1pt 的透明条，滚出屏幕再滚回来会反复触发，
                // 而且加载失败时那片区域就是一片灰。
                .onAppear {
                    guard note.id == bucket.last?.id else { return }
                    Task { await store.loadMore() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 卡片上的作者。首页 DOM 给的卡片常常没有 userId；以前按钮被
    /// `.disabled` 掉，点名字只会落到整卡的 `onTapGesture` 上打开笔记。
    /// 现在缺 id 时先补一次详情，再打开主页。
    private func openUser(_ note: XhsNote) {
        if !note.user.id.isEmpty {
            userTarget = XhsUserTarget(id: note.user.id, name: note.user.name)
            return
        }
        Task {
            let full = await store.resolvedDetail(for: note)
            await MainActor.run {
                if let full = full, !full.user.id.isEmpty {
                    userTarget = XhsUserTarget(
                        id: full.user.id,
                        name: full.user.name.isEmpty ? note.user.name : full.user.name
                    )
                } else {
                    actionError = "没拿到作者的主页 id，先点进笔记再试一次"
                }
            }
        }
    }

    /// 卡片上的心：先乐观地翻状态，失败再翻回来并提示。
    private func toggleLike(_ note: XhsNote) {
        let next = !note.liked
        Task {
            do {
                try await store.setLiked(note, liked: next)
            } catch {
                await MainActor.run {
                    actionError = store.message(for: error)
                }
            }
        }
    }

    /// 固定高度：翻页时高度不跳，用户不会看到「下面一片灰」。
    private var loadMoreFooter: some View {
        ZStack {
            if store.isLoadingMore {
                ProgressView()
            } else if store.loadMoreFailed {
                Button {
                    Task { await store.retryLoadMore() }
                } label: {
                    Text("加载失败，点此重试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if !store.hasMore {
                Text("没有更多了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("重试") {
                    Task { await store.retry() }
                }
                .buttonStyle(.borderedProminent)
                Button("重新登录") {
                    showLogin = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "book")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("登录小红书")
                .font(.headline)
            Text("用小红书 App 扫码登录（页面按桌面版排版，二维码在中间）。cookie 会一直留着，掉线了会回到这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showLogin = true
            } label: {
                Text("网页登录")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 卡片

struct XhsNoteCard: View {
    let note: XhsNote
    /// 这一列的卡片宽度。多图横滑要靠它算每张图的大小。
    var width: CGFloat = 0
    /// 点整张卡：进笔记详情。
    var onOpen: () -> Void = {}
    /// 点头像 / 昵称：进这个人的主页。
    var onUser: () -> Void = {}
    /// 点右下角的心：直接点赞，不用先进详情。
    var onLike: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            media

            if !note.displayTitle.isEmpty {
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button(action: onUser) {
                    HStack(spacing: 4) {
                        XhsImageView(url: note.user.avatar, maxPixel: 96)
                            .frame(width: 14, height: 14)
                            .clipShape(Circle())
                        Text(note.user.name.isEmpty ? "小红书用户" : note.user.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if !note.commentCount.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 10))
                        Text(note.commentCount)
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }

                Button(action: onLike) {
                    HStack(spacing: 3) {
                        Image(systemName: note.liked ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                        if !note.likedCount.isEmpty {
                            Text(note.likedCount)
                                .font(.system(size: 10))
                        }
                    }
                    .foregroundStyle(note.liked ? Color.red : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // 整卡可点。子按钮（头像、心）优先级更高，不会被打断。
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    private var cardWidth: CGFloat {
        width > 0 ? width : max(UIScreen.main.bounds.width / 2 - 15, 120)
    }

    private var mediaHeight: CGFloat {
        cardWidth / max(note.aspect, 0.28)
    }

    /// 多图笔记在卡片上就能横滑看后面的图，不再只显示封面。
    /// 用 `ScrollView` 而不是 `TabView(.page)`：后者每个卡片都是一个
    /// UICollectionView，6s 上滚两屏就卡死，还会撞上批量更新闪退。
    private var media: some View {
        ZStack(alignment: .topTrailing) {
            if note.images.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    // 多图卡片只实例化当前视口附近的子图；一次性创建整排
                    // 1600px 图的请求会让 6S 在首页滑动时同时解码十几张。
                    LazyHStack(spacing: 2) {
                        ForEach(Array(note.images.enumerated()), id: \.offset) { _, url in
                            XhsImageView(
                                url: url,
                                maxPixel: Int(cardWidth * UIScreen.main.scale)
                            )
                                .frame(width: cardWidth, height: mediaHeight)
                                .clipped()
                        }
                    }
                }
                .frame(height: mediaHeight)
            } else {
                XhsImageView(
                    url: note.cover,
                    maxPixel: Int(cardWidth * UIScreen.main.scale)
                )
                    .frame(width: cardWidth, height: mediaHeight)
                    .clipped()
            }

            if note.images.count > 1 {
                Text("\(note.images.count) 图")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.38))
                    .clipShape(Capsule())
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if note.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
                    .padding(6)
            }
        }
    }
}

/// 图片缓存。`AsyncImage` 每次滚回来都重新下载，6s 上就是「一直卡」，
/// 所以这里自己做一层 NSCache + URLCache。
final class XhsImageCache {
    static let shared = XhsImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    private let session: URLSession
    /// 全尺寸 `UIImage(data:)` 在主线程回调里解码时，滑动会直接掉帧。
    /// 解码 + 降采样统一放后台队列，主线程只接手已经能画的图。
    nonisolated private static let decodeQueue = DispatchQueue(
        label: "dev.dimension.flare.xhs.image-decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 240
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024,
            diskPath: "xhs-images"
        )
        // 图床偶尔不返回也不报错，默认 60 秒超时会让第二张一直灰着。
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: String, maxPixel: Int = 0) -> UIImage? {
        cache.object(forKey: Self.cacheKey(url, maxPixel: maxPixel) as NSString)
    }

    func image(for url: String, maxPixel: Int = 0, completion: @escaping (UIImage?) -> Void) {
        let key = Self.cacheKey(url, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        load(Self.loadPlan(for: url), index: 0, original: key, maxPixel: maxPixel)
    }

    /// 同一张图在头像（26pt）和详情（整屏宽）要的像素差很多：分开缓存，
    /// 否则缩略图先到会把全屏看图也变成糊的。128 像素一档，减少重复下载。
    private static func cacheKey(_ url: String, maxPixel: Int) -> String {
        guard maxPixel > 0 else { return url }
        let bucket = ((maxPixel + 127) / 128) * 128
        return "\(url)|\(bucket)"
    }

    /// 一个请求组合：清晰度候选 + 鉴权方式。
    private struct LoadStep {
        let url: String
        let mobileUserAgent: Bool
        let sendsCookie: Bool
    }

    /// 先要原图（`!` 前是原图 token，换到原图 CDN），再退到展示图。
    /// DOM/SSR 兜底路径会把 `urlDefault` 放在最前（见 `XhsStore.firstURL`），
    /// 拿到的就是低清 WebP；这里按 token 重建原图地址，能一并修掉那些笔记。
    private static func loadPlan(for raw: String) -> [LoadStep] {
        let display = XhsNote.normalizedImageURL(raw)
        var urls: [String] = []
        func add(_ value: String?) {
            guard let value = value, !value.isEmpty, !urls.contains(value) else { return }
            urls.append(value)
        }
        let token = XhsNote.imageToken(display)
        add(XhsNote.originalImageURL(display))
        if let token = token {
            // ci 的 w/1440 仍是清晰大图，但比原图小，适合 6S 做第二候选。
            add("https://ci.xiaohongshu.com/\(token)?imageView2/2/w/1440/format/jpg/v3")
        }
        add(XhsNote.strippedImageURL(display))
        add(display)

        var steps: [LoadStep] = []
        func append(_ url: String, mobile: Bool, cookie: Bool) {
            let duplicate = steps.contains {
                $0.url == url && $0.mobileUserAgent == mobile && $0.sendsCookie == cookie
            }
            guard !duplicate else { return }
            steps.append(LoadStep(url: url, mobileUserAgent: mobile, sendsCookie: cookie))
        }
        for (index, url) in urls.enumerated() {
            append(url, mobile: false, cookie: true)
            if index == 0 {
                // 受保护图床有时只认移动端 UA；原图候选也给它一次机会。
                append(url, mobile: true, cookie: true)
            }
            if url == display {
                append(url, mobile: true, cookie: true)
                append(url, mobile: true, cookie: false)
            }
        }
        return steps
    }

    /// `original` 是最初请求的 key：回退到原图后结果仍要交回原来的等待者，
    /// 否则 `finish` 找不到 waiter，界面就一直灰着。
    private func load(_ steps: [LoadStep], index: Int, original: String, maxPixel: Int) {
        guard index < steps.count else {
            finish(original, image: nil)
            return
        }
        let step = steps[index]
        // 图床偶尔下发 `http://`，ATS 会直接拦掉；统一提到 https 再请求。
        var value = step.url
        if value.hasPrefix("//") { value = "https:" + value }
        if value.hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        guard let target = URL(string: value) else {
            load(steps, index: index + 1, original: original, maxPixel: maxPixel)
            return
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 12
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            step.mobileUserAgent ? WebPlatformUserAgent.mobile : WebPlatformUserAgent.desktop,
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // 受保护的图（尤其是详情页第二张之后）不带登录 Cookie 会回 403，
        // 表现就是卡片一直灰着。`XhsStore` 把 cookie 存在这个 key 里。
        if step.sendsCookie {
            let cookie =
                UserDefaults.standard.string(forKey: "xhs.cookie")?
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data else {
                DispatchQueue.main.async {
                    self?.load(steps, index: index + 1, original: original, maxPixel: maxPixel)
                }
                return
            }
            Self.decodeQueue.async {
                let image = Self.decode(data, maxPixel: maxPixel)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let image = image {
                        self.finish(
                            original,
                            image: image,
                            resolved: target.absoluteString,
                            maxPixel: maxPixel
                        )
                    } else {
                        self.load(
                            steps,
                            index: index + 1,
                            original: original,
                            maxPixel: maxPixel
                        )
                    }
                }
            }
        }.resume()
    }

    nonisolated private static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }
        if maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) {
                return UIImage(cgImage: cgImage)
            }
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return max(cgImage.bytesPerRow * cgImage.height, 1)
    }

    private func finish(
        _ url: String,
        image: UIImage?,
        resolved: String? = nil,
        maxPixel: Int = 0
    ) {
        if let image = image {
            let cost = Self.cost(of: image)
            cache.setObject(image, forKey: url as NSString, cost: cost)
            if let resolved = resolved, resolved != url {
                let key = Self.cacheKey(resolved, maxPixel: maxPixel)
                cache.setObject(image, forKey: key as NSString, cost: cost)
            }
        }
        let list = waiters[url] ?? []
        waiters[url] = nil
        for item in list {
            item(image)
        }
    }
}

/// 带缓存的图片视图，失败和加载中统一灰底。
/// `fit == true` 时按完整图片显示（详情页 / 全屏看图），否则铺满裁切（瀑布流封面）。
struct XhsImageView: View {
    let url: String?
    var fit: Bool = false
    /// 0 = 原图（全屏看图）；卡片/头像传目标像素，避免把 1440 宽的图
    /// 在主线程缩到 14pt。按 3x 屏估算，传点尺寸即可。
    var maxPixel: Int = 0

    @State private var image: UIImage?
    @State private var retries = 0

    var body: some View {
        Group {
            if let image = image {
                if fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
            }
        }
        .onAppear {
            retries = 0
            load()
        }
        // 详情页换图 / 卡片换图时 URL 会变，但视图身份不变：
        // 不重新加载就会一直显示上一张（或者一直灰着）。
        .onChange(of: url) { _ in
            image = nil
            retries = 0
            load()
        }
    }

    private func load() {
        guard let url = url, !url.isEmpty else {
            image = nil
            retries = 0
            return
        }
        if let cached = XhsImageCache.shared.cached(url, maxPixel: maxPixel) {
            image = cached
            retries = 0
            return
        }
        XhsImageCache.shared.image(for: url, maxPixel: maxPixel) { loaded in
            if let loaded = loaded {
                self.image = loaded
                self.retries = 0
            } else if self.retries < 2 {
                // 图床偶发 403 / 超时：隔一会儿再走一遍四级回退，
                // 不要一次失败就灰到用户退出页面。
                self.retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.load()
                }
            }
        }
    }
}

private struct XhsPullOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

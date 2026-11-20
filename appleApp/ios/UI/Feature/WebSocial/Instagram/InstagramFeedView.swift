import SwiftUI
import UIKit
import os

/// 点帖子里的头像 / 用户名时，用这个包一层用户名给 `sheet(item:)` 用。
struct IGProfileTarget: Identifiable {
    let name: String
    var id: String { name }

    init(name: String) {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        self.name = value
    }
}

/// Instagram 首页。
///
/// 版式照 Instagram 自己的来：头像 + 用户名一行，下面是图（轮播可以左右滑），
/// 再下面是互动数和正文。点赞走 `InstagramStore` 的乐观更新，评论在详情页里发。
struct InstagramFeedView: View {
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.instagram",
        category: "profile"
    )

    @ObservedObject private var store = InstagramStore.shared
    @State private var showLogin = false
    @State private var showSearch = false
    /// 原生接口被风控拦住时的兜底：直接用网页版刷。
    @State private var showWeb = false
    @State private var selected: IGMedia?
    @State private var profileTarget: IGProfileTarget?

    var body: some View {
        Group {
            if store.isLoggedIn {
                feed
            } else {
                loginPrompt
            }
        }
        .navigationTitle("Instagram")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 15 的 ToolbarContentBuilder 没有 buildIf，条件要放进 ToolbarItem 里。
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoggedIn {
                    Menu {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button {
                            showSearch = true
                        } label: {
                            Label("查看用户主页", systemImage: "magnifyingglass")
                        }
                        Button {
                            showWeb = true
                        } label: {
                            Label("网页版", systemImage: "safari")
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
                url: "https://www.instagram.com/accounts/login/",
                title: "登录 Instagram",
                userAgent: Self.desktopUserAgent,
                requiredCookieName: "sessionid",
                cookieDomainSuffix: "instagram.com"
            ) { cookies in
                store.adopt(cookies: cookies)
                Task { await store.refresh() }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationView {
                IGUserSearchView()
            }
            .navigationViewStyle(.stack)
        }
        .sheet(isPresented: $showWeb) {
            NavigationView {
                WebPlatformView(
                    url: "https://www.instagram.com/",
                    title: "Instagram 网页版",
                    mobileUserAgent: WebPlatformUserAgent.mobile,
                    desktopUserAgent: WebPlatformUserAgent.desktop,
                    initialCookie: InstagramStore.shared.cookie,
                    cookieDomainSuffix: "instagram.com"
                )
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $selected) { media in
            NavigationView {
                InstagramPostView(media: media)
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $profileTarget) { target in
            NavigationView {
                InstagramProfileView(userName: target.name)
            }
            .navigationViewStyle(.stack)
        }
        .task {
            await store.refreshIfNeeded()
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if store.isLoading, store.feed.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else if let message = store.errorMessage, store.feed.isEmpty {
                    errorState(message)
                } else {
                    if let message = store.errorMessage, !store.feed.isEmpty {
                        banner(message)
                    }
                    ForEach(store.feed) { media in
                        IGMediaCard(
                            media: media,
                            onOpen: { selected = media },
                            onOpenUser: { openProfile($0) }
                        )
                        Divider()
                    }
                    if store.feed.isEmpty {
                        Text("时间线是空的")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                    loadMoreFooter
                }
            }
        }
        .refreshable {
            await store.refresh()
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("网页版") {
                showWeb = true
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func openProfile(_ userName: String) {
        let target = IGProfileTarget(name: userName)
        guard !target.name.isEmpty else {
            Self.profileLog.error("tap user with empty username")
            return
        }
        profileTarget = target
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if store.isLoadingMore {
            ProgressView()
                .padding(.vertical, 16)
        } else {
            // 滚到底自动续页；没触发时也有个手动入口。
            Color.clear
                .frame(height: 1)
                .onAppear {
                    Task { await store.loadMore() }
                }
        }
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
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderedProminent)
                Button("用网页版") {
                    showWeb = true
                }
                .buttonStyle(.bordered)
            }
            Text("原生接口被风控拦的时候，网页版还能正常刷。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("登录 Instagram")
                .font(.headline)
            Text("在网页里登录一次，之后就一直用这个 cookie。掉线了会回到这里。")
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

    /// Instagram 在移动 UA 下会把登录页替换成「打开 App」的引导。
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

// MARK: - 卡片

struct IGMediaCard: View {
    let media: IGMedia
    /// 点正文 / 评论 / 更多进详情。
    var onOpen: () -> Void = {}
    /// 点头像 / 用户名进用户主页。
    var onOpenUser: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            IGMediaCarousel(media: media, onOpen: onOpen)
            IGActionBar(media: media, onComment: onOpen, onMore: onOpen)
            footer
        }
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 头像和用户名单独做成按钮：之前整行都挂 `onTapGesture` 进详情，
            // 想点进作者主页根本没入口。
            Button {
                onOpenUser(media.user.userName)
            } label: {
                HStack(spacing: 10) {
                    IGImageView(url: media.user.avatar, maxPixel: 96)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.user.userName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(Self.relative(media.takenAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(media.user.userName) 的主页")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !media.caption.isEmpty {
                IGCaptionView(
                    text: media.caption,
                    fontSize: 13,
                    lineLimit: 4,
                    onOpen: onOpen
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 轮播 / 单图 / 单视频。
///
/// 视频帖先在原地放封面 + 播放键，点了直接在这个位置播（不跳页），
/// 右上角的小叉可以退回封面。
struct IGMediaCarousel: View {
    let media: IGMedia
    var onOpen: () -> Void = {}

    @State private var index = 0
    @State private var playingInline = false
    @State private var showGallery = false

    /// 老数据只有 `images` 时按图片兜底，新数据按 `items` 逐项渲染。
    private var items: [IGMediaItem] {
        if !media.items.isEmpty { return media.items }
        return media.images.map {
            IGMediaItem(id: $0, image: $0, video: nil, aspect: media.aspect)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(width / max(media.aspect, 0.1), 120)
            ZStack(alignment: .bottom) {
                if playingInline, items.indices.contains(index),
                   let video = items[index].video {
                    IGVideoPlayer(url: video)
                        .frame(width: width, height: height)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                playingInline = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(radius: 3)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                } else if items.count > 1 {
                    TabView(selection: $index) {
                        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                            IGMediaCarouselPage(item: item, width: width, height: height) {
                                index = offset
                                open(item, at: offset)
                            }
                            .tag(offset)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: width, height: height)
                    pageDots
                        .padding(.bottom, 8)
                } else if let item = items.first {
                    IGMediaCarouselPage(item: item, width: width, height: height) {
                        open(item, at: 0)
                    }
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: estimatedHeight)
        .fullScreenCover(isPresented: $showGallery) {
            IGImageGalleryView(
                items: items,
                startIndex: index,
                caption: media.caption
            )
        }
    }

    /// 图片点开全屏看图；视频在当前卡片里原地播。
    private func open(_ item: IGMediaItem, at position: Int) {
        index = position
        if item.isVideo {
            playingInline = true
        } else {
            showGallery = true
        }
    }

    /// `GeometryReader` 会吃掉高度，所以外面还要按屏幕宽度估一个。
    private var estimatedHeight: CGFloat {
        let width = UIScreen.main.bounds.width
        return max(width / max(media.aspect, 0.1), 120)
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<items.count, id: \.self) { position in
                Circle()
                    .fill(position == index ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.28))
        .clipShape(Capsule())
    }
}

/// 轮播中的一页：图片铺底，视频再叠一个播放角标。
private struct IGMediaCarouselPage: View {
    let item: IGMediaItem
    let width: CGFloat
    let height: CGFloat
    let onTap: () -> Void

    var body: some View {
        ZStack {
            if item.image != nil {
                IGImageView(url: item.image, maxPixel: 1280)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Color.black
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 6)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// 带缓存的图片视图：失败和加载中都给同一个灰底，避免布局抖动。
///
/// 不用 `AsyncImage`：它不带 Instagram 图床需要的 UA / Referer / cookie，
/// 在 6s 上经常一直灰着，滚回来还会重新下载。
struct IGImageView: View {
    let url: String?
    /// 0 = 原图；列表卡片传目标像素，避免全尺寸图在主线程缩到卡片大小。
    var maxPixel: Int = 0

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        guard let url = url, !url.isEmpty else {
            image = nil
            return
        }
        if let cached = IGImageCache.shared.cached(url, maxPixel: maxPixel) {
            image = cached
            return
        }
        image = nil
        IGImageCache.shared.image(for: url, maxPixel: maxPixel) { loaded in
            if let loaded = loaded { image = loaded }
        }
    }
}

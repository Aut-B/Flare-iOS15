import SwiftUI
import UIKit

/// Instagram 首页。
///
/// 版式照 Instagram 自己的来：头像 + 用户名一行，下面是图（轮播可以左右滑），
/// 再下面是互动数和正文。没有做点赞/评论，只做「看」——这版的目标是能刷。
struct InstagramFeedView: View {
    @ObservedObject private var store = InstagramStore.shared
    @State private var showLogin = false
    @State private var showSearch = false
    @State private var selected: IGMedia?

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
        .sheet(item: $selected) { media in
            NavigationView {
                InstagramPostView(media: media)
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
                    ForEach(store.feed) { media in
                        Button {
                            selected = media
                        } label: {
                            IGMediaCard(media: media)
                        }
                        .buttonStyle(.plain)
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
            Button("重试") {
                Task { await store.refresh() }
            }
            .buttonStyle(.borderedProminent)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            IGMediaCarousel(media: media)
            footer
        }
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            IGImageView(url: media.user.avatar)
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(media.user.userName)
                    .font(.system(size: 13, weight: .semibold))
                Text(Self.relative(media.takenAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label("\(media.likeCount)", systemImage: "heart")
                Label("\(media.commentCount)", systemImage: "bubble.right")
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            if !media.caption.isEmpty {
                Text(media.caption)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
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

/// 轮播 / 单图。多图用 `TabView` 的翻页样式，圆点在下面。
struct IGMediaCarousel: View {
    let media: IGMedia
    @State private var index = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(width / max(media.aspect, 0.1), 120)
            ZStack(alignment: .bottom) {
                if media.images.count > 1 {
                    TabView(selection: $index) {
                        ForEach(Array(media.images.enumerated()), id: \.offset) { offset, url in
                            IGImageView(url: url)
                                .frame(width: width, height: height)
                                .clipped()
                                .tag(offset)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: width, height: height)
                    pageDots
                        .padding(.bottom, 8)
                } else {
                    IGImageView(url: media.cover)
                        .frame(width: width, height: height)
                        .clipped()
                }

                if media.isVideo {
                    // 没有播放器，只标一下这是视频帖，避免用户以为图挂了。
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(height: estimatedHeight)
    }

    /// `GeometryReader` 会吃掉高度，所以外面还要按屏幕宽度估一个。
    private var estimatedHeight: CGFloat {
        let width = UIScreen.main.bounds.width
        return max(width / max(media.aspect, 0.1), 120)
    }

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<media.images.count, id: \.self) { position in
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

/// `AsyncImage` 的薄封装：失败和加载中都给同一个灰底，避免布局抖动。
struct IGImageView: View {
    let url: String?

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { phase in
            if let image = phase.image {
                image
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
    }
}

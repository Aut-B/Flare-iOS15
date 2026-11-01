import SwiftUI
import UIKit

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
                        Image(systemName: "arrow.clockwise")
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
        .refreshable {
            await store.refresh()
        }
    }

    /// 按累计高度分列。列数跟着屏宽走：6s 竖屏两列，iPad 上三列。
    private var columns: [[XhsNote]] {
        let width = UIScreen.main.bounds.width
        let count = max(2, min(4, Int(width / 200)))
        var buckets = Array(repeating: [XhsNote](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for note in store.notes {
            var target = 0
            for index in 1..<count where heights[index] < heights[target] {
                target = index
            }
            buckets[target].append(note)
            heights[target] += estimatedHeight(note, columnCount: count)
        }
        return buckets
    }

    private func estimatedHeight(_ note: XhsNote, columnCount: Int) -> CGFloat {
        let width = (UIScreen.main.bounds.width - CGFloat(columnCount - 1) * 10 - 20) / CGFloat(columnCount)
        let imageHeight = width / max(note.aspect, 0.4)
        let textHeight: CGFloat = note.displayTitle.isEmpty ? 36 : 62
        return imageHeight + textHeight + 10
    }

    private func column(_ bucket: [XhsNote]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(bucket) { note in
                XhsNoteCard(
                    note: note,
                    onOpen: { selected = note },
                    onUser: {
                        guard !note.user.id.isEmpty else { return }
                        userTarget = XhsUserTarget(id: note.user.id, name: note.user.name)
                    },
                    onLike: { toggleLike(note) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
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

    @ViewBuilder
    private var loadMoreFooter: some View {
        if store.isLoadingMore {
            ProgressView()
                .padding(.vertical, 16)
        } else if !store.hasMore {
            Text("没有更多了")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
        } else {
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
    /// 点整张卡：进笔记详情。
    var onOpen: () -> Void = {}
    /// 点头像 / 昵称：进这个人的主页。
    var onUser: () -> Void = {}
    /// 点右下角的心：直接点赞，不用先进详情。
    var onLike: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            XhsImageView(url: note.cover)
                .aspectRatio(note.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
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
                        XhsImageView(url: note.user.avatar)
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
                .disabled(note.user.id.isEmpty)

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
}

/// 图片缓存。`AsyncImage` 每次滚回来都重新下载，6s 上就是「一直卡」，
/// 所以这里自己做一层 NSCache + URLCache。
final class XhsImageCache {
    static let shared = XhsImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var waiters: [String: [(UIImage?) -> Void]] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 160 * 1024 * 1024,
            diskPath: "xhs-images"
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
        guard let target = URL(string: url) else {
            finish(url, image: nil)
            return
        }
        session.dataTask(with: target) { [weak self] data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                self?.finish(url, image: image)
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

/// 带缓存的图片视图，失败和加载中统一灰底。
/// `fit == true` 时按完整图片显示（详情页 / 全屏看图），否则铺满裁切（瀑布流封面）。
struct XhsImageView: View {
    let url: String?
    var fit: Bool = false

    @State private var image: UIImage?

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
        .onAppear { load() }
    }

    private func load() {
        guard let url = url, !url.isEmpty else {
            image = nil
            return
        }
        if let cached = XhsImageCache.shared.cached(url) {
            image = cached
            return
        }
        XhsImageCache.shared.image(for: url) { loaded in
            if let loaded = loaded {
                self.image = loaded
            }
        }
    }
}

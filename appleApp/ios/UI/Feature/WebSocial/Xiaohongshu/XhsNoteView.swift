import SwiftUI
import UIKit
import AVFoundation
import AVKit
import os

/// 笔记详情：多图横滑、点开全屏、点赞 / 收藏 / 评论，作者和评论者都能点进主页。
struct XhsNoteView: View {
    let note: XhsNote
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.xiaohongshu",
        category: "profile"
    )

    @Environment(\.dismiss) private var dismiss

    @State private var detail: XhsNote?
    @State private var detailRequested = false

    @State private var liked: Bool
    @State private var collected: Bool
    @State private var likeCount: String
    @State private var commentCount: String

    @State private var page = 0
    @State private var viewer: XhsViewerTarget?
    @State private var player: AVPlayer?
    @State private var videoError: String?
    @State private var showShare = false
    @State private var profileTarget: XhsUserTarget?
    @State private var unresolvedProfile: UnresolvedProfile?
    @State private var resolvingAuthor = false
    @State private var detailFailed = false

    @State private var comments: [XhsComment] = []
    @State private var commentCursor: String?
    @State private var commentsLoaded = false
    @State private var commentsLoading = false
    @State private var commentsError: String?
    @State private var hasMoreComments = true

    @State private var draft = ""
    @State private var sending = false
    @State private var actionError: String?

    /// 点到的用户没带主页 id。不能拿空 id 去开 `XhsUserView`，
    /// 那里的空 id 被约定成「我的主页」，会显示成用户自己的资料。
    private struct UnresolvedProfile {
        let name: String
    }

    init(note: XhsNote) {
        self.note = note
        _liked = State(initialValue: note.liked)
        _collected = State(initialValue: note.collected)
        _likeCount = State(initialValue: note.likedCount)
        _commentCount = State(initialValue: note.commentCount)
    }

    private var current: XhsNote { detail ?? note }

    private var videoURL: String? { current.videoURL ?? note.videoURL }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                media
                author
                if !current.displayTitle.isEmpty, !current.title.isEmpty {
                    Text(current.title)
                        .font(.system(size: 17, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                if !current.desc.isEmpty {
                    Text(current.desc)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
                Text(Self.dateText(current))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                if let actionError = actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }

                if detailFailed {
                    Button {
                        openWebNote()
                    } label: {
                        Label("网页版打开这条笔记", systemImage: "safari")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }

                Divider().padding(.top, 14)
                commentSection
            }
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(current.user.name.isEmpty ? "笔记" : current.user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            IGShareSheet(items: shareItems)
        }
        .fullScreenCover(item: $viewer) { target in
            XhsImageViewer(images: current.images, index: target.index) {
                viewer = nil
            }
        }
        .sheet(item: $profileTarget) { target in
            NavigationView {
                XhsUserView(userId: target.id, name: target.name, showsClose: true)
            }
            .navigationViewStyle(.stack)
        }
        .alert(
            "没拿到主页 id",
            isPresented: Binding(
                get: { unresolvedProfile != nil },
                set: { if !$0 { unresolvedProfile = nil } }
            ),
            presenting: unresolvedProfile
        ) { target in
            if !target.name.isEmpty {
                Button("网页版搜索") { openProfileSearch(target.name) }
            }
            Button("打开网页版笔记") { openWebNote() }
            Button("取消", role: .cancel) {}
        } message: { target in
            if target.name.isEmpty {
                Text("没拿到这个用户的主页 id。可以打开网页版，在笔记里点作者或评论者头像。")
            } else {
                Text("这个用户没带主页 id。可以在网页版按昵称「\(target.name)」搜索，或打开这条笔记的评论。")
            }
        }
        .onDisappear {
            player?.pause()
        }
        .task {
            // 评论和详情并行。以前是先 await 详情（签名页冷启动能到二十秒），
            // 评论区才开始请求，用户看到的就是「评论要加载半天」。
            async let detailTask: Void = loadDetail()
            loadComments(reset: true)
            await detailTask
        }
    }

    private var shareItems: [Any] {
        var items: [Any] = []
        if let url = URL(string: current.webURL) { items.append(url) }
        if let first = current.images.first, let url = URL(string: first) { items.append(url) }
        return items.isEmpty ? [current.displayTitle] : items
    }

    private static func dateText(_ note: XhsNote) -> String {
        note.isVideo ? "视频笔记" : "\(max(note.images.count, 1)) 张图片"
    }

    // MARK: - 媒体

    @ViewBuilder
    private var media: some View {
        if let urlString = videoURL {
            ZStack(alignment: .bottomTrailing) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let videoError = videoError {
                    VStack(spacing: 8) {
                        Text(videoError)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85))
                        Button("在网页版播放") { openWebNote() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.55))
                } else {
                    Button("网页版") { openWebNote() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(10)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .onAppear {
                if player == nil {
                    player = makeVideoPlayer(urlString)
                }
            }
            // 首页卡片给的是兜底地址，详情接口回来后 videoURL 会换成已验证的直链。
            // 不重建播放器的话，AVPlayer 还会继续拿着旧（常已失效）的 item。
            .onChange(of: urlString) { newValue in
                player?.pause()
                player = nil
                videoError = nil
                player = makeVideoPlayer(newValue)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemFailedToPlayToEndTime
                )
            ) { note in
                guard
                    let failed = note.object as? AVPlayerItem,
                    failed === player?.currentItem
                else { return }
                videoError = "视频加载失败，可点「在网页版播放」"
            }
            .onDisappear {
                player?.pause()
            }
        } else if current.images.isEmpty {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else if current.images.count == 1 {
            XhsImageView(url: current.images[0], fit: true, maxPixel: 1600)
                .aspectRatio(mediaAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { viewer = XhsViewerTarget(index: 0) }
        } else {
            TabView(selection: $page) {
                ForEach(Array(current.images.enumerated()), id: \.offset) { index, url in
                    XhsImageView(url: url, fit: true, maxPixel: 1600)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { viewer = XhsViewerTarget(index: index) }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            // 默认圆点在白底 / 浅色图上几乎看不见，用户会以为只有一张。
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(maxWidth: .infinity)
            .frame(height: mediaHeight)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottomTrailing) { pageBadge }
        }
    }

    private var pageBadge: some View {
        Text("\(page + 1)/\(current.images.count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.4))
            .clipShape(Capsule())
            .padding(10)
    }

    private var mediaAspect: CGFloat {
        let value = current.aspect
        if value <= 0 { return 0.75 }
        // 长图按原比例铺开，靠外层 ScrollView 往下滑；不要为了「一屏放得下」
        // 把它裁掉，用户看到的就是「我贴的是长图，这里只有一张短图」。
        return min(max(value, 0.28), 1.8)
    }

    private var mediaHeight: CGFloat {
        let width = UIScreen.main.bounds.width
        let height = width / mediaAspect
        // 多图横滑时每张都按这个高度居中显示；长图给到 3 屏高左右，
        // 仍然可以用外层 ScrollView 继续往下看正文。
        return min(max(height, 240), UIScreen.main.bounds.height * 2.2)
    }

    private func makeVideoPlayer(_ urlString: String) -> AVPlayer? {
        guard let url = URL(string: urlString) else {
            videoError = "视频地址无效"
            return nil
        }
        let cookie = XhsStore.shared.cookie
        var headers: [String: String] = [
            "Referer": "https://www.xiaohongshu.com/",
            "User-Agent": XhsSigner.desktopUserAgent,
        ]
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        let asset = AVURLAsset(
            url: url,
            // 用字符串 key：`AVURLAssetHTTPHeaderFieldsKey` 在部分 SDK 里
            // 并没有暴露成 Swift 可见符号，直接引用会编译失败。
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        videoError = nil
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    private func openWebNote() {
        guard let url = URL(string: current.webURL) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 作者

    private var author: some View {
        HStack(spacing: 0) {
            authorLink
            Spacer(minLength: 0)
            actionBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var authorLink: some View {
        if current.user.id.isEmpty, current.user.name.isEmpty, current.user.avatar == nil {
            authorRow
        } else {
            Button {
                openAuthorProfile()
            } label: {
                authorRow
            }
            .buttonStyle(.plain)
        }
    }

    /// 详情接口没回来之前，首页卡片可能只有作者名。先按已有 id 打开；
    /// 没 id 就补一次详情，拿到 `user.userId` 再弹主页，而不是让整行不可点。
    private func openAuthorProfile() {
        let author = current.user
        if !author.id.isEmpty {
            profileTarget = XhsUserTarget(id: author.id, name: author.name)
            return
        }
        guard !resolvingAuthor else { return }
        let requestNote = current
        resolvingAuthor = true
        Task {
            var resolved: XhsUser? = nil
            if let detail = detail, !detail.user.id.isEmpty {
                resolved = detail.user
            }
            if resolved == nil,
               let full = await XhsStore.shared.resolvedDetail(for: requestNote),
               !full.user.id.isEmpty {
                resolved = full.user
            }
            await MainActor.run {
                resolvingAuthor = false
                if let resolved = resolved {
                    profileTarget = XhsUserTarget(
                        id: resolved.id,
                        name: resolved.name.isEmpty ? author.name : resolved.name
                    )
                } else {
                    Self.profileLog.error(
                        "author id missing for note \(requestNote.id, privacy: .public), name \(author.name, privacy: .public)"
                    )
                    openUserProfile(XhsUserTarget(id: "", name: author.name))
                }
            }
        }
    }

    /// 有 id 直接开主页；没 id 时不拿空 id 去开（会变成「我的主页」），
    /// 而是给网页版出口，避免整行看起来可点、点下去却没反应。
    private func openUserProfile(_ target: XhsUserTarget) {
        if !target.id.isEmpty {
            profileTarget = target
            return
        }
        let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        unresolvedProfile = UnresolvedProfile(name: name)
    }

    private func openProfileSearch(_ name: String) {
        var components = URLComponents(string: "https://www.xiaohongshu.com/search_result")
        components?.queryItems = [URLQueryItem(name: "keyword", value: name)]
        guard let url = components?.url else { return }
        UIApplication.shared.open(url)
    }

    private var authorRow: some View {
        HStack(spacing: 8) {
            XhsImageView(url: current.user.avatar, maxPixel: 160)
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(current.user.name.isEmpty ? "小红书用户" : current.user.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("查看主页")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                toggleLike()
            } label: {
                actionLabel(
                    symbol: liked ? "heart.fill" : "heart",
                    text: likeCount,
                    tint: liked ? .red : .secondary
                )
            }
            .buttonStyle(.plain)

            Button {
                toggleCollect()
            } label: {
                actionLabel(
                    symbol: collected ? "star.fill" : "star",
                    text: "",
                    tint: collected ? .yellow : .secondary
                )
            }
            .buttonStyle(.plain)

            actionLabel(symbol: "bubble.right", text: commentCount, tint: .secondary)
        }
    }

    private func actionLabel(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 18))
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(tint)
    }

    // MARK: - 评论

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("评论")
                    .font(.system(size: 15, weight: .semibold))
                if !commentCount.isEmpty {
                    Text(commentCount)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if commentsLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if let commentsError = commentsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(commentsError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重新加载评论") { loadComments(reset: true) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
            } else if comments.isEmpty, commentsLoading {
                // 先给骨架，别让评论区空白一片让人以为坏了。
                ForEach(0..<3, id: \.self) { _ in
                    commentSkeleton
                }
            } else if comments.isEmpty, commentsLoaded {
                Text("还没有评论")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            } else {
                ForEach(comments) { comment in
                    XhsCommentRow(comment: comment) { target in
                        openUserProfile(target)
                    }
                        .padding(.horizontal, 14)
                }
                if hasMoreComments {
                    Button {
                        loadComments(reset: false)
                    } label: {
                        Text(commentsLoading ? "加载中…" : "查看更多评论")
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    private var commentSkeleton: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 76, height: 9)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 180, height: 10)
            }
        }
        .padding(.horizontal, 14)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("说点什么…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .submitLabel(.send)
                .onSubmit { sendComment() }
            Button {
                sendComment()
            } label: {
                if sending {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("发送").font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 动作

    private func toggleLike() {
        let next = !liked
        liked = next
        let snapshot = current
        Task {
            do {
                try await XhsStore.shared.setLiked(snapshot, liked: next)
            } catch {
                await MainActor.run {
                    liked = !next
                    actionError = XhsStore.shared.message(for: error)
                }
            }
        }
    }

    private func toggleCollect() {
        let next = !collected
        collected = next
        let snapshot = current
        Task {
            do {
                try await XhsStore.shared.setCollected(snapshot, collected: next)
            } catch {
                await MainActor.run {
                    collected = !next
                    actionError = XhsStore.shared.message(for: error)
                }
            }
        }
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        let snapshot = current
        Task {
            do {
                let comment = try await XhsStore.shared.postComment(note: snapshot, content: text)
                await MainActor.run {
                    draft = ""
                    sending = false
                    actionError = nil
                    if let comment = comment {
                        comments.insert(comment, at: 0)
                    }
                    let current = Int(commentCount) ?? 0
                    commentCount = current > 0 ? String(current + 1) : commentCount
                    commentsLoaded = true
                }
            } catch {
                await MainActor.run {
                    sending = false
                    actionError = XhsStore.shared.message(for: error)
                }
            }
        }
    }

    private func loadDetail() async {
        guard !detailRequested else { return }
        detailRequested = true

        // 刚看过同一篇：正文和多图直接出，不再等签名页和详情接口。
        if let cached = XhsStore.shared.cachedDetail(for: note.id) {
            let merged = mergedDetail(with: cached)
            detail = merged
            XhsStore.shared.rememberDetail(merged)
            if page >= merged.images.count { page = 0 }
            liked = merged.liked || liked
            collected = merged.collected || collected
            if !merged.likedCount.isEmpty { likeCount = merged.likedCount }
            if !merged.commentCount.isEmpty { commentCount = merged.commentCount }
            detailFailed = false
            return
        }

        // 同一个 xsec_token 在「笔记页来源」和「首页卡片来源」之间不一定通用：
        // 只试 pc_feed 的话，从关注流 / 搜索进来的笔记经常整条详情被拒，
        // 表现就是「只有封面一张图、正文和评论都出不来」。
        guard let full = await XhsStore.shared.detail(for: note, allowCache: false) else {
            // 所有来源全挂：给出「网页版打开」兜底，而不是留一个只剩封面的空页面。
            Self.profileLog.error(
                "detail failed for note \(note.id, privacy: .public); author id \(note.user.id, privacy: .public)"
            )
            await MainActor.run {
                detailFailed = true
            }
            return
        }

        await MainActor.run {
            let merged = mergedDetail(with: full)
            detail = merged
            XhsStore.shared.rememberDetail(merged)
            // 详情里的图可能比首页卡片多：页码越界会直接显示空白。
            if page >= merged.images.count { page = 0 }
            liked = merged.liked || liked
            collected = merged.collected || collected
            if !merged.likedCount.isEmpty { likeCount = merged.likedCount }
            if !merged.commentCount.isEmpty { commentCount = merged.commentCount }
            detailFailed = false
            // 评论是和详情并行发的，第一次多半还拿着卡片上的旧 token。
            // 详情回来时 token 可能已经刷新，这里自动重试一次，
            // 用户不用再手点「重新加载评论」。
            if commentsError != nil, !commentsLoading {
                loadComments(reset: true)
            }
        }
    }

    /// 详情偶尔只回正文或一张图；首页卡片上已有的作者 id / 多图不能倒退，
    /// 但详情可能更全，所以做并集，详情在前。
    private func mergedDetail(with full: XhsNote) -> XhsNote {
        var merged = full
        if merged.user.id.isEmpty, !note.user.id.isEmpty {
            merged.user = XhsUser(
                id: note.user.id,
                name: merged.user.name.isEmpty ? note.user.name : merged.user.name,
                avatar: merged.user.avatar ?? note.user.avatar
            )
        } else if merged.user.name.isEmpty, !note.user.name.isEmpty {
            merged.user = XhsUser(
                id: merged.user.id,
                name: note.user.name,
                avatar: merged.user.avatar ?? note.user.avatar
            )
        }
        var seen = Set<String>()
        var mergedImages: [String] = []
        for url in (full.images + note.images) where !url.isEmpty {
            if seen.insert(url).inserted { mergedImages.append(url) }
        }
        if !mergedImages.isEmpty {
            merged.images = mergedImages
        }
        // 详情接口的直链已验证：优先保留详情地址，卡片兜底只在详情缺失时用。
        if let video = full.videoURL, !video.isEmpty {
            merged.videoURL = video
        } else if let video = note.videoURL, !video.isEmpty {
            merged.videoURL = video
        }
        if merged.likedCount.isEmpty {
            merged.likedCount = note.likedCount
        }
        if merged.commentCount.isEmpty {
            merged.commentCount = note.commentCount
        }
        if merged.shareCount.isEmpty {
            merged.shareCount = note.shareCount
        }
        if !merged.liked, note.liked {
            merged.liked = true
        }
        if !merged.collected, note.collected {
            merged.collected = true
        }
        return merged
    }

    private func loadComments(reset: Bool) {
        guard !commentsLoading else { return }
        if reset {
            commentsError = nil
        } else if !hasMoreComments {
            return
        }
        commentsLoading = true
        let snapshot = current
        let cursor = reset ? nil : commentCursor
        Task {
            do {
                let page = try await XhsStore.shared.comments(note: snapshot, cursor: cursor)
                await MainActor.run {
                    if reset {
                        comments = page.items
                    } else {
                        comments.append(contentsOf: page.items)
                    }
                    commentCursor = page.next
                    hasMoreComments = !(page.next ?? "").isEmpty && !page.items.isEmpty
                    commentsLoaded = true
                    commentsLoading = false
                }
            } catch {
                await MainActor.run {
                    commentsError = XhsStore.shared.message(for: error)
                    commentsLoaded = true
                    commentsLoading = false
                }
            }
        }
    }
}

// MARK: - 全屏看图

struct XhsViewerTarget: Identifiable {
    let id = UUID()
    let index: Int
}

struct XhsImageViewer: View {
    let images: [String]
    let startIndex: Int
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var showShare = false
    @State private var zoomedPages: Set<Int> = []
    @State private var zoomResetGeneration = 0

    init(images: [String], index: Int, onClose: (() -> Void)? = nil) {
        self.images = images
        self.startIndex = index
        self.onClose = onClose
        _index = State(initialValue: index)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { offset, url in
                    XhsZoomableImage(
                        url: url,
                        resetGeneration: zoomResetGeneration,
                        onZoomChange: { zoomed in
                            if zoomed {
                                zoomedPages.insert(offset)
                            } else {
                                zoomedPages.remove(offset)
                            }
                        }
                    )
                        .id("\(offset)|\(url)")
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")

                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.top, 16)

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    saveCurrent()
                } label: {
                    circle("arrow.down.to.line")
                }
                if images.count > 1 {
                    Button {
                        saveAll()
                    } label: {
                        circle("square.and.arrow.down.on.square")
                    }
                }
                Button {
                    showShare = true
                } label: {
                    circle("square.and.arrow.up")
                }
                Text("\(index + 1) / \(images.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            .padding(.top, 16)
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .sheet(isPresented: $showShare) {
            IGShareSheet(items: shareItems)
        }
        .onChange(of: images) { _ in
            resetZoomState()
            if index >= images.count {
                index = max(images.count - 1, 0)
            }
        }
        .onChange(of: index) { _ in
            resetZoomState()
        }
        .simultaneousGesture(dismissDrag())
    }

    private func dismissDrag() -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard !zoomedPages.contains(index) else { return }
                let dy = value.translation.height
                let projected = value.predictedEndTranslation.height
                guard dy > 0, abs(dy) > abs(value.translation.width) * 1.5 else { return }
                if dy > 120 || projected > 180 {
                    close()
                }
            }
    }

    private func resetZoomState() {
        zoomedPages.removeAll()
        zoomResetGeneration &+= 1
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var shareItems: [Any] {
        guard images.indices.contains(index) else { return [] }
        return [images[index]]
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.black.opacity(0.4))
            .clipShape(Circle())
    }

    private func saveCurrent() {
        guard images.indices.contains(index) else { return }
        MediaSaver.shared.saveImages([MediaImageSaveItem(url: images[index])])
    }

    private func saveAll() {
        guard !images.isEmpty else { return }
        MediaSaver.shared.saveImages(images.map { MediaImageSaveItem(url: $0) })
    }
}

/// 单张可缩放的图。双击 1x / 2.5x，捏合到 4x，放大后可拖动。
struct XhsZoomableImage: View {
    let url: String
    var resetGeneration: Int = 0
    var onZoomChange: ((Bool) -> Void)? = nil

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Group {
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
                                    onZoomChange?(scale > 1)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    onZoomChange?(scale > 1)
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
                                onZoomChange?(scale > 1)
                                if scale == 1 {
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear(perform: load)
        .onChange(of: resetGeneration) { _ in
            resetZoom()
        }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func load() {
        if let cached = XhsImageCache.shared.cached(url) {
            image = cached
            return
        }
        XhsImageCache.shared.image(for: url) { loaded in
            if let loaded = loaded { image = loaded }
        }
    }
}

// MARK: - 评论行

struct XhsCommentRow: View {
    let comment: XhsComment
    /// 点评论者 / 回复者 / 头像时回调，由详情页统一用 sheet 打开用户主页。
    /// 以前这里用 NavigationLink，评论一多就会把详情页的导航栈撑爆。
    let onUser: (XhsUserTarget) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                nameLink
                Text(comment.content)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if !comment.time.isEmpty {
                        Text(comment.time)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if !comment.likeCount.isEmpty {
                        Label(comment.likeCount, systemImage: "heart")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if comment.subCount > 0 {
                        Text("\(comment.subCount) 条回复")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(comment.subComments.prefix(2))) { sub in
                    HStack(alignment: .top, spacing: 6) {
                        subNameLink(sub)
                        Text(sub.content)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var nameText: some View {
        Text(comment.user.name.isEmpty ? "小红书用户" : comment.user.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var nameLink: some View {
        if comment.user.id.isEmpty, comment.user.name.isEmpty {
            nameText
        } else {
            Button {
                onUser(XhsUserTarget(id: comment.user.id, name: comment.user.name))
            } label: {
                nameText
            }
            .buttonStyle(.plain)
        }
    }

    private func subNameText(_ sub: XhsComment) -> Text {
        Text(sub.user.name + "：")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func subNameLink(_ sub: XhsComment) -> some View {
        if sub.user.id.isEmpty, sub.user.name.isEmpty {
            subNameText(sub)
        } else {
            Button {
                onUser(XhsUserTarget(id: sub.user.id, name: sub.user.name))
            } label: {
                subNameText(sub)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if comment.user.id.isEmpty, comment.user.name.isEmpty {
            avatarImage
        } else {
            Button {
                onUser(XhsUserTarget(id: comment.user.id, name: comment.user.name))
            } label: {
                avatarImage
            }
            .buttonStyle(.plain)
        }
    }

    private var avatarImage: some View {
        XhsImageView(url: comment.user.avatar, maxPixel: 128)
            .frame(width: 26, height: 26)
            .clipShape(Circle())
    }
}

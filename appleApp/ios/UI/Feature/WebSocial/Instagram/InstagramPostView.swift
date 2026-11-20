import SwiftUI
import UIKit
import os

/// 帖子详情：正文不截断，多图纵向铺开，视频直接播。
/// 底部带网页版那套交互：点赞、评论、转发、保存图片。
struct InstagramPostView: View {
    let media: IGMedia
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.instagram",
        category: "profile"
    )

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = InstagramStore.shared
    @State private var detail: IGMedia?
    @State private var comments: [IGComment] = []
    @State private var isLoadingComments = false
    @State private var commentText = ""
    @State private var sending = false
    @State private var commentError: String?
    @State private var showGallery = false
    @State private var galleryIndex = 0
    @State private var profileTarget: IGProfileTarget?
    @State private var showWeb = false
    @FocusState private var commentFocused: Bool

    private var current: IGMedia { detail ?? media }
    private var likeState: IGLikeState { store.likeState(for: current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                userHeader
                mediaStack
                IGActionBar(media: current, onComment: { commentFocused = true })
                statsRow
                if !current.caption.isEmpty {
                    IGCaptionView(text: current.caption)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                }
                Divider()
                    .padding(.top, 14)
                commentsSection
                openInBrowser
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(current.user.userName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task {
            // 详情和评论互不依赖：详情拿全量媒体字段，评论同时开始请求，
            // 不让 20s 级的详情超时把评论区一起拖住。
            if detail == nil {
                async let detailRequest = InstagramService.shared.media(pk: media.id)
                await loadComments()
                detail = try? await detailRequest
            } else {
                await loadComments()
            }
        }
        .sheet(isPresented: $showWeb) {
            NavigationView {
                WebPlatformView(
                    url: current.webURL,
                    title: "Instagram 网页版",
                    mobileUserAgent: WebPlatformUserAgent.mobile,
                    desktopUserAgent: WebPlatformUserAgent.desktop,
                    initialCookie: InstagramStore.shared.cookie,
                    cookieDomainSuffix: "instagram.com"
                )
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $profileTarget) { target in
            NavigationView {
                InstagramProfileView(userName: target.name)
            }
            .navigationViewStyle(.stack)
        }
        .fullScreenCover(isPresented: $showGallery) {
            IGImageGalleryView(
                items: current.items,
                startIndex: galleryIndex,
                caption: current.caption
            )
        }
    }

    private var userHeader: some View {
        HStack(spacing: 10) {
            Button {
                openProfile(current.user.userName)
            } label: {
                HStack(spacing: 10) {
                    IGImageView(url: current.user.avatar, maxPixel: 160)
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.user.userName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(IGMediaCard.relative(current.takenAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开 \(current.user.userName) 的主页")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var mediaStack: some View {
        if current.items.count > 1 {
            VStack(spacing: 2) {
                ForEach(Array(current.items.enumerated()), id: \.offset) { offset, item in
                    mediaItem(item, at: offset, autoPlay: false)
                }
            }
        } else if let item = current.items.first {
            mediaItem(item, at: 0, autoPlay: item.isVideo)
        } else {
            IGImageView(url: current.cover, maxPixel: 1600)
                .aspectRatio(current.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
        }
    }

    @ViewBuilder
    private func mediaItem(_ item: IGMediaItem, at offset: Int, autoPlay: Bool) -> some View {
        // 用 item 自己的比例，不要用 `current.aspect`：那条是首图的比例，
        // 多图轮播里横图和竖图混排时（很常见），后面几张会按首图的比例被
        // 裁掉一截或者留黑边。
        let aspect = item.aspect > 0 ? item.aspect : current.aspect
        if let video = item.video {
            IGVideoPlayer(url: video, autoPlay: autoPlay)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            IGImageView(url: item.image, maxPixel: 1600)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    galleryIndex = offset
                    showGallery = true
                }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            Text("\(likeState.count) 次赞")
            Text("\(current.commentCount) 条评论")
            Spacer(minLength: 0)
            if current.isVideo {
                Label("视频", systemImage: "play.rectangle")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: - 评论

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("评论")
                    .font(.system(size: 14, weight: .semibold))
                if isLoadingComments {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Spacer(minLength: 0)
            }

            if let commentError = commentError {
                actionErrorBanner(commentError)
            } else if comments.isEmpty, !isLoadingComments {
                Text("还没有评论，来抢第一条")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        openProfile(comment.userName)
                    } label: {
                        IGImageView(url: comment.avatar, maxPixel: 128)
                            .frame(width: 26, height: 26)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开 \(comment.displayName) 的主页")
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            openProfile(comment.userName)
                        } label: {
                            Text(comment.displayName)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        Text(comment.text)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                TextField("写评论…", text: $commentText)
                    .textFieldStyle(.roundedBorder)
                    .focused($commentFocused)
                    .submitLabel(.send)
                    .onSubmit { sendComment() }
                Button {
                    sendComment()
                } label: {
                    if sending {
                        ProgressView()
                    } else {
                        Text("发送")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func openProfile(_ userName: String) {
        let target = IGProfileTarget(name: userName)
        guard !target.name.isEmpty else {
            Self.profileLog.error("tap user with empty username")
            return
        }
        profileTarget = target
    }

    /// 点赞 / 评论被风控拦下时的提示条：说清楚「登录没掉」，并给网页版入口。
    private func actionErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("网页版") {
                showWeb = true
            }
            .font(.system(size: 12, weight: .semibold))
            Button("重试") {
                Task { await loadComments() }
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadComments() async {
        isLoadingComments = true
        commentError = nil
        defer { isLoadingComments = false }
        do {
            comments = try await InstagramService.shared.comments(mediaId: media.id)
        } catch {
            commentError = error.localizedDescription
        }
    }

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            do {
                let created = try await InstagramService.shared.addComment(
                    mediaId: media.id,
                    text: text
                )
                commentText = ""
                commentFocused = false
                if let created = created {
                    comments.append(created)
                } else {
                    await loadComments()
                }
                IGToast.success("评论已发送")
            } catch {
                commentError = error.localizedDescription
                IGToast.error(error.localizedDescription)
            }
            sending = false
        }
    }

    @ViewBuilder
    private var openInBrowser: some View {
        if let url = URL(string: current.webURL) {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("在浏览器里打开")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .padding(.top, 8)
        }
    }
}

/// 用户主页：头部信息 + 九宫格缩略图。
struct InstagramProfileView: View {
    let userName: String
    private static let profileLog = Logger(
        subsystem: "dev.dimension.flare.instagram",
        category: "profile"
    )

    @Environment(\.dismiss) private var dismiss
    @State private var user: IGUser?
    @State private var media: [IGMedia] = []
    @State private var next: String?
    @State private var isLoadingMore = false
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selected: IGMedia?
    /// 只有用户自己点「用网页版打开」时才切网页版。
    /// 以前是接口一报错就自动切，用户会觉得「点个人主页就被踢走了」，
    /// 而且切过去以后原生主页就再也回不来了。
    @State private var useWeb = false

    private var webURL: String { "https://www.instagram.com/\(userName)/" }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if useWeb {
                webFallback
            } else if isLoading, media.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText = errorText, media.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(errorText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("用网页版打开") {
                        useWeb = true
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let errorText = errorText {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                Text(errorText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Button("重试") {
                                    Task { await load() }
                                }
                                .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.08))
                        }
                        header
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(media) { item in
                                Button {
                                    selected = item
                                } label: {
                                    IGImageView(url: item.cover, maxPixel: 512)
                                        .aspectRatio(1, contentMode: .fill)
                                        .frame(maxWidth: .infinity)
                                        .clipped()
                                        .overlay(alignment: .topTrailing) {
                                            if item.isVideo {
                                                Image(systemName: "play.fill")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.white)
                                                    .padding(4)
                                                    .background(Color.black.opacity(0.4))
                                                    .clipShape(Circle())
                                                    .padding(4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    guard item.id == media.last?.id else { return }
                                    Task { await loadMore() }
                                }
                            }
                        }
                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await load()
                }
            }
        }
        .navigationTitle(userName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .sheet(item: $selected) { item in
            NavigationView {
                InstagramPostView(media: item)
            }
            .navigationViewStyle(.stack)
        }
        .task {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                IGImageView(url: user?.avatar, maxPixel: 256)
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(user?.displayName ?? userName)
                        .font(.system(size: 16, weight: .semibold))
                    Text("@\(userName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        if let count = user?.postCount {
                            Text("\(count) 帖子").font(.system(size: 12))
                        }
                        if let count = user?.followerCount {
                            Text("\(count) 粉丝").font(.system(size: 12))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let biography = user?.biography, !biography.isEmpty {
                Text(biography)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await InstagramService.shared.profile(userName: userName)
            user = result.user
            media = result.media
            next = result.next
            Self.profileLog.info(
                "profile view @\(userName, privacy: .public) loaded \(result.media.count) posts"
            )
            // 九宫格首屏同样先并发取前几张缩略图，避免逐张 onAppear 才发请求。
            DispatchQueue.main.async {
                IGImageCache.shared.prefetch(
                    result.media.prefix(6).compactMap(\.cover),
                    limit: 6,
                    maxPixel: 512
                )
            }
        } catch {
            Self.profileLog.error(
                "profile view @\(userName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            errorText = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard
            let userId = user?.id,
            !userId.isEmpty,
            let cursor = next,
            !cursor.isEmpty,
            !isLoadingMore
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await InstagramService.shared.userFeed(
                userId: userId,
                cursor: cursor
            )
            let known = Set(media.map(\.id))
            media.append(contentsOf: page.items.filter { !known.contains($0.id) })
            next = page.next
        } catch {
            Self.profileLog.error(
                "profile view @\(userName, privacy: .public) load more failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @ViewBuilder
    private var webFallback: some View {
        VStack(spacing: 0) {
            if errorText != nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("已打开网页版")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("重试原生") {
                        useWeb = false
                        Task { await load() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }
            WebPlatformView(
                url: webURL,
                title: "@\(userName)",
                mobileUserAgent: WebPlatformUserAgent.mobile,
                desktopUserAgent: WebPlatformUserAgent.desktop,
                initialCookie: InstagramStore.shared.cookie,
                cookieDomainSuffix: "instagram.com",
                showsBrowserBar: false
            )
        }
    }
}

/// 输入用户名看主页。首页时间线挂了的时候，这是唯一还能用的入口。
struct IGUserSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
    }

    var body: some View {
        Form {
            Section {
                TextField("用户名", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            } footer: {
                Text("不用带 @，例如 nasa。")
            }
            Section {
                if trimmed.isEmpty {
                    Text("先输入一个用户名")
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink("查看 @\(trimmed) 的主页") {
                        InstagramProfileView(userName: trimmed)
                    }
                }
            }
        }
        .navigationTitle("查看用户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

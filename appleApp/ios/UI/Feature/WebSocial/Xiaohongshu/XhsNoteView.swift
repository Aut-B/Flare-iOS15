import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// 笔记详情：多图横滑、点开全屏、点赞 / 收藏 / 评论，作者和评论者都能点进主页。
struct XhsNoteView: View {
    let note: XhsNote

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
    @State private var showShare = false

    @State private var comments: [XhsComment] = []
    @State private var commentCursor: String?
    @State private var commentsLoaded = false
    @State private var commentsLoading = false
    @State private var commentsError: String?
    @State private var hasMoreComments = true

    @State private var draft = ""
    @State private var sending = false
    @State private var actionError: String?

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
            XhsImageViewer(images: current.images, index: target.index)
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
        if let urlString = videoURL, let url = URL(string: urlString) {
            VideoPlayer(player: player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .onAppear {
                    if player == nil { player = AVPlayer(url: url) }
                }
        } else if current.images.isEmpty {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else if current.images.count == 1 {
            XhsImageView(url: current.images[0], fit: true)
                .aspectRatio(mediaAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { viewer = XhsViewerTarget(index: 0) }
                .overlay(alignment: .bottomTrailing) {
                    if current.images.count > 1 { pageBadge }
                }
        } else {
            TabView(selection: $page) {
                ForEach(Array(current.images.enumerated()), id: \.offset) { index, url in
                    XhsImageView(url: url, fit: true)
                        .contentShape(Rectangle())
                        .onTapGesture { viewer = XhsViewerTarget(index: index) }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
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
        return min(max(value, 0.5), 1.8)
    }

    private var mediaHeight: CGFloat {
        let width = UIScreen.main.bounds.width
        let height = width / mediaAspect
        return min(max(height, 240), 560)
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
        if current.user.id.isEmpty {
            authorRow
        } else {
            NavigationLink(
                destination: XhsUserView(userId: current.user.id, name: current.user.name)
            ) {
                authorRow
            }
            .buttonStyle(.plain)
        }
    }

    private var authorRow: some View {
        HStack(spacing: 8) {
            XhsImageView(url: current.user.avatar)
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
                    XhsCommentRow(comment: comment)
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
        do {
            let full = try await XhsService.shared.note(id: note.id, xsecToken: note.xsecToken)
            await MainActor.run {
                detail = full
                // 详情里的图可能比首页卡片多：页码越界会直接显示空白。
                if page >= full.images.count { page = 0 }
                liked = full.liked || liked
                collected = full.collected || collected
                if !full.likedCount.isEmpty { likeCount = full.likedCount }
                if !full.commentCount.isEmpty { commentCount = full.commentCount }
            }
        } catch {
            // 详情接口被风控挡了不影响看：首页流里已经带了图片和正文。
        }
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

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var showShare = false

    init(images: [String], index: Int) {
        self.images = images
        self.startIndex = index
        _index = State(initialValue: index)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.offset) { offset, url in
                    XhsZoomableImage(url: url)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    circle("xmark")
                }
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
            .padding(.trailing, 12)
            .padding(.top, 16)
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .sheet(isPresented: $showShare) {
            IGShareSheet(items: shareItems)
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
                                }
                                .onEnded { _ in
                                    lastScale = scale
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.user.name.isEmpty ? "小红书用户" : comment.user.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                        Text(sub.user.name + "：")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var avatar: some View {
        if comment.user.id.isEmpty {
            avatarImage
        } else {
            NavigationLink(
                destination: XhsUserView(userId: comment.user.id, name: comment.user.name)
            ) {
                avatarImage
            }
            .buttonStyle(.plain)
        }
    }

    private var avatarImage: some View {
        XhsImageView(url: comment.user.avatar)
            .frame(width: 26, height: 26)
            .clipShape(Circle())
    }
}
import SwiftUI
import UIKit

/// 帖子详情：正文不截断，多图纵向铺开，视频直接播。
/// 底部带网页版那套交互：点赞、评论、转发、保存图片。
struct InstagramPostView: View {
    let media: IGMedia

    @Environment(\.dismiss) private var dismiss
    @State private var detail: IGMedia?
    @State private var comments: [IGComment] = []
    @State private var isLoadingComments = false
    @State private var commentText = ""
    @State private var sending = false
    @State private var commentError: String?
    @FocusState private var commentFocused: Bool

    private var current: IGMedia { detail ?? media }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                userHeader
                mediaStack
                IGActionBar(media: current, onComment: { commentFocused = true })
                statsRow
                if !current.caption.isEmpty {
                    Text(current.caption)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
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
            // 时间线里的字段是精简过的，进详情再拉一次拿全量（含视频地址）。
            if detail == nil {
                detail = try? await InstagramService.shared.media(pk: media.id)
            }
            await loadComments()
        }
    }

    private var userHeader: some View {
        HStack(spacing: 10) {
            IGImageView(url: current.user.avatar)
                .frame(width: 34, height: 34)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(current.user.userName)
                    .font(.system(size: 14, weight: .semibold))
                Text(IGMediaCard.relative(current.takenAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var mediaStack: some View {
        if let video = current.videoURL, !current.isCarousel {
            IGVideoPlayer(url: video)
                .aspectRatio(current.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            VStack(spacing: 2) {
                ForEach(Array(current.images.enumerated()), id: \.offset) { _, url in
                    IGImageView(url: url)
                        .aspectRatio(current.aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            Text("\(current.likeCount) 次赞")
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

            if comments.isEmpty, !isLoadingComments {
                Text(commentError ?? "还没有评论，来抢第一条")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(comments) { comment in
                HStack(alignment: .top, spacing: 8) {
                    IGImageView(url: comment.avatar)
                        .frame(width: 26, height: 26)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.displayName)
                            .font(.system(size: 12, weight: .semibold))
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

    private func loadComments() async {
        isLoadingComments = true
        commentError = nil
        defer { isLoadingComments = false }
        do {
            comments = try await InstagramService.shared.comments(mediaId: current.id)
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
                    mediaId: current.id,
                    text: text
                )
                commentText = ""
                commentFocused = false
                if let created = created {
                    comments.append(created)
                }
                IGToast.success("评论已发送")
            } catch {
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

    @Environment(\.dismiss) private var dismiss
    @State private var user: IGUser?
    @State private var media: [IGMedia] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selected: IGMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if isLoading, media.isEmpty {
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(media) { item in
                                Button {
                                    selected = item
                                } label: {
                                    IGImageView(url: item.cover)
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
                            }
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
                IGImageView(url: user?.avatar)
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
        } catch {
            errorText = error.localizedDescription
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

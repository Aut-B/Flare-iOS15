import SwiftUI
import UIKit

/// 帖子详情：正文不截断，多图纵向铺开（跟截图导出那套版式一致）。
struct InstagramPostView: View {
    let media: IGMedia

    @Environment(\.dismiss) private var dismiss
    @State private var detail: IGMedia?

    private var current: IGMedia { detail ?? media }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                userHeader
                mediaStack
                statsRow
                if !current.caption.isEmpty {
                    Text(current.caption)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }
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
            guard detail == nil else { return }
            detail = try? await InstagramService.shared.media(pk: media.id)
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

    private var mediaStack: some View {
        VStack(spacing: 2) {
            ForEach(Array(current.images.enumerated()), id: \.offset) { _, url in
                IGImageView(url: url)
                    .aspectRatio(current.aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            Label("\(current.likeCount)", systemImage: "heart")
            Label("\(current.commentCount)", systemImage: "bubble.right")
            Spacer(minLength: 0)
            if current.isVideo {
                Label("视频", systemImage: "play.rectangle")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
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

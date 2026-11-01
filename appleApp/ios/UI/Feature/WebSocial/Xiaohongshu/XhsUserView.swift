import SwiftUI
import Combine

/// 打开某个用户主页时传的东西（`sheet(item:)` 需要 `Identifiable`）。
struct XhsUserTarget: Identifiable {
    let id: String
    let name: String
}

/// 小红书用户主页（原生）：资料头 + 笔记网格。
///
/// `userId` 为空 = 「我的主页」：先调 `selfinfo` 拿到自己的 id，再按 id 拉笔记。
/// 两个接口都要签名，统一交给 `XhsService` 在真网页里发出去。
struct XhsUserView: View {
    let userId: String
    let name: String
    /// 直接当 sheet 根页打开时给一个「关闭」；从笔记里 NavigationLink 推进来时不用。
    let showsClose: Bool

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = XhsStore.shared

    @State private var profile: XhsProfile?
    @State private var notes: [XhsNote] = []
    @State private var cursor: String?
    @State private var hasMore = true
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var requested = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    init(userId: String, name: String, showsClose: Bool = false) {
        self.userId = userId
        self.name = name
        self.showsClose = showsClose
    }

    private var displayName: String {
        let value = profile?.name ?? name
        return value.isEmpty ? "用户主页" : value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.top, 14)
                content
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if showsClose {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            guard !requested else { return }
            requested = true
            await reload()
        }
    }

    // MARK: - 资料头

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                XhsImageView(url: profile?.avatar)
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    if let redId = profile?.redId, !redId.isEmpty {
                        Text("小红书号：\(redId)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let location = profile?.location, !location.isEmpty {
                        Text(location)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if loading, profile == nil {
                    ProgressView().scaleEffect(0.8)
                }
            }

            if let desc = profile?.desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 18) {
                stat("关注", profile?.follows)
                stat("粉丝", profile?.fans)
                stat("获赞与收藏", profile?.liked)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        let text = (value ?? "").isEmpty ? "-" : (value ?? "")
        return HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 笔记

    @ViewBuilder
    private var content: some View {
        if loading, notes.isEmpty, error == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if let message = error, notes.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") {
                    Task { await reload() }
                }
                .buttonStyle(.bordered)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        } else if notes.isEmpty {
            Text("还没有公开笔记")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(notes) { note in
                    NavigationLink(destination: XhsNoteView(note: note)) {
                        cell(note)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if note.id == notes.last?.id {
                            loadMore()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if loadingMore {
                ProgressView()
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else if !hasMore {
                Text("没有更多了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
    }

    private func cell(_ note: XhsNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            XhsImageView(url: note.cover)
                .aspectRatio(min(max(note.aspect, 0.5), 1.6), contentMode: .fit)
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
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
            HStack(spacing: 3) {
                Image(systemName: note.liked ? "heart.fill" : "heart")
                    .font(.system(size: 9))
                Text(note.likedCount.isEmpty ? "赞" : note.likedCount)
                    .font(.system(size: 10))
                if !note.commentCount.isEmpty {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 9))
                        .padding(.leading, 4)
                    Text(note.commentCount)
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.top, 3)
        }
    }

    // MARK: - 取数

    private func reload() async {
        await loadProfile()
        await loadNotes(reset: true)
    }

    private func loadProfile() async {
        loading = true
        do {
            let resolved: XhsProfile
            if userId.isEmpty {
                resolved = try await store.selfProfile()
            } else {
                resolved = try await store.profile(userId: userId)
            }
            await MainActor.run {
                profile = resolved
                error = nil
            }
        } catch {
            await MainActor.run {
                self.error = store.message(for: error)
            }
        }
        await MainActor.run { loading = false }
    }

    private func loadNotes(reset: Bool) async {
        let owner = profile?.id ?? userId
        guard !owner.isEmpty else {
            await MainActor.run {
                if error == nil { error = "没拿到用户 id，稍后重试" }
            }
            return
        }
        if !reset, !hasMore { return }
        if reset {
            await MainActor.run { loading = true }
        } else {
            await MainActor.run { loadingMore = true }
        }
        do {
            let page = try await store.userNotes(userId: owner, cursor: reset ? nil : cursor)
            await MainActor.run {
                if reset {
                    notes = page.notes
                } else {
                    let known = Set(notes.map { $0.id })
                    notes.append(contentsOf: page.notes.filter { !known.contains($0.id) })
                }
                cursor = page.next
                let next = (page.next ?? "").isEmpty ? false : true
                hasMore = next && !page.notes.isEmpty
                error = nil
            }
        } catch {
            await MainActor.run {
                if reset { self.error = store.message(for: error) }
            }
        }
        await MainActor.run {
            loading = false
            loadingMore = false
        }
    }

    private func loadMore() {
        guard hasMore, !loadingMore, !loading else { return }
        Task { await loadNotes(reset: false) }
    }
}
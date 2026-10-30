import SwiftUI
import UIKit

/// 小红书首页。
///
/// 版式按网页版来：两列瀑布流，卡片是「图 + 标题 + 作者 + 点赞」。
/// 真正的瀑布流要自己算列高，这里按奇偶分两列近似 —— 视觉上够用，代码短得多。
struct XhsFeedView: View {
    @ObservedObject private var store = XhsStore.shared
    @State private var showLogin = false
    @State private var selected: XhsNote?

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
                url: "https://www.xiaohongshu.com/explore",
                title: "登录小红书",
                userAgent: XhsSigner.desktopUserAgent,
                requiredCookieName: "web_session",
                cookieDomainSuffix: "xiaohongshu.com"
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
        .task {
            await store.refreshIfNeeded()
        }
    }

    private var feed: some View {
        ScrollView {
            if store.isLoading, store.notes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let message = store.errorMessage, store.notes.isEmpty {
                errorState(message)
            } else {
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        column(notesAt: 0)
                        column(notesAt: 1)
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

    private func column(notesAt offset: Int) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(store.notes.enumerated()), id: \.element.id) { index, note in
                if index % 2 == offset {
                    Button {
                        selected = note
                    } label: {
                        XhsNoteCard(note: note)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if store.isLoadingMore {
            ProgressView()
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
                    Task { await store.refresh() }
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
            Text("扫码或账号密码登录网页版，cookie 会一直留着。掉线了会回到这里。")
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

            HStack(spacing: 4) {
                XhsImageView(url: note.user.avatar)
                    .frame(width: 14, height: 14)
                    .clipShape(Circle())
                Text(note.user.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !note.likedCount.isEmpty {
                    Label(note.likedCount, systemImage: "heart")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

/// `AsyncImage` 的薄封装，失败和加载中统一灰底。
struct XhsImageView: View {
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
            }
        }
    }
}

import SwiftUI
import WebKit

/// 微信读书书架。
struct WereadShelfView: View {
    @ObservedObject private var store = WereadStore.shared
    @State private var showLogin = false
    @State private var selectedBook: WereadBook?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 16)]

    var body: some View {
        Group {
            if store.isLoggedIn {
                shelf
            } else {
                loginPrompt
            }
        }
        .navigationTitle("微信读书")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // iOS 15 的 ToolbarContentBuilder 没有 buildIf，不能在 .toolbar 里写 if，
            // 所以条件放在 ToolbarItem 的 ViewBuilder 里面。
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoggedIn {
                    Menu {
                        Button {
                            Task { await store.refreshShelf() }
                        } label: {
                            Label("刷新书架", systemImage: "arrow.clockwise")
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
            WereadLoginView { _ in
                Task { await store.refreshShelf() }
            }
        }
        .sheet(item: $selectedBook) { book in
            WereadReaderView(book: book)
        }
        .task {
            if store.isLoggedIn, store.books.isEmpty {
                await store.refreshShelf()
            }
        }
    }

    private var shelf: some View {
        ScrollView {
            if store.isLoading, store.books.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let message = store.errorMessage, store.books.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重新登录") { showLogin = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(store.books) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            bookCell(book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await store.refreshShelf()
        }
    }

    private func bookCell(_ book: WereadBook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(book)
            Text(book.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(book.author)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            if book.progress > 0 || book.finished {
                Text(book.finished ? "已读完" : "已读 \(book.progress)%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cover(_ book: WereadBook) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let cover = book.cover, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "book.closed")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "book.closed")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(3.0 / 4.2, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("登录微信读书")
                .font(.headline)
            Text("扫码登录后可以看自己的书架，读到哪里会同步回账号。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showLogin = true
            } label: {
                Text("扫码登录")
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

import SwiftUI
import WebKit

/// 微信读书书架（原生）。
///
/// 书单来自 `shelf/sync`（`books` + `archive` + `bookProgress`），同时后台用
/// 一个隐藏网页把线上书架抄一遍，补上接口漏掉的书，并记下每本书网页阅读器的
/// 真实地址。点书直接全屏进阅读器 —— 不再「先进线上书架、再点一次」。
struct WereadShelfView: View {
    @ObservedObject private var store = WereadStore.shared
    @State private var showLogin = false
    @State private var target: WereadReaderTarget?

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
                        Button {
                            // 手动同步是用户的明确意图，安全模式也放行一次。
                            LaunchGuard.allowThisRun()
                            store.syncWebShelf()
                        } label: {
                            Label("重新同步线上书架", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            store.clearReaderLinks()
                        } label: {
                            Label("清除阅读器地址缓存", systemImage: "trash.slash")
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
        .fullScreenCover(item: $target) { item in
            WereadReaderView(target: item)
        }
        .task {
            guard store.isLoggedIn else { return }
            if store.books.isEmpty {
                await store.refreshShelf()
            }
            // 老版本升级上来的用户书架有、但「bookId → 阅读器地址」是空的，
            // 先补一遍。一次启动只跑一次，别每切回标签页就重建隐藏网页。
            if store.bookLinks.isEmpty {
                store.syncWebShelfIfNeeded()
            }
        }
    }

    // MARK: - 排序与分组
    //
    // 具体规则在 WereadShelfSections 里（纯数据变换，有单元测试盯着）。

    private var shelfSections: [WereadShelfSection] {
        WereadShelfSections.make(store.books)
    }

    // MARK: - 书架

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
                if shelfSections.count <= 1 {
                    grid(flatBooks)
                        .padding(.vertical, 16)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(shelfSections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 16)
                                grid(section.books)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await store.refreshShelf()
        }
    }

    /// 认不出分组时的平铺列表（已经按最近阅读排好）。
    private var flatBooks: [WereadBook] {
        shelfSections.first?.books ?? []
    }

    private func grid(_ books: [WereadBook]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(books) { book in
                Button {
                    open(book)
                } label: {
                    bookCell(book)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    /// 点书立刻进阅读器。
    ///
    /// 有缓存地址（按 bookId 记的）就直接秒开；没有就打开网页书架，
    /// 用 `data-book-id` 精确点中这本，点到之后把真地址记下来，下次秒开。
    private func open(_ book: WereadBook) {
        if let url = store.readerLink(for: book) {
            target = WereadReaderTarget(
                url: url,
                title: book.title,
                bookId: book.id,
                needsJump: false
            )
            return
        }
        target = WereadReaderTarget(
            url: "https://weread.qq.com/web/shelf",
            title: book.title,
            bookId: book.id,
            needsJump: true
        )
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
            Text("扫码登录后可以看自己的书架，读到哪里会同步回账号。网页打不开的话，也可以在登录页里选「粘贴 Cookie」。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showLogin = true
            } label: {
                Text("登录")
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
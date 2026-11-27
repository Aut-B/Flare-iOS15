import SwiftUI
import WebKit

/// 微信读书书架（原生）。
///
/// 书单来自 `shelf/sync`（`books` + `archive` + `bookProgress`），同时后台用
/// 点书直接全屏进原生阅读器 —— 不再「先进线上书架、再点一次」。
struct WereadShelfView: View {
    @ObservedObject private var store = WereadStore.shared
    @State private var showLogin = false
    @State private var nativeTarget: WereadNativeTarget?

    /// 6S 有「标准 375pt」和「放大 320pt」两种逻辑宽度。
    /// 固定两列均分：左右各 12pt、列间 10pt，两列边界都能由同一公式算出；
    /// 不再用单个 adaptive 列，避免宽封面把某一格撑宽后压到邻格。
    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

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
        .fullScreenCover(item: $nativeTarget) { item in
            // `.id` 必须跟着书走：fullScreenCover 会复用上一次的视图实例，
            // 不加 id 时换书打开会沿用上一本的 @State（标题、章节、正文），
            // 看起来就像「点了 A 显示 B」。
            WereadNativeReaderView(target: item)
                .id(item.id)
        }
        .task {
            guard store.isLoggedIn else { return }
            if store.books.isEmpty {
                await store.refreshShelf()
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
            } else if let message = store.shelfLoadError, store.books.isEmpty {
                // 暂时失败（网络/超时）：保留登录态，只给重试，不弹「重新登录」，
                // 也绝不白屏 —— 这是用户「第二次进去什么都没有」的那条路径。
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试书架") {
                        Task { await store.refreshShelf() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
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
            } else if store.books.isEmpty {
                // 兜底：已登录、书架空、又没有任何状态提示时不许留白屏。
                // 显示加载态并给重试入口，.task 会尝试拉取，用户也能手动点。
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在加载书架…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("重试书架") {
                        Task { await store.refreshShelf() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else {
                if shelfSections.count <= 1 {
                    grid(flatBooks)
                        .padding(.vertical, 10)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shelfSections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                grid(section.books)
                            }
                        }
                    }
                    .padding(.vertical, 10)
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
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(books) { book in
                Button {
                    open(book)
                } label: {
                    bookCell(book)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    /// 点书立刻进原生阅读器。
    ///
    /// 目录和正文都直接走接口，不再先打开 `/web/shelf`，所以不会出现
    /// 「正在打开」很久、网页书架盖在书上面、或者标题还是上一本书的问题。
    private func open(_ book: WereadBook) {
        nativeTarget = WereadNativeTarget(book: book)
    }

    private func bookCell(_ book: WereadBook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            cover(book)
            Text(book.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(book.author.isEmpty ? " " : book.author)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(progressText(book))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 整格（封面 + 书名 + 作者/进度）裁在自己的 bounds 内，
        // 宽幅套装封面或超长书名都碰不到相邻格。
        .clipped()
        .contentShape(Rectangle())
    }

    private func progressText(_ book: WereadBook) -> String {
        if book.finished {
            return "已读完"
        }
        if book.progress > 0 {
            return "已读 \(book.progress)%"
        }
        return "未读"
    }

    private func cover(_ book: WereadBook) -> some View {
        // Color 先锁死单格封面比例，再让图片 cover 填满并裁切；
        // 宽幅多册套装图不会按原图宽度撑开格子。
        Color(.tertiarySystemFill)
            .aspectRatio(3.0 / 4.2, contentMode: .fit)
            .overlay {
                coverImage(book)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            )
            .clipped()
    }

    @ViewBuilder
    private func coverImage(_ book: WereadBook) -> some View {
        if let cover = book.cover, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    coverPlaceholder
                }
            }
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        Image(systemName: "book.closed")
            .font(.system(size: 22))
            .foregroundStyle(.secondary)
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

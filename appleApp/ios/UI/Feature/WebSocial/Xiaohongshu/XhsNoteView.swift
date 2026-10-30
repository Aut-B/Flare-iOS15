import SwiftUI

/// 笔记详情：图逐张铺开，下面是正文。
struct XhsNoteView: View {
    let note: XhsNote

    @Environment(\.dismiss) private var dismiss
    @State private var detail: XhsNote?
    @State private var errorText: String?

    private var current: XhsNote { detail ?? note }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                images
                header
                if !current.desc.isEmpty {
                    Text(current.desc)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                if let errorText = errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
                openInBrowser
            }
            .padding(.bottom, 28)
        }
        .navigationTitle(current.user.name.isEmpty ? "笔记" : current.user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
        .task {
            guard detail == nil else { return }
            do {
                detail = try await XhsService.shared.note(id: note.id)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private var images: some View {
        VStack(spacing: 2) {
            ForEach(Array(current.images.enumerated()), id: \.offset) { _, url in
                XhsImageView(url: url)
                    .aspectRatio(current.aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !current.title.isEmpty {
                Text(current.title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                XhsImageView(url: current.user.avatar)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                Text(current.user.name)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                if !current.likedCount.isEmpty {
                    Label(current.likedCount, systemImage: "heart")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
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

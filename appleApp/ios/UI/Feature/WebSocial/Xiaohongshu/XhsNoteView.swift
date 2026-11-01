import SwiftUI
import AVFoundation
import AVKit

/// 笔记详情：视频能直接播，图逐张铺开，下面是正文。
struct XhsNoteView: View {
    let note: XhsNote

    @Environment(\.dismiss) private var dismiss
    @State private var detail: XhsNote?
    @State private var errorText: String?
    @State private var player: AVPlayer?

    private var current: XhsNote { detail ?? note }

    /// 详情接口偶尔拿不到，但首页流里本来就带视频直链，先用着。
    private var videoURL: String? {
        current.videoURL ?? note.videoURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                media
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
        .onDisappear {
            player?.pause()
        }
        .task {
            // 首页流里已经带了标题、正文、图片、视频，够看了。只有正文缺了
            // 才去问详情接口 —— 那个接口要拉起签名页，为了一点正文不值当。
            guard detail == nil, note.desc.isEmpty else { return }
            do {
                detail = try await XhsService.shared.note(id: note.id)
            } catch {
                // 详情接口被风控挡了不影响看：首页流里的标题、正文、图片、视频都在。
                errorText = nil
            }
        }
    }

    @ViewBuilder
    private var media: some View {
        if let urlString = videoURL, let url = URL(string: urlString) {
            VideoPlayer(player: player)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .onAppear {
                    if player == nil {
                        player = AVPlayer(url: url)
                    }
                }
        } else {
            VStack(spacing: 2) {
                ForEach(Array(current.images.enumerated()), id: \.offset) { _, url in
                    XhsImageView(url: url)
                        .aspectRatio(current.aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
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

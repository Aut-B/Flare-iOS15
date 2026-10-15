import SwiftUI
import KotlinSharedUI
import FlareAppleCore
import AVFoundation

#if os(iOS)
import UIKit
import Perception
#endif

public struct MediaView: View {
    private let data: UiMedia
    private let allowsAutoplay: Bool

    public init(data: UiMedia, allowsAutoplay: Bool = true) {
        self.data = data
        self.allowsAutoplay = allowsAutoplay
    }

    public var body: some View {
        ZStack {
            switch onEnum(of: data) {
            case .image(let image):
                Color.gray
                    .overlay {
                        NetworkImage(data: image.previewUrl, customHeader: image.customHeaders)
                            .allowsHitTesting(false)
                    }
                    .clipped()
            case .video(let video):
                MediaVideoView(data: video, allowsAutoplay: allowsAutoplay)
            case .gif(let gif):
                Color.gray
                    .overlay {
                        NetworkImage(data: gif.url, customHeader: gif.customHeaders)
                            .allowsHitTesting(false)
                    }
                    .clipped()
            case .ugoira(let animation):
                MediaVideoView(data: animation, allowsAutoplay: allowsAutoplay)
            case .audio:
                EmptyView()
            }
        }
        .accessibilityLabel(Text(verbatim: data.accessibleDescription))
    }
}

public struct MediaVideoView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.timelineAppearance.videoAutoplay) private var videoAutoplay
    @Environment(\.networkKind) private var networkKind
    @Environment(\.timelinePlaybackCoordinator) private var timelinePlayback
    @Environment(\.timelineCarouselItem) private var carouselItem
    @Environment(\.isMultipleColumn) private var isMultipleColumn
    @Environment(\.timelinePlaybackViewport) private var timelinePlaybackViewport
    @State private var fallbackPlayback = TimelinePlaybackCoordinator()
    @State private var player = VideoPlaybackSession()
    @State private var ugoira = UgoiraPlaybackSession()
    @State private var id = UUID().uuidString
    @State private var geometry = InlineVideoGeometry()
    @State private var appeared = false
    private let data: any UiMedia
    private let allowsAutoplay: Bool

    public init(data: UiMediaVideo, allowsAutoplay: Bool = true) {
        self.data = data
        self.allowsAutoplay = allowsAutoplay
    }

    public init(data: UiMediaUgoira, allowsAutoplay: Bool = true) {
        self.data = data
        self.allowsAutoplay = allowsAutoplay
    }

    private var playback: TimelinePlaybackCoordinator { timelinePlayback ?? fallbackPlayback }

    private var canAutoplay: Bool {
        guard allowsAutoplay else { return false }
        switch videoAutoplay {
        case .always: return true
        case .wifi: return networkKind == .wifi
        case .never: return false
        }
    }

    public var body: some View {
        // iOS 15 回退：@Perceptible 属性必须在 withPerceptionTracking 作用域内读取才会被登记。
        WithPerceptionTracking {

        Color.gray
            .overlay {
                // iOS 15 回退：overlay 的内容闭包是惰性求值的，@Perceptible 的读取
                // 必须再包一层才会被登记（player / ugoira 是 @Perceptible）。
                WithPerceptionTracking {
                    NetworkImage(data: data.mediaPreviewURL, customHeader: data.customHeaders)
                        .allowsHitTesting(false)
                        .opacity(data is UiMediaUgoira && ugoira.image != nil ? 0 : 1)
                }
            }
            .clipped()
            .overlay {
                WithPerceptionTracking {
                    if let animation = data as? UiMediaUgoira, ugoira.image != nil {
                        UgoiraFrameView(media: animation, session: ugoira).allowsHitTesting(false)
                    } else if let avPlayer = player.player {
                        #if os(macOS)
                        MacAVPlayerView(player: avPlayer, videoGravity: .resizeAspectFill, showsControls: false,
                                        canDisplayFrame: player.hasRestoredPosition)
                            .id(data.url)
                            .allowsHitTesting(false)
                        #elseif os(iOS)
                        InlineAVPlayerView(player: avPlayer, canDisplayFrame: player.hasRestoredPosition)
                            .id(data.url)
                            .allowsHitTesting(false)
                        #endif
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                // iOS 15 回退：同 overlay 内容闭包惰性求值，statusOverlay 内部读
                // player.state / player.position，必须包一层才会被登记。
                WithPerceptionTracking {
                    statusOverlay
                }
            }
            // onGeometryChange + bounds(of: .scrollView) 分别是 iOS 16 / iOS 17 的 API。
            // iOS 15 下退化为「自身 bounds ∩ 全局坐标换算出的可视区」，丢掉横向滚动的那一次裁剪。
            .flareOnGeometry({ proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let globalBounds = proxy.frame(in: .global)
                let viewport = timelinePlaybackViewport?.offsetBy(dx: -globalBounds.minX, dy: -globalBounds.minY) ?? bounds
                let visible = bounds.intersection(viewport)
                return InlineVideoGeometry(
                    visible: !visible.isEmpty,
                    horizontalFraction: bounds.width > 0 ? max(0, visible.width) / bounds.width : 0,
                    distance: TimelineAutoplayPolicy.centerDistance(of: bounds, in: viewport, multipleColumns: isMultipleColumn),
                    verticalOffset: globalBounds.minY
                )
            }, action: { value in
                if #unavailable(iOS 18.0, macOS 15.0) {
                    if let oldOffset = geometry.verticalOffset, oldOffset != value.verticalOffset {
                        playback.moved(source: "vertical", vertical: true)
                    }
                }
                geometry = value
                updateCandidate()
            })
            .onAppear {
                if timelinePlayback == nil { fallbackPlayback.setSuspended(scenePhase != .active) }
                appeared = true
                registerPlayer()
                updateCandidate()
            }
            .backportOnChange(of: canAutoplay) { _, _ in updateCandidate() }
            .backportOnChange(of: scenePhase) { _, phase in
                if timelinePlayback == nil { fallbackPlayback.setSuspended(phase != .active) }
            }
            .backportOnChange(of: carouselItem) { _, _ in updateCandidate() }
            .backportOnChange(of: data.url) { _, _ in
                playback.remove(id: id)
                player.detach()
                ugoira.detach()
                registerPlayer()
                updateCandidate()
            }
            .onDisappear {
                appeared = false
                playback.remove(id: id)
                player.detach()
                ugoira.detach()
                if timelinePlayback == nil { fallbackPlayback.setSuspended(true) }
            }
        }
    }

    private func registerPlayer() {
        let url = data.url
        let coordinator = playback
        let model = player
        let animation = data as? UiMediaUgoira
        let ugoiraModel = ugoira
        coordinator.register(id: id) { playing in
            if playing {
                if let animation { ugoiraModel.play(animation) } else { model.play(url: url) }
            } else {
                model.detach()
                ugoiraModel.detach()
            }
        }
    }

    private func updateCandidate() {
        guard appeared else { return }
        playback.update(.init(
            id: id,
            groupID: carouselItem?.groupID,
            isVisible: geometry.visible && canAutoplay,
            isSelected: carouselItem?.isSelected ?? true,
            canStart: canAutoplay && (carouselItem?.isCarousel != true || geometry.horizontalFraction >= 0.6),
            distance: geometry.distance,
            mediaURL: data.url
        ))
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if data is UiMediaUgoira {
            UgoiraStatusOverlay(session: ugoira)
        } else {
            switch player.state {
            case .idle, .paused:
                Image(fontAwesome: .circlePlay).mediaVideoBadgeStyle()
            case .loading:
                ProgressView().accentColor(.white).mediaVideoBadgeStyle()
            case .playing(let duration):
                let remaining = max(Int((duration - player.position).rounded(.down)), 0)
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .mediaVideoBadgeStyle()
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").mediaVideoBadgeStyle()
            }
        }
    }
}

private nonisolated struct InlineVideoGeometry: Equatable, Sendable {
    var visible = false
    var horizontalFraction: CGFloat = 0
    var distance: Double = 0
    var verticalOffset: CGFloat?
}

#if os(iOS)
struct InlineAVPlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    var canDisplayFrame = true
    var onReady: () -> Void = {}

    func makeUIView(context: Context) -> VideoPlaybackSurfaceView {
        let view = VideoPlaybackSurfaceView()
        view.onReady = onReady
        view.canDisplayFrame = canDisplayFrame
        view.playerLayer.videoGravity = videoGravity
        view.player = player
        return view
    }

    func updateUIView(_ view: VideoPlaybackSurfaceView, context: Context) {
        view.onReady = onReady
        view.canDisplayFrame = canDisplayFrame
        view.player = player
        view.playerLayer.videoGravity = videoGravity
    }

    static func dismantleUIView(_ view: VideoPlaybackSurfaceView, coordinator: ()) {
        view.onReady = {}
        view.player = nil
    }
}
#endif

extension View {
    func mediaVideoBadgeStyle() -> some View {
        padding(8)
            .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()
            .foregroundStyle(.white)
    }
}

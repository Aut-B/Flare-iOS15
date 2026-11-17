import SwiftUI
import FlareAppleUI
import KotlinSharedUI
import LazyPager
import AVKit
import Photos
import Kingfisher
import VideoPlayer
import Combine
import UIKit
import FlareAppleCore

struct StatusMediaScreen: View {
    let accountType: AccountType
    let statusKey: MicroBlogKey
    let initialIndex: Int
    let preview: String?
    let initialMediaAspectRatio: CGFloat?
    let initialMediaIsImage: Bool
    @StateObject private var presenter: KotlinPresenter<StatusState>
    @State private var medias: [any UiMedia] = []

    var body: some View {
        MediaViewerScreen(
            medias: medias,
            initialIndex: initialIndex,
            preview: preview,
            previewProxy: ProxyRef.companion.forAccountType(accountType: accountType),
            previewAspectRatio: initialMediaAspectRatio,
            previewIsImage: initialMediaIsImage,
            shareContext: MediaViewerShareContext(
                statusKey: statusKey.description(),
                userHandle: statusUserHandle
            ),
            post: statusPost,
            quotes: statusQuotes
        )
        .onAppear {
            syncMediasIfNeeded(animated: false)
        }
        .backportOnChange(of: presenter.state.status) { oldValue, newValue in
            syncMediasIfNeeded(animated: true)
        }
    }

    private func syncMediasIfNeeded(animated: Bool) {
        if medias.isEmpty,
           case .success(let success) = onEnum(of: presenter.state.status),
           let content = success.data.timelineContentPost {
            if animated {
                withAnimation {
                    medias = Array(content.images)
                }
            } else {
                medias = Array(content.images)
            }
        }
    }

    private var statusPost: UiTimelineV2.Post? {
        if case .success(let success) = onEnum(of: presenter.state.status) {
            return success.data.timelineContentPost
        }
        return nil
    }

    private var statusQuotes: [UiTimelineV2.Post] {
        if case .success(let success) = onEnum(of: presenter.state.status),
           case .timelinePostItem(let item) = onEnum(of: success.data) {
            return Array(item.presentation.quotes)
        }
        return []
    }

    private var statusUserHandle: String {
        if case .success(let success) = onEnum(of: presenter.state.status),
           let content = success.data.timelineContentPost {
            return content.user?.handle.canonical ?? "unknown"
        }
        return "unknown"
    }
}

struct LazyPagerIndicator: View {
    let count: Int
    @Binding var page: Int
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

extension StatusMediaScreen {
    init(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        initialIndex: Int,
        preview: String?,
        initialMediaAspectRatio: CGFloat?,
        initialMediaIsImage: Bool
    ) {
        self.accountType = accountType
        self.statusKey = statusKey
        self.initialIndex = initialIndex
        self.preview = preview
        self.initialMediaAspectRatio = initialMediaAspectRatio
        self.initialMediaIsImage = initialMediaIsImage
        self._presenter = .init(wrappedValue: .init(presenter: StatusPresenter(accountType: accountType, statusKey: statusKey)))
    }
}

@MainActor
enum MediaOrientationController {
    static func setLandscape(_ enabled: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }

        let orientations: UIInterfaceOrientationMask = enabled ? .landscapeRight : .portrait
        if #available(iOS 16.0, *) {
            scene.mediaKeyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                print("Media orientation request failed: \(error)")
            }
        } else {
            // iOS 15 回退：requestGeometryUpdate 是 iOS 16 API。走 UIDevice 的方向 KVC
            // + attemptRotationToDeviceOrientation，效果等价。
            let deviceOrientation: UIInterfaceOrientation = enabled ? .landscapeRight : .portrait
            UIDevice.current.setValue(deviceOrientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

private extension UIWindowScene {
    var mediaKeyWindow: UIWindow? {
        windows.first { $0.isKeyWindow }
    }
}

struct AdaptiveKFImage: View {
    let data: any UiMedia
    let placeholder: UiMedia?
    let mediaAspectRatio: CGFloat?
    var onImageFailure: (() -> Void)? = nil
    @State private var measuredImageSize: CGSize?
    @State private var isLoading = false
    @State private var loadFailed = false

    private var shouldFill: Bool {
        MediaViewerImageLayoutPolicy.shouldFillWidth(mediaAspectRatio: mediaAspectRatio, measuredImageSize: measuredImageSize)
    }
    var body: some View {
        Group {
            if shouldFill { ScrollView(.vertical, showsIndicators: false) { image } }
            else { image }
        }
    }
    private var image: some View {
        NetworkImage(data: data, placeholder: placeholder, contentMode: shouldFill ? .fill : .fit,
                     onProgress: { isLoading = $0.map { $0 < 1 } ?? false },
                     onImageFailure: {
                         loadFailed = true
                         onImageFailure?()
                     },
                     onImageSize: {
                         loadFailed = false
                         measuredImageSize = $0
                     },
                     keepsCurrentImage: true)
            .originalImage()
            .overlay { if isLoading, !data.isRemote { ProgressView() } }
            .overlay {
                if loadFailed {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
    }
}

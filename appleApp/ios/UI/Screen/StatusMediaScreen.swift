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
    let data: String
    let placeholder: String?
    let customHeader: [String: String]?
    let mediaAspectRatio: CGFloat?

    @State private var measuredImageSize: CGSize?
    /// 加载失败标记。Kingfisher 的 placeholder 只在加载中显示，失败后会消失，
    /// 而查看器是黑底——失败时用户看到的就是一块纯黑，必须显式兜底。
    @State private var loadFailed = false

    init(
        data: String,
        placeholder: String?,
        customHeader: [String: String]? = nil,
        mediaAspectRatio: CGFloat? = nil
    ) {
        self.data = data
        self.placeholder = placeholder
        self.customHeader = customHeader
        self.mediaAspectRatio = mediaAspectRatio
    }

    private var shouldFill: Bool {
        MediaViewerImageLayoutPolicy.shouldFillWidth(
            mediaAspectRatio: mediaAspectRatio,
            measuredImageSize: measuredImageSize
        )
    }

    var body: some View {
        if shouldFill {
            ScrollView(.vertical, showsIndicators: false) {
                kfImageView
            }
        } else {
            kfImageView
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        if let placeholder {
            NetworkImage(
                data: placeholder,
                customHeader: customHeader,
                contentMode: shouldFill ? .fill : .fit
            )
        } else {
            // 给 ProgressView 确定尺寸：无图阶段 KFImage 高度为 0，
            // ZStack 会跟着塌成 0，加载指示也跟着消失。
            ProgressView()
                .frame(width: 48, height: 48)
        }
    }

    var kfImageView: some View {
        ZStack {
            if URL(string: data)?.pathExtension.lowercased() == "gif" {
                KFAnimatedImage(.init(string: data))
                    // iOS 15 回退：与时间线 NetworkImage 的加载链保持一致。
                    // 上游这里缺 loadDiskFileSynchronously(false)，iOS 15 上同步
                    // 解码大图会导致原图在查看器里加载不出（表现为纯黑）。
                    .loadDiskFileSynchronously(false)
                    .requestModifier({ request in
                        if let customHeader {
                            for (key, value) in customHeader {
                                request.setValue(value, forHTTPHeaderField: key)
                            }
                        }
                    })
                    .placeholder { placeholderView }
                    .onSuccess { result in
                        loadFailed = false
                        measuredImageSize = result.image.size
                    }
                    .onFailure { _ in
                        loadFailed = true
                    }
                    .fade(duration: 0.25)
                    .aspectRatio(contentMode: shouldFill ? .fill : .fit)
            } else {
                KFImage(.init(string: data))
                    .loadDiskFileSynchronously(false)
                    .requestModifier({ request in
                        if let customHeader {
                            for (key, value) in customHeader {
                                request.setValue(value, forHTTPHeaderField: key)
                            }
                        }
                    })
                    .placeholder { placeholderView }
                    .onSuccess { result in
                        loadFailed = false
                        measuredImageSize = result.image.size
                    }
                    .onFailure { _ in
                        loadFailed = true
                    }
                    .fade(duration: 0.25)
                    .resizable()
                    .aspectRatio(contentMode: shouldFill ? .fill : .fit)
            }
            if loadFailed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        // 给 ZStack 确定的空间：无图/无比例阶段由外层约束撑开，
        // 避免查看器塌成一块黑。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

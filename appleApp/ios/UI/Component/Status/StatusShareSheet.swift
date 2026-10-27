import SwiftUI
import KotlinSharedUI
import UniformTypeIdentifiers
import FlareAppleCore
import FlareAppleUI

private enum SharePreviewStyle: Hashable {
    case card
    case content
}

struct StatusShareSheet: View {
    let statusKey: MicroBlogKey
    let accountType: AccountType
    let shareUrl: String
    let fxShareUrl: String?
    let fixvxShareUrl: String?
    let onCrossPost: (ComposePrefill) -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timelineAppearance) private var timelineAppearance
    @StateObject private var presenter: KotlinPresenter<StatusState>
    @State private var renderScale: CGFloat = 2.0
    @State private var theme: ColorScheme? = nil
    @State private var previewStyle: SharePreviewStyle = .card
    @State private var image: UIImage? = nil
    
    init(
        statusKey: MicroBlogKey,
        accountType: AccountType,
        shareUrl: String,
        fxShareUrl: String?,
        fixvxShareUrl: String?,
        onCrossPost: @escaping (ComposePrefill) -> Void
    ) {
        self.statusKey = statusKey
        self.accountType = accountType
        self.shareUrl = shareUrl
        self.fxShareUrl = fxShareUrl
        self.fixvxShareUrl = fixvxShareUrl
        self.onCrossPost = onCrossPost
        self._presenter = .init(wrappedValue: .init(presenter: StatusPresenter(accountType: accountType, statusKey: statusKey)))
    }
    
    var body: some View {
        List {
            StateView(state: presenter.state.status) { data in
                ViewBox {
                    ZStack {
                        previewView(data: data)
                            .padding()
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                            }
                    }
                }
                .frame(minHeight: 200, maxHeight: 360)
                .listRowSeparator(.hidden)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                
                Section {
                    // 截图放在最前面：这是这个面板的主功能。
                    if let image {
                        BackportShareLink(item: image) {
                            Label("share_screenshot", systemImage: "photo")
                        }
                    } else {
                        // 渲染中保留占位，避免「分享截图」按钮突然消失、看起来像没有截图功能。
                        HStack(spacing: 12) {
                            Label("share_screenshot", systemImage: "photo")
                            Spacer(minLength: 0)
                            ProgressView()
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        saveImage()
                    } label: {
                        Label("save_screenshot", systemImage: "arrow.down.circle")
                    }
                    .disabled(image == nil)

                    Button {
                        crossPost()
                    } label: {
                        Label {
                            Text("share_crosspost")
                        } icon: {
                            Image(fontAwesome: .retweet)
                        }
                    }
                    .disabled(image == nil)

                    if let url = URL(string: shareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_link", systemImage: "link")
                        }
                    }

                    if let fxShareUrl, let url = URL(string: fxShareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_via_fxembed", systemImage: "link")
                        }
                    }
                    
                    if let fixvxShareUrl, let url = URL(string: fixvxShareUrl) {
                        BackportShareLink(item: url) {
                            Label("share_via_fixvx", systemImage: "link")
                        }
                    }
                }
                
                Picker("appearance_theme", selection: $theme) {
                    Text("appearance_theme_system").tag(nil as ColorScheme?)
                    Text("appearance_theme_light").tag(Optional(ColorScheme.light))
                    Text("appearance_theme_dark").tag(Optional(ColorScheme.dark))
                }

                Picker("appearance_layout_group_title", selection: $previewStyle) {
                    Text("appearance_timeline_display_mode_card").tag(SharePreviewStyle.card)
                    Text("status_share_sheet_preview_content").tag(SharePreviewStyle.content)
                }
            } loadingContent: {
                TimelinePlaceholderView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(
                    role: .cancel
                ) {
                    dismiss()
                } label: {
                    Label {
                        Text("Cancel")
                    } icon: {
                        Image(fontAwesome: .xmark)
                    }
                }
            }
        }
        .navigationTitle("fx_share")
        .onSuccessOf(of: presenter.state.status) { data in
            image = nil
            Task {
                image = await renderImage(data: data)
            }
        }
        .backportOnChange(of: theme) { oldValue, newValue in
            if case .success(let data) = onEnum(of: presenter.state.status) {
                image = nil
                Task {
                    image = await renderImage(data: data.data)
                }
            }
        }
        .backportOnChange(of: previewStyle) { oldValue, newValue in
            if case .success(let data) = onEnum(of: presenter.state.status) {
                image = nil
                Task {
                    image = await renderImage(data: data.data)
                }
            }
        }
    }
    
    @ViewBuilder
    private func previewView(data: UiTimelineV2) -> some View {
        TimelineView(data: data, detailStatusKey: statusKey, showTranslate: false)
            .frame(width: 360)
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .if(previewStyle == .card) { view in
                view
                    .clipShape(.rect(cornerRadius: 16))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 8)
                    .padding(64)
            }
            .background(Color(.systemGroupedBackground))
            .environment(\.colorScheme, theme ?? colorScheme)
            .environment(\.timelineAppearance, timelineAppearance.withSharePreviewDefaults())
    }
    
    
    private func renderImage(data: UiTimelineV2) async -> UIImage? {
        return await previewView(data: data).snapshot(
            colorScheme: theme ?? colorScheme
        )
    }
    
    private func saveImage() {
        guard let image = image else { return }
        MediaSaver.shared.saveImage(image)
        dismiss()
    }

    private func crossPost() {
        guard let imageData = image?.pngData() else { return }
        onCrossPost(
            ComposePrefill(
                text: "\n\n\(shareUrl)",
                cursorPosition: 0,
                imageData: imageData,
                fileName: "flare-crosspost.png"
            )
        )
    }
}

private extension TimelineAppearance {
    func withSharePreviewDefaults() -> TimelineAppearance {
        doCopy(
            avatarShape: avatarShape,
            showMedia: showMedia,
            showSensitiveContent: showSensitiveContent,
            expandContentWarning: true,
            expandMediaSize: expandMediaSize,
            mediaLayout: mediaLayout,
            limitMediaGridToNine: limitMediaGridToNine,
            videoAutoplay: .never,
            showLinkPreview: showLinkPreview,
            compatLinkPreview: compatLinkPreview,
            showEmojiReactions: showEmojiReactions,
            showNumbers: showNumbers,
            postActionStyle: postActionStyle,
            postActionLayout: postActionLayout,
            postActionFixedWidth: postActionFixedWidth,
            fullWidthPost: fullWidthPost,
            absoluteTimestamp: absoluteTimestamp,
            showPlatformLogo: showPlatformLogo,
            timelineDisplayMode: timelineDisplayMode,
            aiConfig: aiConfig,
            lineLimit: lineLimit,
            showTranslateButton: showTranslateButton
        )
    }
}

extension View {
    @MainActor
    func snapshot(
        colorScheme: ColorScheme,
        delay: TimeInterval = 0.1
    ) async -> UIImage? {
        let controller = UIHostingController(rootView: self.edgesIgnoringSafeArea(.top))
        controller.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        guard let view = controller.view else { return nil }

        // UIHostingController 的 intrinsicContentSize 有时会是 -1 或 0（内含
        // UIViewRepresentable 时尤其常见），直接用会渲染出一张空图。
        var targetSize = view.intrinsicContentSize
        if targetSize.width < 1 || targetSize.height < 1 {
            targetSize = controller.sizeThatFits(
                in: CGSize(
                    width: UIView.layoutFittingCompressedSize.width,
                    height: UIView.layoutFittingCompressedSize.height
                )
            )
        }
        guard targetSize.width >= 1,
              targetSize.height >= 1,
              targetSize.width.isFinite,
              targetSize.height.isFinite
        else {
            return nil
        }

        view.bounds = CGRect(origin: .zero, size: targetSize)
        view.backgroundColor = .systemGroupedBackground
        view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        view.layoutIfNeeded()

        // 超长微博降采样，避免 3x 渲染长图时爆内存。
        var scale: CGFloat = 3
        if targetSize.height * scale > 12_000 { scale = 2 }
        if targetSize.height * scale > 12_000 { scale = 1 }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }
}

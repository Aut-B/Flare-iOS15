import SwiftUI
import KotlinSharedUI
import FlareAppleCore

public typealias TimelineMediaOpenAction = (UiTimelineV2.Post, any UiMedia, Int) -> Void
public enum TimelineMediaMenuAction {
    case download
    case downloadAll
    case shareImage
    case copyLink
}
public typealias TimelineMediaActionHandler = (UiTimelineV2.Post, any UiMedia, TimelineMediaMenuAction) -> Void

public extension EnvironmentValues {
    @Entry var timelineMediaOpenAction: TimelineMediaOpenAction? = nil
    @Entry var timelineMediaActionHandler: TimelineMediaActionHandler? = nil
}

public struct StatusView: View {
    @Environment(\.timelineAppearance.fullWidthPost) private var fullWidthPost
    @Environment(\.timelineAppearance.showLinkPreview) private var showLinkPreview
    @Environment(\.timelineAppearance.compatLinkPreview) private var compatLinkPreview
    @Environment(\.timelineAppearance.showEmojiReactions) private var showEmojiReactions
    @Environment(\.timelineAppearance.postActionStyle) private var postActionStyle
    @Environment(\.timelineAppearance.showPlatformLogo) private var showPlatformLogo
    @Environment(\.timelineAppearance.expandContentWarning) private var expandContentWarning
    @Environment(\.timelineAppearance.lineLimit) private var appearanceLineLimit
    @Environment(\.timelineAppearance.mediaLayout) private var mediaLayout
    @Environment(\.timelineAppearance.aiConfig.agent) private var agentEnabled
    @Environment(\.translateConfig) private var translateConfig
    @Environment(\.openURL) private var openURL
    @Environment(\.timelineMediaOpenAction) private var timelineMediaOpenAction
    private let data: UiTimelineV2.Post
    private let isDetail: Bool
    private let isQuote: Bool
    private let isClickable: Bool
    private let withLeadingPadding: Bool
    private let showMedia: Bool
    private let showAttachments: Bool
    private let maxLine: Int?
    private let showExpandTextButton: Bool
    private let forceHideActions: Bool
    private let showTranslate: Bool
    private let showParents: Bool
    private let inlineParents: [UiTimelineV2.TimelinePostItem]
    private let quotes: [UiTimelineV2.Post]
    private let allowsMediaCarousel: Bool
    private let carouselOuterHorizontalPadding: CGFloat
    @State private var contentWarningExpanded = false
    @State private var textExpanded = false
    @State private var overflowingTextIndexes: Set<Int> = []
    @State private var showManageMenu = false
    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false

    /// 服务端支持改正文的平台：毛象（含 Pleroma）和 Misskey。
    private var supportsEditing: Bool {
        switch data.platformId.lowercased() {
        case "mastodon", "misskey":
            return true
        default:
            return false
        }
    }

    /// 置顶 / 改可见范围是微博的接口，别的平台点了一定报错，按平台分菜单。
    private var isWeibo: Bool {
        data.platformId.lowercased() == "vvo"
    }

    public init(
        data: UiTimelineV2.Post,
        isDetail: Bool = false,
        isQuote: Bool = false,
        isClickable: Bool = true,
        withLeadingPadding: Bool = false,
        showMedia: Bool = true,
        showAttachments: Bool = true,
        maxLine: Int? = nil,
        showExpandTextButton: Bool = true,
        forceHideActions: Bool = false,
        showTranslate: Bool = true,
        showParents: Bool = true,
        inlineParents: [UiTimelineV2.TimelinePostItem] = [],
        quotes: [UiTimelineV2.Post] = [],
        allowsMediaCarousel: Bool = false,
        carouselOuterHorizontalPadding: CGFloat = 0
    ) {
        self.data = data
        self.isDetail = isDetail
        self.isQuote = isQuote
        self.isClickable = isClickable
        self.withLeadingPadding = withLeadingPadding
        self.showMedia = showMedia
        self.showAttachments = showAttachments
        self.maxLine = maxLine
        self.showExpandTextButton = showExpandTextButton
        self.forceHideActions = forceHideActions
        self.showTranslate = showTranslate
        self.showParents = showParents
        self.inlineParents = inlineParents
        self.quotes = quotes
        self.allowsMediaCarousel = allowsMediaCarousel
        self.carouselOuterHorizontalPadding = carouselOuterHorizontalPadding
    }

    private var showAsFullWidth: Bool {
        (!fullWidthPost || withLeadingPadding) && !isQuote && !isDetail
    }
    public var body: some View {
        let parents = inlineParents
        let user = data.user
        let carouselEdgePadding: CGFloat = isQuote ? 8 : carouselOuterHorizontalPadding
        let carouselLeadingPadding = carouselEdgePadding + (showAsFullWidth && user != nil ? 52 : 0)
        let replyToHandle = data.replyToHandle
        let translationDisplayed = data.translationDisplayState == .translated
        let contentWarnings: [UiRichText] = if let warning = data.contentWarning {
            if translationDisplayed, let translation = warning.translation {
                translateConfig.showOriginalWithTranslation ? [warning.original, translation] : [translation]
            } else {
                [warning.original]
            }
        } else {
            []
        }
        let contentWarningIsEmpty = contentWarnings.allSatisfy(\.isEmpty)
        let contents: [UiRichText] = if translationDisplayed, let translation = data.content.translation {
            translateConfig.showOriginalWithTranslation ? [data.content.original, translation] : [translation]
        } else {
            [data.content.original]
        }
        let poll = data.poll
        let images = Array(data.images)
        let hasImages = !images.isEmpty
        let usesSideAvatarCarousel =
            showAsFullWidth &&
            user != nil &&
            showMedia &&
            showAttachments &&
            allowsMediaCarousel &&
            mediaLayout == .carousel &&
            images.count > 1
        let sensitive = data.sensitive
        let card = data.card
        let quoteItems = self.quotes
        let hasQuotes = !quoteItems.isEmpty
        let sourceChannelName = data.sourceChannel?.name
        let ipLocation: String? = data.ipLocation.flatMap { $0.isEmpty ? nil : $0 }
        let emojiReactions = Array(data.emojiReactions)
        let hasEmojiReactions = showEmojiReactions && !emojiReactions.isEmpty
        let visibility = data.visibility
        let translationDisplayState = data.translationDisplayState
        let createdAt = data.createdAt
        let actions = Array(data.actions)
        let accountType = data.accountType
        let statusKey = data.statusKey
        let effectiveLineLimit = max(maxLine ?? Int(appearanceLineLimit), 1)
        let contentLineLimit: Int? = isDetail || textExpanded ? nil : effectiveLineLimit
        let collapseThreshold = maxLine == nil ? max(15, effectiveLineLimit) : effectiveLineLimit
        let canExpandLineLimitedContent = contentLineLimit != nil && !isDetail && !textExpanded && showExpandTextButton
        let hasPreMediaBody =
            replyToHandle != nil ||
            !contentWarningIsEmpty ||
            contents.contains { !$0.isEmpty } ||
            (isDetail && showTranslate) ||
            (poll != nil && showMedia)

        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            if !parents.isEmpty, showParents {
                ForEach(parents, id: \.itemKey) { parent in
                    VStack(
                        spacing: 0
                    ) {
                        StatusView(
                            data: parent.displayPost,
                            withLeadingPadding: true,
                            quotes: Array(parent.presentation.quotes),
                            allowsMediaCarousel: allowsMediaCarousel,
                            carouselOuterHorizontalPadding: carouselOuterHorizontalPadding
                        )
                        Spacer()
                            .frame(height: 18)
                    }
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.flareSeparator)
                            .frame(minWidth: 1, maxWidth: 1, alignment: .leading)
                            .padding(.leading, 22)
                            .padding(.top, 44)
                    }
                }
            }
            HStack(
                alignment: .top,
                spacing: 8,
            ) {
                if showAsFullWidth, let user {
                    AvatarView(data: user.avatar?.url, customHeader: user.avatar?.customHeaders)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(
                            Text(
                                verbatim: openProfileAccessibilityLabel(handle: user.handle.canonical)
                            )
                        )
                        .onTapGesture {
                            user.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
                        }
                }
                VStack(
                    alignment: .leading,
                    spacing: 0,
                ) {
                    if user != nil || hasPreMediaBody {
                        VStack(
                            alignment: .leading,
                            spacing: 0,
                        ) {
                            if let user {
                                if showAsFullWidth {
                                    UserOnelineView(data: user, showAvatar: false) {
                                        topEndContent(
                                            visibility: visibility,
                                            translationDisplayState: translationDisplayState,
                                            platformIcon: data.platformIcon,
                                            platformId: data.platformId,
                                            ipLocation: ipLocation,
                                            createdAt: createdAt,
                                            accountType: accountType,
                                            statusKey: statusKey
                                        )
                                    } onClicked: {
                                        user.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
                                    }
                                } else if isQuote {
                                    UserOnelineView(data: user, showAvatar: true) {
                                        topEndContent(
                                            visibility: visibility,
                                            translationDisplayState: translationDisplayState,
                                            platformIcon: data.platformIcon,
                                            platformId: data.platformId,
                                            ipLocation: ipLocation,
                                            createdAt: createdAt,
                                            accountType: accountType,
                                            statusKey: statusKey
                                        )
                                    } onClicked: {
                                        user.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
                                    }
                                } else {
                                    UserCompatView(data: user) {
                                        topEndContent(
                                            visibility: visibility,
                                            translationDisplayState: translationDisplayState,
                                            platformIcon: data.platformIcon,
                                            platformId: data.platformId,
                                            ipLocation: ipLocation,
                                            createdAt: createdAt,
                                            accountType: accountType,
                                            statusKey: statusKey
                                        )
                                    } onClicked: {
                                        user.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
                                    }
                                    Spacer()
                                        .frame(height: 4)
                                }
                            }
                            if hasPreMediaBody {
                                VStack(
                                    alignment: .leading,
                                    spacing: 0,
                                ) {
                                    if let replyToHandle {
                                        HStack(spacing: 4) {
                                            Image(fontAwesome: .reply)
                                            Text("Reply to \(replyToHandle)", bundle: FlareAppleUILocalization.bundle)
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                    }
                                    if !contentWarningIsEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(contentWarnings.enumerated()), id: \.offset) { _, contentWarning in
                                                if !contentWarning.isEmpty {
                                                    RichText(text: contentWarning)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .if(isDetail) { view in
                                                            view.textSelection(.enabled)
                                                        }
                                                    }
                                            }

                                            if !expandContentWarning {
                                                Button {
                                                    withAnimation {
                                                        contentWarningExpanded.toggle()
                                                        if !contentWarningExpanded {
                                                            textExpanded = false
                                                            overflowingTextIndexes.removeAll()
                                                        }
                                                    }
                                                } label: {
                                                    if contentWarningExpanded {
                                                        Text("mastodon_item_show_less", bundle: FlareAppleUILocalization.bundle)
                                                    } else {
                                                        Text("mastodon_item_show_more", bundle: FlareAppleUILocalization.bundle)
                                                    }
                                                }
                                                .buttonStyle(.borderedProminent)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }

                                    if contentWarningExpanded || expandContentWarning || contentWarningIsEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(contents.enumerated()), id: \.offset) { index, content in
                                                if !content.isEmpty {
                                                    CollapsibleRichText(
                                                        text: content,
                                                        lineLimit: contentLineLimit,
                                                        collapseThreshold: collapseThreshold,
                                                        isExpanded: textExpanded,
                                                        isTextSelectionEnabled: isDetail
                                                    ) { overflows in
                                                        if overflows {
                                                            overflowingTextIndexes.insert(index)
                                                        } else {
                                                            overflowingTextIndexes.remove(index)
                                                        }
                                                    }
                                                }
                                            }
                                            if !overflowingTextIndexes.isEmpty, canExpandLineLimitedContent {
                                                Button {
                                                    withAnimation {
                                                        textExpanded = true
                                                    }
                                                } label: {
                                                    Text("mastodon_item_show_more", bundle: FlareAppleUILocalization.bundle)
                                                }
                                                .buttonStyle(.borderless)
                                            }

                                            if let poll, showMedia {
                                                Spacer()
                                                    .frame(height: 8)
                                                StatusPollView(data: poll)
                                            }
                                        }
                                    }

                                    if isDetail, showTranslate {
                                        StatusTranslateView(
                                            content: data.content.original,
                                            contentWarning: data.contentWarning?.original
                                        )
                                    }
                                }
                            }
                        }
                        .frame(
                            minHeight: usesSideAvatarCarousel ? 44 : nil,
                            alignment: .topLeading
                        )
                    }
                    VStack(
                        alignment: .leading,
                        spacing: 0,
                    ) {
                        if hasImages, showMedia, showAttachments {
                            StatusMediaContent(
                                post: data,
                                data: images,
                                sensitive: sensitive,
                                cornerRadius: isQuote ? 12 : 16,
                                allowsCarousel: allowsMediaCarousel,
                                carouselLeadingPadding: carouselLeadingPadding,
                                carouselTrailingPadding: carouselEdgePadding
                            ) { media, index in
                                if let timelineMediaOpenAction {
                                    timelineMediaOpenAction(data, media, index)
                                } else {
                                    let preview: String? = switch onEnum(of: media) {
                                    case .image(let image):
                                        image.previewUrl
                                    case .video(let video):
                                        video.thumbnailUrl
                                    case .ugoira(let animation):
                                        animation.previewUrl
                                    case .gif(let gif):
                                        gif.previewUrl
                                    case .audio:
                                        nil
                                    }
                                    let previewIsImage: Bool
                                    if case .image = onEnum(of: media) {
                                        previewIsImage = true
                                    } else {
                                        previewIsImage = false
                                    }
                                    let route = DeeplinkRoute.MediaStatusMedia(
                                        statusKey: statusKey,
                                        accountType: accountType,
                                        index: Int32(index),
                                        preview: preview,
                                        aspectRatio: Float(media.aspectRatio ?? 0),
                                        previewIsImage: previewIsImage
                                    )
                                    if let url = URL(string: route.toUri()) {
                                        openURL(url)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }

                        if let card, showMedia, !hasImages, !hasQuotes, showLinkPreview {
                            if compatLinkPreview {
                                StatusCompatCardView(data: card, cornerRadius: isQuote ? 12 : 16)
                                    .padding(.top, 8)
                            } else {
                                StatusCardView(data: card, cornerRadius: isQuote ? 12 : 16)
                                    .padding(.top, 8)
                            }
                        }

                        if hasQuotes, !isQuote {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(quoteItems.enumerated()), id: \.offset) { index, quote in
                                    StatusView(
                                        data: quote,
                                        isQuote: true,
                                        forceHideActions: true,
                                        allowsMediaCarousel: allowsMediaCarousel
                                    )
                                    if index < quoteItems.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .padding(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.flareSeparator, lineWidth: 1)
                            )
                            .padding(.top, 4)
                        }

                        if showMedia, !isQuote {
                            if sourceChannelName != nil || hasEmojiReactions {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let sourceChannelName {
                                        HStack(spacing: 4) {
                                            Image(fontAwesome: .tv)
                                            Text(sourceChannelName)
                                        }
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    }
                                    if hasEmojiReactions {
                                        StatusReactionView(data: emojiReactions, isDetail: isDetail)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }

                        if isDetail {
                            DateTimeText(data: createdAt, fullTime: true)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }

                        if (postActionStyle != .hidden || isDetail) && !forceHideActions {
                            StatusActionsView(data: actions, useText: false, topPadding: 8)
                            #if os(macOS)
                                .font(isDetail ? .body : .callout)
                            #else
                                .font(isDetail ? .body : .footnote)
                            #endif
                                .foregroundStyle(isDetail ? .primary : .secondary)
                        }
                    }
                }
                #if os(macOS)
                .contextMenu {
                    StatusActionsView(data: data.actions, useText: true, allowSpacer: false)
                }
                #endif
//                .if(!isDetail) { view in
//                    view
//                        .contextMenu {
//                            StatusActionsView(data: data.actions, useText: true, allowSpacer: false)
//                        }
//                }
            }
        }
        .contentShape(.rect)
        .if(isClickable) { view in
            view.onTapGesture {
                data.onClicked(ClickContext(launcher: AppleUriLauncher(openUrl: openURL)))
            }
        }
        .backportOnChange(of: data.renderHash) { _, _ in
            contentWarningExpanded = false
            textExpanded = false
            overflowingTextIndexes.removeAll()
        }
        .backportOnChange(of: effectiveLineLimit) { _, _ in
            textExpanded = false
            overflowingTextIndexes.removeAll()
        }
        .backportOnChange(of: translateConfig.showOriginalWithTranslation) { _, _ in
            textExpanded = false
            overflowingTextIndexes.removeAll()
        }
        .confirmationDialog(
            Text("status_manage_title", bundle: FlareAppleUILocalization.bundle),
            isPresented: $showManageMenu,
            titleVisibility: .visible
        ) {
            if supportsEditing {
                Button {
                    showEditSheet = true
                } label: {
                    Text("status_manage_edit", bundle: FlareAppleUILocalization.bundle)
                }
            }
            if isWeibo {
                Button {
                    StatusManageActions.shared.pin(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        pinned: true,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_pin", bundle: FlareAppleUILocalization.bundle)
                }
                Button {
                    StatusManageActions.shared.pin(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        pinned: false,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_unpin", bundle: FlareAppleUILocalization.bundle)
                }
                Button {
                    StatusManageActions.shared.updateVisibility(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        visibility: .`public`,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_visibility_public", bundle: FlareAppleUILocalization.bundle)
                }
                Button {
                    StatusManageActions.shared.updateVisibility(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        visibility: .mutual,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_visibility_mutual", bundle: FlareAppleUILocalization.bundle)
                }
                Button {
                    StatusManageActions.shared.updateVisibility(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        visibility: .followers,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_visibility_followers", bundle: FlareAppleUILocalization.bundle)
                }
                Button {
                    StatusManageActions.shared.updateVisibility(
                        accountType: data.accountType,
                        statusKey: data.statusKey,
                        visibility: .`private`,
                        onResult: { _ in }
                    )
                } label: {
                    Text("status_manage_visibility_private", bundle: FlareAppleUILocalization.bundle)
                }
            }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("delete", bundle: FlareAppleUILocalization.bundle)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            StatusEditSheet(
                accountType: data.accountType,
                statusKey: data.statusKey,
                onClose: { showEditSheet = false },
                onSaved: { showEditSheet = false },
                onFailed: { _ in }
            )
        }
        .alert(
            Text("status_manage_delete_confirm", bundle: FlareAppleUILocalization.bundle),
            isPresented: $showDeleteConfirm
        ) {
            Button(role: .destructive) {
                DeleteStatusPresenter(accountType: data.accountType, statusKey: data.statusKey)
                    .models.value.delete()
            } label: {
                Text("delete", bundle: FlareAppleUILocalization.bundle)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel")
            }
        }
    }

    /// 只在自己发的帖子右上角显示「更多」入口。
    private func isOwnPost(_ accountType: AccountType) -> Bool {
        guard case .specific(let specific) = onEnum(of: accountType) else { return false }
        guard let userKey = data.user?.key else { return false }
        return specific.accountKey.id == userKey.id && specific.accountKey.host == userKey.host
    }
    
    private func topEndContent(
        visibility: UiTimelineV2.PostVisibility?,
        translationDisplayState: TranslationDisplayState,
        platformIcon: UiIcon,
        platformId: String,
        ipLocation: String?,
        createdAt: UiDateTime,
        accountType: AccountType,
        statusKey: MicroBlogKey
    ) -> some View {
        HStack(spacing: 4) {
            if let visibility {
                StatusVisibilityView(data: visibility)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if translationDisplayState != .hidden {
                TranslateStatusComponent(data: translationDisplayState)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showPlatformLogo {
                // 平台图标下方放 IP 属地，只显示地名（如「北京」）。
                VStack(alignment: .trailing, spacing: 0) {
                    Image(fontAwesome: platformIcon.fontAwesomeIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            Text(
                                verbatim: String(
                                    format: FlareAppleUILocalization.string(
                                        "status_platform",
                                        fallback: "Platform: %@"
                                    ),
                                    platformId
                                )
                            )
                        )
                    if let ipLocation, !ipLocation.isEmpty {
                        Text(ipLocation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if !isDetail {
                DateTimeText(data: createdAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isOwnPost(accountType), !isQuote, !isDetail {
                Button {
                    showManageMenu = true
                } label: {
                    Image(fontAwesome: .ellipsis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("status_manage_title", bundle: FlareAppleUILocalization.bundle))
            }
            if agentEnabled, !isQuote {
                Button {
                    let route = DeeplinkRoute.StatusInsight(
                        accountType: accountType,
                        statusKey: statusKey
                    )
                    if let url = URL(string: route.toUri()) {
                        openURL(url)
                    }
                } label: {
                    Image(fontAwesome: .robot)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("status_insight_title", bundle: FlareAppleUILocalization.bundle))
            }
        }
    }
}

struct StatusMediaContent: View {
    @Environment(\.timelineAppearance.showMedia) private var showMedia
    @Environment(\.timelineAppearance.showSensitiveContent) private var showSensitiveContent
    @State private var expandMedia = false
    let post: UiTimelineV2.Post
    let data: [any UiMedia]
    let sensitive: Bool
    let cornerRadius: CGFloat
    let allowsCarousel: Bool
    let carouselLeadingPadding: CGFloat
    let carouselTrailingPadding: CGFloat
    let onMediaClicked: (any UiMedia, Int) -> Void
    var body: some View {
        if showMedia || expandMedia {
            StatusMediaView(
                post: post,
                data: data,
                sensitive: !(showSensitiveContent) && sensitive,
                cornerRadius: cornerRadius,
                allowsCarousel: allowsCarousel,
                carouselLeadingPadding: carouselLeadingPadding,
                carouselTrailingPadding: carouselTrailingPadding,
                onMediaClicked: onMediaClicked
            )
        } else {
            Button {
                withAnimation {
                    expandMedia = true
                }
            } label: {
                Label {
                    Text(
                        "appearance_show_media",
                        bundle: FlareAppleUILocalization.bundle,
                        comment: "Button to show media attachments"
                    )
                } icon: {
                    Image(fontAwesome: .image)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

//extension StatusView {
//    init(
//        data: UiTimeline.ItemContentStatus, 
//        isDetail: Bool = false, 
//        isQuote: Bool = false,
//        withLeadingPadding: Bool = false,
//        showMedia: Bool = true,
//        maxLine: Int = 5, 
//        showExpandTextButton: Bool = true, 
//        forceHideActions: Bool = false
//    ) {
//        self.data = data
//        self.isDetail = isDetail
//        self.isQuote = isQuote
//        self.withLeadingPadding = withLeadingPadding
//        self.showMedia = showMedia
//        self.maxLine = maxLine
//        self.showExpandTextButton = showExpandTextButton
//        self.forceHideActions = forceHideActions
//    }
//}

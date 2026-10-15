import Combine
import Foundation
@preconcurrency import KotlinSharedUI
import SwiftUI

// iOS 15 回退：@Perceptible 的读取点散落在 ComposeScreen 的各类惰性闭包里
// （ScrollView / overlay / toolbar / sheet），逐个包 WithPerceptionTracking 不可靠。
// 改成 Combine 的 ObservableObject 后，任何属性变化都会让持有者整体重算，
// 与 iOS 17 上 @Observable 的自动追踪等效。
public final class ComposeContentViewModel: ObservableObject {
    @Published public var text: String
    @Published public var contentWarning: String
    @Published public var enableContentWarning: Bool
    @Published public var showEmoji: Bool
    public var pollViewModel: ComposePollViewModel
    @Published public var languages: [String]
    private var cancellables = Set<AnyCancellable>()

    public init(
        text: String = "",
        contentWarning: String = "",
        enableContentWarning: Bool = false,
        showEmoji: Bool = false,
        pollViewModel: ComposePollViewModel = ComposePollViewModel(),
        languages: [String]? = nil
    ) {
        self.text = text
        self.contentWarning = contentWarning
        self.enableContentWarning = enableContentWarning
        self.showEmoji = showEmoji
        self.pollViewModel = pollViewModel
        self.languages = languages ?? Self.defaultLanguages
        // pollViewModel 自己是 ObservableObject，ComposeScreen 只持有本对象，
        // 必须把它的变化转发上来，否则「开启投票」后面板不出现。
        pollViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public static var defaultLanguages: [String] {
        // Locale.current.language.languageCode 是 iOS 16 起的 API，退回 NSLocale 取值
        [flareCurrentLanguageCode]
    }

    public var hasDraftContent: Bool {
        !text.isEmpty ||
        !contentWarning.isEmpty ||
        pollViewModel.enabled
    }

    public func toggleContentWarning() {
        enableContentWarning.toggle()
    }

    public func togglePoll() {
        pollViewModel.toggleEnabled()
    }

    public func addEmoji(emoji: UiEmoji) {
        showEmoji = false
    }

    public func makeComposeData(
        visibility: UiTimelineV2.PostVisibility,
        medias: [ComposeData.Media],
        sensitive: Bool,
        composeStatus: ComposeStatus?,
        localOnly: Bool = false
    ) -> ComposeData {
        ComposeData(
            content: text,
            visibility: visibility,
            language: languages,
            medias: medias,
            sensitive: sensitive,
            spoilerText: enableContentWarning ? contentWarning : nil,
            poll: pollViewModel.makeComposePoll(),
            localOnly: localOnly,
            referenceStatus: referenceStatus(from: composeStatus)
        )
    }

    public func applyDraft(_ draft: UiDraft) -> ComposeDraftRestoreResult {
        let data = draft.data
        text = data.content
        contentWarning = data.spoilerText ?? ""
        enableContentWarning = !(data.spoilerText ?? "").isEmpty
        if !data.language.isEmpty {
            languages = data.language
        }
        pollViewModel.apply(poll: data.poll)
        return ComposeDraftRestoreResult(
            sensitive: data.sensitive,
            visibility: data.visibility
        )
    }

    private func referenceStatus(from composeStatus: ComposeStatus?) -> ComposeData.ReferenceStatus? {
        if let composeStatus {
            ComposeData.ReferenceStatus(composeStatus: composeStatus)
        } else {
            nil
        }
    }
}

public struct ComposeDraftRestoreResult {
    public let sensitive: Bool
    public let visibility: UiTimelineV2.PostVisibility

    public init(
        sensitive: Bool,
        visibility: UiTimelineV2.PostVisibility
    ) {
        self.sensitive = sensitive
        self.visibility = visibility
    }
}

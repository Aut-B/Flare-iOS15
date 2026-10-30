import SwiftUI
import KotlinSharedUI
import FlareAppleCore

/// 编辑已发布帖子的正文（Mastodon / Misskey）。
///
/// 这两个平台的服务端都支持改正文，客户端不带这个功能等于少一半 ——
/// 打错一个字只能删了重发，转发出去的链接全废。
///
/// 只改正文：可见范围、CW、附件都交给服务端沿用原值，避免「编辑一下把媒体丢了」。
public struct StatusEditSheet: View {
    private let accountType: AccountType
    private let statusKey: MicroBlogKey
    private let onClose: () -> Void
    private let onSaved: () -> Void
    private let onFailed: (String) -> Void

    @State private var text: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var loadError: String?

    public init(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        onClose: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        self.accountType = accountType
        self.statusKey = statusKey
        self.onClose = onClose
        self.onSaved = onSaved
        self.onFailed = onFailed
    }

    private var canSave: Bool {
        !isLoading &&
            !isSaving &&
            loadError == nil &&
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("status_edit_loading", bundle: FlareAppleUILocalization.bundle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                        Text(loadError)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editor
                }
            }
            .navigationTitle(Text("status_edit_title", bundle: FlareAppleUILocalization.bundle))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose()
                    } label: {
                        Text("Cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button {
                            save()
                        } label: {
                            Text("status_edit_save", bundle: FlareAppleUILocalization.bundle)
                                .fontWeight(.semibold)
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
        .onAppear(perform: load)
        #if os(iOS)
            .navigationViewStyle(.stack)
        #endif
    }

    /// 这个包同时编 iOS 和 macOS，`UIColor` / `NSColor` 只能各自走分支。
    private var editorBackground: Color {
        #if os(iOS)
            return Color(UIColor.secondarySystemGroupedBackground)
        #else
            return Color(NSColor.textBackgroundColor)
        #endif
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 16))
                .frame(minHeight: 220)
                .padding(6)
                .background(editorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Text("status_edit_hint", bundle: FlareAppleUILocalization.bundle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(text.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func load() {
        guard isLoading else { return }
        StatusManageActions.shared.editableContent(
            accountType: accountType,
            statusKey: statusKey
        ) { content, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error, !error.isEmpty {
                    loadError = error
                } else {
                    text = content ?? ""
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        StatusManageActions.shared.edit(
            accountType: accountType,
            statusKey: statusKey,
            content: text
        ) { error in
            DispatchQueue.main.async {
                isSaving = false
                if let error, !error.isEmpty {
                    onFailed(error)
                } else {
                    onSaved()
                }
            }
        }
    }
}

// iOS 15 回退：把 iOS 16/17 专属的 SwiftUI API 用兼容写法包一层。
// 放在 FlareAppleCore 模块（FlareAppleUI 依赖它），ios/ 与 Shared/ 内的文件均可使用。
import Combine
import SwiftUI

// MARK: - onChange 回退
// 不用 SwiftUI 的 onChange：iOS 17 SDK 里它同时存在单参旧版与双参新版（initial 有默认值），
// 在部署目标 iOS 15 下重载解析容易歧义。改用 onReceive(Just(...))，iOS 13+ 通用且语义一致。
private struct BackportChangeObserver<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var oldValue: V?

    func body(content: Content) -> some View {
        content
            .onReceive(Just(value)) { newValue in
                guard let old = oldValue else {
                    oldValue = newValue
                    if initial {
                        action(newValue, newValue)
                    }
                    return
                }
                guard old != newValue else { return }
                oldValue = newValue
                action(old, newValue)
            }
    }
}

extension View {
    public func backportOnChange<V: Equatable>(
        of value: V,
        initial: Bool = false,
        perform: @escaping (V) -> Void
    ) -> some View {
        modifier(
            BackportChangeObserver(value: value, initial: initial) { _, newValue in
                perform(newValue)
            }
        )
    }

    public func backportOnChange<V: Equatable>(
        of value: V,
        initial: Bool = false,
        perform: @escaping (V, V) -> Void
    ) -> some View {
        modifier(BackportChangeObserver(value: value, initial: initial, action: perform))
    }
}

// MARK: - ContentUnavailableView 回退（iOS 17 专属）
// 与 SwiftUI 的 ContentUnavailableView 保持同一调用形态：
// label（必填）、description（可选）、actions（可选）皆为 ViewBuilder 尾随闭包。
public struct BackportContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    @ViewBuilder private let label: () -> Label
    @ViewBuilder private let description: () -> Description
    @ViewBuilder private let actions: () -> Actions

    public init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder description: @escaping () -> Description,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.label = label
        self.description = description
        self.actions = actions
    }

    public init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder description: @escaping () -> Description
    ) where Actions == EmptyView {
        self.init(label: label, description: description, actions: { EmptyView() })
    }

    public init(
        @ViewBuilder label: @escaping () -> Label,
        @ViewBuilder actions: @escaping () -> Actions
    ) where Description == EmptyView {
        self.init(label: label, description: { EmptyView() }, actions: actions)
    }

    public init(
        @ViewBuilder label: @escaping () -> Label
    ) where Description == EmptyView, Actions == EmptyView {
        self.init(label: label, description: { EmptyView() }, actions: { EmptyView() })
    }

    public var body: some View {
        VStack(spacing: 12) {
            label()
                .font(.headline)
            description()
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .multilineTextAlignment(.center)
    }
}


// HomeTimelineScreen 等处仍在用 ContentUnavailableView(_:systemImage:) 的简写形式。
public extension BackportContentUnavailableView where Label == AnyView, Description == EmptyView, Actions == EmptyView {
    init(_ titleKey: LocalizedStringKey, systemImage: String) {
        self.init {
            AnyView(
                VStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(titleKey)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
            )
        }
    }
}

// MARK: - scrollPosition 回退（iOS 17 专属，iOS 15 下直接透传不生效）
extension View {
    @ViewBuilder
    public func backportScrollPosition<ID: Hashable>(
        id: Binding<ID?>,
        anchor: UnitPoint? = nil
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.scrollPosition(id: id, anchor: anchor)
        } else {
            self
        }
    }

    @ViewBuilder
    public func backportScrollTargetLayout() -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    public func backportDefaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }
}

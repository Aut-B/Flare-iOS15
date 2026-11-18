import SwiftUI

#if os(iOS)
import UIKit

// iOS 15 没有 UITraitDefinition / UITraitBridgedEnvironmentKey / UIMutableTraits（均为 iOS 17 才引入）。
// 这里退化成普通 EnvironmentKey：环境里只存 UIColor? 背景，供主文字色在纯黑背景下微调。
private nonisolated struct FlareTextBackgroundKey: EnvironmentKey {
    static let defaultValue: UIColor? = nil
}

public extension EnvironmentValues {
    nonisolated var flareTextBackground: UIColor? {
        get { self[FlareTextBackgroundKey.self] }
        set { self[FlareTextBackgroundKey.self] = newValue }
    }
}

public extension UIColor {
    /// iOS 15 回退：直接返回系统 label 色（不再做纯黑背景下的 trait 桥接调暗）。
    nonisolated static var flareLabel: UIColor { .label }

    nonisolated fileprivate static func flareLabel(on background: UIColor) -> UIColor {
        UIColor { traits in flareLabel(on: background, traits: traits) }
    }

    nonisolated private static func flareLabel(on background: UIColor?, traits: UITraitCollection) -> UIColor {
        guard traits.userInterfaceStyle == .dark,
              traits.accessibilityContrast != .high,
              let background else { return .label.resolvedColor(with: traits) }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              red == 0, green == 0, blue == 0, alpha == 1 else {
            return .label.resolvedColor(with: traits)
        }
        return UIColor(white: 224.0 / 255, alpha: 1)
    }
}
#endif

#if os(iOS)
nonisolated enum FlareTextRole { case primary, secondary, tertiary }

private nonisolated struct FlareTextRoleKey: EnvironmentKey {
    static let defaultValue = FlareTextRole.primary
}

extension EnvironmentValues {
    nonisolated var flareTextRole: FlareTextRole {
        get { self[FlareTextRoleKey.self] }
        set { self[FlareTextRoleKey.self] = newValue }
    }
}
#endif

public nonisolated struct FlarePrimaryTextStyle: ShapeStyle {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        #if os(iOS)
        switch environment.flareTextRole {
        case .secondary: return AnyShapeStyle(Color.secondary)
        case .tertiary: return AnyShapeStyle(Color(uiColor: .tertiaryLabel))
        case .primary: break
        }
        if let background = environment.flareTextBackground,
           Color(uiColor: .flareLabel(on: background)).resolve(in: environment)
            != Color(uiColor: .label).resolve(in: environment) {
            return AnyShapeStyle(Color(uiColor: .flareLabel(on: background)))
        }
        #endif
        return AnyShapeStyle(.primary)
    }
}

public extension Text {
    func flarePrimaryText() -> Text {
        #if os(iOS)
        foregroundStyle(FlarePrimaryTextStyle())
        #else
        self
        #endif
    }
}

public extension View {
    /// Describe the effective background without changing control or symbol foregrounds.
    func flareTextBackground(_ background: Color?) -> some View {
        #if os(iOS)
        environment(\.flareTextBackground, background.map { UIColor($0) })
        #else
        self
        #endif
    }

    func flareSecondaryText() -> some View {
        #if os(iOS)
        foregroundStyle(.secondary).environment(\.flareTextRole, .secondary)
        #else
        foregroundStyle(.secondary)
        #endif
    }

    func flareTertiaryText() -> some View {
        #if os(iOS)
        foregroundStyle(.tertiary).environment(\.flareTextRole, .tertiary)
        #else
        foregroundStyle(.tertiary)
        #endif
    }
}

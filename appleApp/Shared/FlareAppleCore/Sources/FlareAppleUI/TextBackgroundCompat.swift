#if os(iOS)
import UIKit
import ObjectiveC

/// iOS 15 没有 `UITraitDefinition` / `UIView.traitOverrides`（均为 iOS 17 才引入）。
///
/// 上游用 `view.traitOverrides[FlareTextBackgroundTrait.self] = background` 把「当前背景色」
/// 告诉 UIKit，从而让 `.flareLabel` 动态色能在纯黑背景下调暗文字。iOS 15 没有 trait 机制，
/// 这里用一个关联对象记录背景色，调用点统一改走 `flareSetTextBackground(_:)`（见 App 层）。
/// 文字柔化特性在 iOS 15 上只在 SwiftUI 的 `.flareTextBackground(_:)` 环境路径保留，
/// UIKit trait 路径退化为仅记录、不改变颜色。
public enum FlareTextBackgroundTrait {}

public extension UIView {
    func flareSetTextBackground(_ color: UIColor?) {
        objc_setAssociatedObject(self, &flareTextBackgroundKey, color, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    var flareTextBackgroundColor: UIColor? {
        objc_getAssociatedObject(self, &flareTextBackgroundKey) as? UIColor
    }
}

private nonisolated(unsafe) var flareTextBackgroundKey: UInt8 = 0
#endif

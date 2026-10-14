// iOS 15 兼容层：把 iOS 16/17 才有的 SwiftUI API 用等价实现替一遍。
// 放在 FlareAppleUI 模块，app 目标（ios/）与 Shared 内所有 UI 代码都能直接用，无需额外 import。
import SwiftUI

// MARK: - iOS 17 的 .placeholder 形状样式

public extension ShapeStyle where Self == Color {
    static var flarePlaceholder: Color {
        Color.secondary.opacity(0.28)
    }
}

// MARK: - iOS 16 的 Locale.Language / Locale.LanguageCode

/// 当前系统语言的 tag，替代 iOS 16 才有的 Locale.current.language.languageCode?.identifier。
public nonisolated var flareCurrentLanguageCode: String {
    (Locale.current as NSLocale).object(forKey: NSLocale.Key.languageCode) as? String ?? "en"
}

// MARK: - iOS 16 的 AnyShape

public struct FlareAnyShape: Shape {
    private let builder: @Sendable (CGRect) -> Path

    public init<S: Shape>(_ shape: S) {
        builder = { shape.path(in: $0) }
    }

    public func path(in rect: CGRect) -> Path {
        builder(rect)
    }
}

// MARK: - iOS 16 的 UnevenRoundedRectangle / RectangleCornerRadii

public struct FlareRectangleCornerRadii {
    public let topLeading: CGFloat
    public let bottomLeading: CGFloat
    public let bottomTrailing: CGFloat
    public let topTrailing: CGFloat

    public init(
        topLeading: CGFloat = 0,
        bottomLeading: CGFloat = 0,
        bottomTrailing: CGFloat = 0,
        topTrailing: CGFloat = 0
    ) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
}

public struct FlareUnevenRoundedRectangle: Shape {
    public let cornerRadii: FlareRectangleCornerRadii
    public let style: RoundedCornerStyle

    public init(cornerRadii: FlareRectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
        self.cornerRadii = cornerRadii
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let maxR = min(rect.width, rect.height) / 2
        let tl = min(max(cornerRadii.topLeading, 0), maxR)
        let tr = min(max(cornerRadii.topTrailing, 0), maxR)
        let bl = min(max(cornerRadii.bottomLeading, 0), maxR)
        let br = min(max(cornerRadii.bottomTrailing, 0), maxR)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addRelativeArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                radius: tr,
                startAngle: .degrees(-90),
                delta: .degrees(90)
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addRelativeArc(
                center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                radius: br,
                startAngle: .degrees(0),
                delta: .degrees(90)
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addRelativeArc(
                center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                radius: bl,
                startAngle: .degrees(90),
                delta: .degrees(90)
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addRelativeArc(
                center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                radius: tl,
                startAngle: .degrees(180),
                delta: .degrees(90)
            )
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - iOS 16 的 onGeometryChange

public struct FlareGeometryBox<T>: Equatable {
    public let value: T
    public let isEqual: (T, T) -> Bool

    public static func == (lhs: FlareGeometryBox<T>, rhs: FlareGeometryBox<T>) -> Bool {
        lhs.isEqual(lhs.value, rhs.value)
    }
}

public struct FlareGeometryKey<T>: PreferenceKey {
    public typealias Value = FlareGeometryBox<T>?

    public static var defaultValue: Value { nil }

    public static func reduce(value: inout Value, nextValue: () -> Value) {
        value = nextValue() ?? value
    }
}

@MainActor
public struct FlareGeometryObserver<T>: ViewModifier {
    public let transform: (GeometryProxy) -> T
    public let isEqual: (T, T) -> Bool
    public let action: (T) -> Void

    public init(
        transform: @escaping (GeometryProxy) -> T,
        isEqual: @escaping (T, T) -> Bool,
        action: @escaping (T) -> Void
    ) {
        self.transform = transform
        self.isEqual = isEqual
        self.action = action
    }

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: FlareGeometryKey<T>.self,
                            value: FlareGeometryBox(value: transform(proxy), isEqual: isEqual)
                        )
                        .allowsHitTesting(false)
                }
            )
            .onPreferenceChange(FlareGeometryKey<T>.self) { box in
                if let box {
                    action(box.value)
                }
            }
    }
}

public extension View {
    /// `onGeometryChange(for:of:action:)` 的 iOS 13+ 等效实现：
    /// 视图尺寸或位置变化时重算 transform，仅在结果变化时回调。
    func flareOnGeometry<T: Equatable>(
        _ transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        modifier(FlareGeometryObserver(transform: transform, isEqual: { $0 == $1 }, action: action))
    }
}

// MARK: - iOS 17 的 searchable(text:isPresented:prompt:)

public extension View {
    @ViewBuilder
    func flareSearchable(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        prompt: Text
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.searchable(text: text, isPresented: isPresented, prompt: prompt)
        } else {
            self.searchable(text: text, prompt: prompt)
        }
    }

    /// 无 prompt 的形态：iOS 17 起才有 isPresented，iOS 15 退化为不可编程收起的搜索框。
    @ViewBuilder
    func flareSearchable(
        text: Binding<String>,
        isPresented: Binding<Bool>
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.searchable(text: text, isPresented: isPresented)
        } else {
            // iOS 15 的 searchable 必须带 prompt，且没有 isPresented 形态
            self.searchable(text: text, prompt: "")
        }
    }

    /// iOS 16 起才有 searchSuggestions，iOS 15 下直接丢弃（搜索框仍可用）。
    @ViewBuilder
    func flareSearchSuggestions<Suggestions: View>(
        @ViewBuilder _ suggestions: () -> Suggestions
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.searchSuggestions(suggestions)
        } else {
            self
        }
    }
}

// MARK: - iOS 16.4+ 的弹层/按钮外观修饰器

public extension View {
    @ViewBuilder
    func flarePresentationCompactAdaptationPopover() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
        }
    }

    @ViewBuilder
    func flareButtonBorderShapeCircle() -> some View {
        if #available(iOS 17.0, *) {
            self.buttonBorderShape(.circle)
        } else {
            self
        }
    }

    // MediaViewer 的 sheet 外观：presentationBackground / presentationContentInteraction /
    // presentationBackgroundInteraction / presentationCompactAdaptation 都从 iOS 16.4 才提供。
    @ViewBuilder
    func flarePresentationBackgroundMaterial(regular: Bool) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(regular ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
        } else {
            self
        }
    }

    @ViewBuilder
    func flarePresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @ViewBuilder
    func flarePresentationCompactAdaptationNone() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.none)
        } else {
            self
        }
    }

    @ViewBuilder
    func flarePresentationContentInteractionResizes() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationContentInteraction(.resizes)
        } else {
            self
        }
    }

    @ViewBuilder
    func flarePresentationBackgroundInteractionEnabled() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled)
        } else {
            self
        }
    }
}

// MARK: - SwiftUI-Flow 的 HFlow（1.7.0 内部用了 Layout 协议，实际最低 iOS 16）

/// iOS 15 可用的横向流式排布：用自适应列宽的 LazyVGrid 近似 HFlow。
public struct FlareHFlow<Content: View>: View {
    private let spacing: CGFloat
    private let minimumItemWidth: CGFloat
    private let content: () -> Content

    public init(
        spacing: CGFloat = 8,
        minimumItemWidth: CGFloat = 96,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing
        self.minimumItemWidth = minimumItemWidth
        self.content = content
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumItemWidth), alignment: .leading)],
            spacing: spacing
        ) {
            content()
        }
    }
}

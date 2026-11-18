import SwiftUI

// MARK: - iOS 15 回退：SwiftUI 的 Layout 协议自 iOS 16 起才可用
//
// Flare 里有 4 个自定义 Layout（AdaptiveGrid / TimelineCarouselFrameLayout /
// ReactionFlowLayout / StatusActionStretchLayout），它们都遵循 iOS 16 的 Layout 协议，
// 在部署目标 iOS 15 下无法编译。
//
// 处理方式：把 Layout 结构体本身标注 @available(iOS 16.0, *)，
// 再提供下面的包装 View —— iOS 16+ 走原生实现，iOS 15 退化为等价的简单容器。
// 这样既保留高版本上的精确布局，又能在 iOS 15 上编译并正常显示。

public struct AdaptiveGridCompat<Content: View>: View {
    public let singleFollowsImageAspect: Bool
    public let singleViewAspectRatio: CGFloat?
    public let singleMediaMaxHeight: CGFloat?
    public let spacing: CGFloat
    public let maxColumns: Int
    private let content: () -> Content

    public init(
        singleFollowsImageAspect: Bool = true,
        singleViewAspectRatio: CGFloat? = nil,
        singleMediaMaxHeight: CGFloat? = nil,
        spacing: CGFloat = 4,
        maxColumns: Int = 3,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.singleFollowsImageAspect = singleFollowsImageAspect
        self.singleViewAspectRatio = singleViewAspectRatio
        self.singleMediaMaxHeight = singleMediaMaxHeight
        self.spacing = spacing
        self.maxColumns = max(1, maxColumns)
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            AdaptiveGrid(
                singleFollowsImageAspect: singleFollowsImageAspect,
                singleViewAspectRatio: singleViewAspectRatio,
                singleMediaMaxHeight: singleMediaMaxHeight,
                spacing: spacing,
                maxColumns: maxColumns
            ) {
                content()
            }
        } else {
            // iOS 15 回退：等宽栅格，保留列数与间距，不做按图片比例的精确排布。
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: spacing),
                    count: min(maxColumns, 3)
                ),
                spacing: spacing
            ) {
                content()
            }
        }
    }
}

public struct TimelineCarouselFrameLayoutCompat<Content: View>: View {
    public let widthMultiplier: CGFloat
    public let spacingMultiplier: CGFloat
    public let horizontalInsets: CGFloat
    public let itemSpacing: CGFloat
    private let content: () -> Content

    public init(
        widthMultiplier: CGFloat,
        spacingMultiplier: CGFloat,
        horizontalInsets: CGFloat,
        itemSpacing: CGFloat,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.widthMultiplier = widthMultiplier
        self.spacingMultiplier = spacingMultiplier
        self.horizontalInsets = horizontalInsets
        self.itemSpacing = itemSpacing
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            TimelineCarouselFrameLayout(
                widthMultiplier: widthMultiplier,
                spacingMultiplier: spacingMultiplier,
                horizontalInsets: horizontalInsets,
                itemSpacing: itemSpacing
            ) {
                content()
            }
        } else {
            // iOS 15 回退：不做高度约束，交给内容自身尺寸。
            content()
        }
    }
}

public struct ReactionFlowLayoutCompat<Content: View>: View {
    public let maxLines: Int?
    private let content: () -> Content

    public init(
        maxLines: Int? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maxLines = maxLines
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            ReactionFlowLayout(maxLines: maxLines) {
                content()
            }
        } else {
            // iOS 15 回退：自适应宽度栅格代替流式换行，行数限制不再生效。
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 56), spacing: 8)],
                spacing: 8
            ) {
                content()
            }
        }
    }
}

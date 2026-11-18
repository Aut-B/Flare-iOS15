import Foundation
import SwiftUI

/// iOS 15 构建下没有 Textual（该库最低要求 iOS 17，无法编进 iOS 15 目标）。
/// 这里用系统自带的 `AttributedString(markdown:)`（iOS 15 起可用）做基础 Markdown 渲染，
/// 保证 FlareAppleUI 能编译、agent 相关文字能正常显示。
///
/// 相对 Textual 的富文本样式（自定义标题/表格样式、图片附件加载、动画）在 iOS 15 上
/// 退化为系统默认，属于已知的功能降级；等目标升到 iOS 17 再换回 Textual。
struct AgentMarkdownText: View {
    let markdown: String

    var body: some View {
        Group {
            if let parsed = try? AttributedString(markdown: markdown) {
                Text(parsed).textSelection(.enabled)
            } else {
                Text(markdown).textSelection(.enabled)
            }
        }
    }
}

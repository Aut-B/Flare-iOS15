import SwiftUI

public extension View {
    /// `formStyle(.grouped)` 是 iOS 16 起才有的 API；iOS 15 上退回默认表单样式。
    @ViewBuilder
    func groupedFormCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }
}

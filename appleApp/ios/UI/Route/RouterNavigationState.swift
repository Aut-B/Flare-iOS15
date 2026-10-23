// iOS 15 回退：Observation 框架（@Observable）是 iOS 17+ 专属，
// 改用 swift-perception 的 @Perceptible，对 SwiftUI 的追踪刷新等效。
import Perception

@MainActor
@Perceptible
final class RouterNavigationState<Route> {
    var backStack: [Route] = []
    var sheet: Route?
    var cover: Route?

    func goBack() {
        if !backStack.isEmpty {
            backStack.removeLast()
        }
    }

    func dismissSheet() {
        sheet = nil
    }

    func dismissCover() {
        cover = nil
    }
}

// iOS 15 回退：Observation 框架（@Observable）是 iOS 17+ 专属。
// 上游这里是「泛型 + @Observable」类；iOS 15 目标下改用 swift-perception 的
// @Perceptible 后，Swift 6.3 编译器在 -O 下优化该类的 deinit 时自身崩溃
// （EarlyPerfInliner / isCallerAndCalleeLayoutConstraintsCompatible 递归栈溢出，
// 见 build36：While running pass EarlyPerfInliner on @$s5Flare21RouterNavigationStateCfD）。
// 另外 @State 持有 @Perceptible 对象必须靠 WithPerceptionTracking 才会被追踪，
// 而 Router 的 sheet/cover 都是惰性求值闭包，追踪作用域难以完整覆盖。
// 故改为非泛型的 Combine ObservableObject，由 SwiftUI 的 @StateObject 订阅刷新：
// 既绕开编译器崩溃，也保证 iOS 15 下导航状态变更能被稳定观察到。
import Combine

@MainActor
final class RouterNavigationState: ObservableObject {
    @Published var backStack: [Route] = []
    @Published var sheet: Route?
    @Published var cover: Route?

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

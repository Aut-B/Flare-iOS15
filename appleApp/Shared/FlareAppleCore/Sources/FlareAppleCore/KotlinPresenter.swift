// iOS 15 回退：@Observable / Observation 框架是 iOS 17+ 专属，改用 Combine 的 ObservableObject。
//
// 为什么不用 Perception 的 WithPerceptionTracking：
// swift-perception 的追踪作用域只覆盖它自己那次闭包求值，包在根视图上追不到嵌套视图的 body
// （SwiftUI 对各层 body 是惰性求值的）。结果是 Kotlin presenter 推来新 state 时没有任何视图
// 被标记为脏，界面停在初始内容上，只有视图被重建（切换 Tab、重新 push）时才读到最新值。
// 这正是「首页白屏、切个 Tab 再回来就有内容」「账号列表空白」「设置项点了没反应」的根因。
//
// 换成 ObservableObject 后，SwiftUI 通过 @StateObject / @ObservedObject 建立依赖，
// objectWillChange 一发就让持有者整体重算，与 iOS 17 上 @Observable 的自动追踪等效。
@preconcurrency import Combine
import Foundation
@preconcurrency import KotlinSharedUI

public final class KotlinPresenter<T: AnyObject>: ObservableObject {
    private var makePresenter: (() -> PresenterBase<T>)?
    private var storage: Storage?
    private var subscription: AnyCancellable?

    public let key = UUID().uuidString

    // Parameterized @State initializers can run on every view rebuild. Defer the
    // Kotlin factory until the retained wrapper is actually used.
    public init(presenter: @autoclosure @escaping () -> PresenterBase<T>) {
        self.makePresenter = presenter
    }

    public var presenter: PresenterBase<T> {
        initializedStorage().presenter
    }

    public var state: T {
        get {
            initializedStorage().state
        }
        set {
            initializedStorage().state = newValue
        }
    }

    // Keep Combine's initial-value replay and will-set delivery for UIKit consumers.
    public var statePublisher: AnyPublisher<T, Never> {
        initializedStorage().$state.eraseToAnyPublisher()
    }

    private func initializedStorage() -> Storage {
        if let storage { return storage }
        guard let makePresenter else {
            preconditionFailure("Missing Kotlin presenter factory")
        }
        let storage = Storage(presenter: makePresenter())
        self.storage = storage
        self.makePresenter = nil
        subscription = storage.presenter.models.toPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                // 同一实例不重复通知，避免无谓地重算整棵视图树。
                guard self.storage?.state !== newState else { return }
                self.objectWillChange.send()
                self.storage?.state = newState
            }
        return storage
    }

    deinit {
        subscription?.cancel()
    }

    private final class Storage {
        let presenter: PresenterBase<T>
        @Published var state: T

        init(presenter: PresenterBase<T>) {
            self.presenter = presenter
            self.state = presenter.models.value
        }

        deinit {
            presenter.close()
        }
    }
}

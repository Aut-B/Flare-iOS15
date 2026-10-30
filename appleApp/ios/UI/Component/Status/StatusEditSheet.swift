import SwiftUI
import UIKit
import KotlinSharedUI
import FlareAppleCore
import FlareAppleUI
import Drops

/// 从 UIKit 时间线弹出「编辑帖子」。
///
/// 编辑界面本体在 `FlareAppleUI.StatusEditSheet`（SwiftUI 版时间线也用它），
/// 这里只负责用 `UIHostingController` 包一层、给出 sheet 尺寸，以及成败提示。
enum StatusEditPresenter {
    /// 需要 weak 持有 controller：闭包被 rootView 持有，rootView 又被 controller 持有，
    /// 直接捕获就是循环引用。
    private final class WeakBox {
        weak var value: UIViewController?
    }

    static func present(
        from host: UIViewController,
        accountType: AccountType,
        statusKey: MicroBlogKey
    ) {
        let box = WeakBox()
        let root = StatusEditSheet(
            accountType: accountType,
            statusKey: statusKey,
            onClose: { [box] in box.value?.dismiss(animated: true) },
            onSaved: { [box] in
                box.value?.dismiss(animated: true)
                Drops.show(
                    .init(
                        title: String(localized: "status_edit_done"),
                        icon: UIImage(fontAwesome: .circleCheck)
                    )
                )
            },
            onFailed: { message in
                Drops.show(
                    .init(
                        title: String(localized: "status_manage_failed"),
                        subtitle: message,
                        subtitleNumberOfLines: 3,
                        icon: UIImage(fontAwesome: .circleExclamation),
                        duration: .seconds(5)
                    )
                )
            }
        )
        let controller = UIHostingController(rootView: root)
        box.value = controller
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
    }
}

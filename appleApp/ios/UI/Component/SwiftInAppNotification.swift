import FlareAppleCore
import KotlinSharedUI
import Drops
import Foundation
import SwiftUI

struct LoginExpiredToast: Identifiable {
    let id = UUID()
    let accountKey: MicroBlogKey
    let platformId: String
}

final class SwiftInAppNotification: InAppNotification {
    private init() {}
    static let shared = SwiftInAppNotification()
    var onRelogin: ((LoginExpiredToast) -> Void)?
    
    func onError(message: Message, throwable: KotlinThrowable) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch message {
            case .compose:
                // 把微博/服务端返回的真实原因带出来（比如「重复转发」「操作频繁」），
                // 否则用户只看到「发送失败」，无法判断是客户端还是账号被限流。
                let detail = throwable.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                Drops.show(
                    .init(
                        title: .init(localized: "notification_compose_error"),
                        subtitle: (detail?.isEmpty == false) ? detail : nil,
                        subtitleNumberOfLines: 3,
                        icon: UIImage(fontAwesome: .circleExclamation),
                        duration: .seconds(5)
                    )
                )
            case .loginExpired:
                if let expiredError = throwable as? LoginExpiredException {
                    let toast = LoginExpiredToast(
                        accountKey: expiredError.accountKey,
                        platformId: expiredError.platformId
                    )
                    Drops.show(
                        .init(
                            title: String(localized: "login_expired", defaultValue: "Login session expired"),
                            subtitle: "\(expiredError.accountKey)",
                            subtitleNumberOfLines: 1,
                            icon: UIImage(fontAwesome: .circleExclamation),
                            action: .init(icon: UIImage(fontAwesome: .arrowsRotate)) { [weak self] in
                                Drops.hideCurrent()
                                self?.onRelogin?(toast)
                            },
                            duration: .seconds(5)
                        )
                    )
                } else {
                    Drops.show(.init(stringLiteral: .init(localized: "notification_login_expired")))
                }
            }
        }
    }

    func onProgress(message: Message, progress: Int32, total: Int32) {
        
    }

    func onSuccess(message: Message) {
        DispatchQueue.main.async {
            switch message {
            case .compose:
                Drops.show(
                    .init(
                        title: .init(localized: "notification_compose_success"),
                        icon: UIImage(fontAwesome: .circleCheck)
                    )
                )
            case .loginExpired:
                // do nothing
                break
            }
        }
    }
}

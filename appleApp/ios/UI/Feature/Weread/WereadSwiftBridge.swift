import Foundation
import KotlinSharedUI

/// 把「设置 → 账号 → 添加」里登录到的微信读书 cookie 交给 `WereadStore`。
///
/// 微信读书的书架是原生页面，Kotlin 侧只负责让它能在实例列表里被搜到、
/// 能走完登录流程。登录成功后 cookie 落到 `WereadStore` 存的同一个 key 上，
/// 书架页立刻就能用 —— 和走 `WereadLoginView` 扫码的效果完全一致。
final class WereadSwiftBridge: NSObject, WeReadBridge {
    func adopt(cookie: String) -> Bool {
        // Kotlin 侧可能在 suspend 的后台线程调用本方法，而 WereadStore 是
        // ObservableObject（写 @Published 属 @MainActor 隔离）。直接在后台线程
        // 调用会触发 Swift 并发的 data race 告警并可能偶发卡顿/崩溃。这里兜一层
        // 主线程；已经在前台时直接走，避免 main.sync 自锁。
        if Thread.isMainThread {
            return WereadStore.shared.adopt(cookieHeader: cookie)
        }
        var accepted = false
        DispatchQueue.main.sync {
            accepted = WereadStore.shared.adopt(cookieHeader: cookie)
        }
        return accepted
    }
}

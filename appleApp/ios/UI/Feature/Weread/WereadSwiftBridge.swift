import Foundation
import KotlinSharedUI

/// 把「设置 → 账号 → 添加」里登录到的微信读书 cookie 交给 `WereadStore`。
///
/// 微信读书的书架是原生页面，Kotlin 侧只负责让它能在实例列表里被搜到、
/// 能走完登录流程。登录成功后 cookie 落到 `WereadStore` 存的同一个 key 上，
/// 书架页立刻就能用 —— 和走 `WereadLoginView` 扫码的效果完全一致。
final class WereadSwiftBridge: NSObject, WeReadBridge {
    func adopt(cookie: String) -> Bool {
        WereadStore.shared.adopt(cookieHeader: cookie)
    }
}

import Foundation
import KotlinSharedUI

/// 把 Kotlin 登录拿到的 Instagram cookie 同步到原生 `InstagramStore`。
///
/// 两边各有一套登录态：Kotlin 账号库负责「添加账号 / 时间线」，原生页负责
/// 侧边栏里的 Instagram 入口。登录成功时同步一次，用户不用再登一遍。
final class InstagramSwiftBridge: NSObject, InstagramBridge {
    func adopt(cookie: String) -> Bool {
        // Kotlin 是从协程里调过来的，可能不在主线程；Store 是主线程对象，
        // 直接跨线程改 @Published 会炸。统一切回主线程再落。
        if Thread.isMainThread {
            return InstagramStore.shared.adopt(cookieHeader: cookie)
        }
        var accepted = false
        DispatchQueue.main.sync {
            accepted = InstagramStore.shared.adopt(cookieHeader: cookie)
        }
        return accepted
    }
}

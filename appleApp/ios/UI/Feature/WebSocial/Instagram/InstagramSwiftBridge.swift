import Foundation
import KotlinSharedUI

/// 把 Kotlin 登录拿到的 Instagram cookie 同步到原生 `InstagramStore`。
///
/// 两边各有一套登录态：Kotlin 账号库负责「添加账号 / 时间线」，原生页负责
/// 侧边栏里的 Instagram 入口。登录成功时同步一次，用户不用再登一遍。
final class InstagramSwiftBridge: NSObject, InstagramBridge {
    func adopt(cookie: String) -> Bool {
        InstagramStore.shared.adopt(cookieHeader: cookie)
    }
}

import Foundation
import KotlinSharedUI

/// 把 Kotlin 登录拿到的 Instagram cookie 同步到原生 `InstagramStore`。
///
/// 两边各有一套登录态：Kotlin 账号库负责「添加账号 / 时间线」，原生页负责
/// 侧边栏里的 Instagram 入口。登录成功时同步一次，用户不用再登一遍。
final class InstagramSwiftBridge: NSObject, InstagramBridge {
    func adopt(cookie: String) -> Bool {
        // 先做纯字符串校验，完全不碰 Store：Kotlin 可能从任意线程 / 协程
        // 上下文调进来，而 Store 是主线程对象。
        let normalized =
            cookie
                .replacingOccurrences(of: "\r\n", with: "; ")
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let header = InstagramService.sanitizeHeader(normalized)
        guard CookieJar.value(inHeader: header, named: "sessionid") != nil else {
            return false
        }

        // 这里以前是 `DispatchQueue.main.sync`。Kotlin 的协程如果正好跑在
        // 主线程上下文里，sync 就是「自己等自己」——主线程永久阻塞，
        // 系统看门狗直接杀进程。用户看到的就是「登录成功那一刻闪退，
        // 之后每次启动都崩」（启动时 Kotlin 又会同步一次 cookie）。
        // 改成异步派发：返回值用纯字符串校验结果，真正的落库在主线程做。
        if Thread.isMainThread {
            return InstagramStore.shared.adopt(cookieHeader: cookie)
        }
        DispatchQueue.main.async {
            _ = InstagramStore.shared.adopt(cookieHeader: cookie)
        }
        return true
    }
}

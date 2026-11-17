package dev.dimension.flare.data.network.weread

import dev.dimension.flare.common.PlatformDispatchers
import dev.dimension.flare.data.repository.AccountService
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiAccount
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * 原生登录页（Swift `WereadLoginView`）拿到的 cookie 也要写进账号库。
 *
 * 只在书架页登录时，`WereadStore` 有 cookie，但 Kotlin 的「我的账户」和首页
 * 标签栏并不知道这个账号。这里补上，和「添加账号」走同一条持久化路径。
 */
public object WeReadAccountBridge {
    private val accountService: AccountService by koinInject()

    /**
     * 写库是挂起操作，Swift 那边没有协程，所以放到 IO 上跑。
     *
     * 和 `TimelineDbPageLoader` 同样的写法：`UNDISPATCHED` 先同步执行到第一个
     * 挂起点，账号在校验通过后立刻可见，真正的落库在 IO 线程接上。
     */
    private val scope: CoroutineScope by lazy { CoroutineScope(SupervisorJob() + PlatformDispatchers.IO) }

    /** 返回 cookie 是否有效（必须同时包含 wr_vid 与 wr_skey）。 */
    public fun register(cookie: String): Boolean {
        val normalized = WeReadCredential.normalize(cookie)
        if (!normalized.contains("${WeReadCredential.PRIMARY_KEY}=")) return false
        if (!normalized.contains("wr_skey=")) return false
        persist(normalized)
        return true
    }

    private fun persist(normalized: String) {
        val credential = WeReadCredential.fromCookie(normalized)
        val account =
            UiAccount(
                accountKey = MicroBlogKey(credential.userId, WEREAD_HOST),
                platformId = WEREAD_PLATFORM_ID,
            )
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            accountService.addAccount(
                account = account,
                credential = credential,
                serializer = WeReadCredential.serializer(),
            )
        }
    }
}

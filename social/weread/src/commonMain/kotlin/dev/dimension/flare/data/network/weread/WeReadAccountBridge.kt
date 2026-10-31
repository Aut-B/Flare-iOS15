package dev.dimension.flare.data.network.weread

import dev.dimension.flare.data.repository.AccountService
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiAccount

/**
 * 原生登录页（Swift `WereadLoginView`）拿到的 cookie 也要写进账号库。
 *
 * 只在书架页登录时，`WereadStore` 有 cookie，但 Kotlin 的「我的账户」和首页
 * 标签栏并不知道这个账号。这里补上，和「添加账号」走同一条持久化路径。
 */
public object WeReadAccountBridge {
    private val accountService: AccountService by koinInject()

    /** 返回 cookie 是否有效（必须同时包含 wr_vid 与 wr_skey）。 */
    public fun register(cookie: String): Boolean {
        val normalized = WeReadCredential.normalize(cookie)
        if (!normalized.contains("${WeReadCredential.PRIMARY_KEY}=")) return false
        if (!normalized.contains("wr_skey=")) return false
        val credential = WeReadCredential.fromCookie(normalized)
        val accountKey = MicroBlogKey(credential.userId, WEREAD_HOST)
        accountService.addAccount(
            account =
                UiAccount(
                    accountKey = accountKey,
                    platformId = WEREAD_PLATFORM_ID,
                ),
            credential = credential,
            serializer = WeReadCredential.serializer(),
        )
        return true
    }
}

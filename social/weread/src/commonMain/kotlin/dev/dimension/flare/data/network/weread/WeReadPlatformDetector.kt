package dev.dimension.flare.data.network.weread

import dev.dimension.flare.ui.presenter.login.NodeDetection
import dev.dimension.flare.ui.presenter.login.PlatformDetector

/**
 * 让「添加账号」的实例输入框认得 `weread.qq.com`。
 *
 * 优先级比 Mastodon 高：`qq.com` 下的探测容易先被别的规则吃掉。
 */
internal data object WeReadPlatformDetector : PlatformDetector {
    override val priority: Int = 87

    override suspend fun detect(host: String): NodeDetection? {
        val normalized =
            host
                .trim()
                .removePrefix("https://")
                .removePrefix("http://")
                .substringBefore("/")
                .lowercase()
        if (normalized != WEREAD_HOST && normalized != "www.$WEREAD_HOST") {
            return null
        }
        return NodeDetection(
            host = WEREAD_HOST,
            software = "WeRead",
            compatibleMode = false,
        )
    }
}

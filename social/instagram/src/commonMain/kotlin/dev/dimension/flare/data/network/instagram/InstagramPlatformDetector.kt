package dev.dimension.flare.data.network.instagram

import dev.dimension.flare.ui.presenter.login.NodeDetection
import dev.dimension.flare.ui.presenter.login.PlatformDetector

/**
 * 让「添加账号」的实例输入框认得 `instagram.com` / `www.instagram.com`。
 *
 * 优先级设得比 Mastodon 高一点：Mastodon 的探测是靠 `/api/v1/instance` 判断的，
 * 而 Instagram 也有一堆 `/api/v1/...` 路径，别让它先猜错。
 */
internal data object InstagramPlatformDetector : PlatformDetector {
    override val priority: Int = 85

    override suspend fun detect(host: String): NodeDetection? {
        val normalized =
            host
                .trim()
                .removePrefix("https://")
                .removePrefix("http://")
                .substringBefore("/")
                .lowercase()
        if (normalized != INSTAGRAM_HOST && normalized != "www.$INSTAGRAM_HOST") {
            return null
        }
        return NodeDetection(
            host = INSTAGRAM_HOST,
            software = "Instagram",
            compatibleMode = false,
        )
    }
}

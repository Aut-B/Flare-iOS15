package dev.dimension.flare.data.network.xiaohongshu

import dev.dimension.flare.ui.presenter.login.NodeDetection
import dev.dimension.flare.ui.presenter.login.PlatformDetector

internal data object XhsPlatformDetector : PlatformDetector {
    override val priority: Int = 86

    override suspend fun detect(host: String): NodeDetection? {
        val normalized =
            host
                .trim()
                .removePrefix("https://")
                .removePrefix("http://")
                .substringBefore("/")
                .lowercase()
        if (normalized != XHS_HOST && normalized != "www.$XHS_HOST") {
            return null
        }
        return NodeDetection(
            host = XHS_HOST,
            software = "Xiaohongshu",
            compatibleMode = false,
        )
    }
}

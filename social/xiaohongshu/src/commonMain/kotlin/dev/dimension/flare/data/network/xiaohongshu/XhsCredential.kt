package dev.dimension.flare.data.network.xiaohongshu

import kotlinx.serialization.Serializable

/**
 * 小红书的网页登录凭证。
 *
 * 关键 cookie：
 * - `web_session`：登录态本身，没有它就是未登录
 * - `a1` / `webId`：设备指纹，签名和 `X-S-Common` 都要用
 *
 * 账号 id 取 `webId`（没有就退 `a1`）：这两个在同一个浏览器里是稳定的，
 * 重新登录不会变成一个新账号。
 */
@Serializable
public data class XhsCredential(
    public val cookie: String,
    public val userId: String,
    public val userName: String = "",
) {
    public companion object {
        public fun fromCookie(raw: String): XhsCredential {
            val map =
                raw.split(";")
                    .mapNotNull { part ->
                        val index = part.indexOf('=')
                        if (index <= 0) return@mapNotNull null
                        part.substring(0, index).trim() to part.substring(index + 1).trim()
                    }.toMap()
            val id =
                map["webId"]?.takeIf { it.isNotBlank() }
                    ?: map["a1"]?.takeIf { it.isNotBlank() }
                    ?: "web"
            return XhsCredential(
                cookie = raw,
                userId = id,
            )
        }
    }
}

public const val XHS_PLATFORM_ID: String = "Xiaohongshu"

/** `MicroBlogKey` 里的 host，只写域名不带 scheme。 */
public const val XHS_HOST: String = "xiaohongshu.com"

public const val XHS_LOGIN_URL: String = "https://www.xiaohongshu.com/explore"

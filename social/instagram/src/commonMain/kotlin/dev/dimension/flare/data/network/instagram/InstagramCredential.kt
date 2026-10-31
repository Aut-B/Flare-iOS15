package dev.dimension.flare.data.network.instagram

import kotlinx.serialization.Serializable

/**
 * Instagram 网页端的登录凭证。
 *
 * 用户在网页版登录后，`sessionid` / `csrftoken` / `ds_user_id` 就够用了 ——
 * 接口鉴权全靠这几个 cookie 加上 `X-IG-App-ID`，不需要额外签名。
 */
@Serializable
public data class InstagramCredential(
    public val cookie: String,
    public val csrfToken: String,
    public val userId: String,
    public val userName: String = "",
) {
    public companion object {
        /** 从浏览器 cookie 串里挑出需要的几项，顺便补齐 header 要用的值。 */
        public fun fromCookie(raw: String): InstagramCredential {
            val map =
                raw.split(";")
                    .mapNotNull { part ->
                        val index = part.indexOf('=')
                        if (index <= 0) return@mapNotNull null
                        part.substring(0, index).trim() to part.substring(index + 1).trim()
                    }.toMap()
            return InstagramCredential(
                cookie = raw,
                csrfToken = map["csrftoken"].orEmpty(),
                userId = map["ds_user_id"].orEmpty(),
            )
        }
    }
}

public object InstagramConstants {
    public const val HOST: String = "https://www.instagram.com"

    /** 网页端公开的 app id，所有 web 接口都要带。 */
    public const val APP_ID: String = "936619743392459"
    public const val ASBD_ID: String = "129477"
    public const val USER_AGENT: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

/**
 * 平台 id 用大写开头，和 Fanbox / Pixiv 一致 —— 它同时出现在 `MicroBlogKey.host`
 * 里，会和别的平台拼成缓存 key。
 */
public const val INSTAGRAM_PLATFORM_ID: String = "Instagram"

/** `MicroBlogKey` 里的 host。只写域名，不带 scheme。 */
public const val INSTAGRAM_HOST: String = "instagram.com"


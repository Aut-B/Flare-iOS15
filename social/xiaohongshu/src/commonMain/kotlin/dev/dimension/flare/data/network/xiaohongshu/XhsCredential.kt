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
            val map = parseCookiePairs(raw)
            val id =
                map["webId"]?.takeIf { it.isNotBlank() }
                    ?: map["a1"]?.takeIf { it.isNotBlank() }
                    ?: "web"
            return XhsCredential(
                // 重新拼一遍：粘贴进来的串经常带换行，塞进 HTTP header 就是非法值。
                cookie = map.entries.joinToString("; ") { "${it.key}=${it.value}" },
                userId = id,
            )
        }

        /** 兼容 `Cookie:` 前缀、一行一条的粘贴方式、首尾引号。 */
        internal fun parseCookiePairs(raw: String): Map<String, String> {
            var text = raw.trim().trim('"').trim()
            if (text.startsWith("Cookie:", ignoreCase = true)) {
                text = text.substring("Cookie:".length)
            }
            text =
                text
                    .replace("\r\n", "; ")
                    .replace("\n", "; ")
                    .replace("\r", "; ")
                    .replace("\t", " ")
            return text
                .split(";")
                .mapNotNull { part ->
                    val index = part.indexOf('=')
                    if (index <= 0) return@mapNotNull null
                    val name = part.substring(0, index).trim()
                    val value = part.substring(index + 1).trim().trim('"')
                    if (name.isEmpty()) null else name to value
                }.toMap()
        }
    }
}

public const val XHS_PLATFORM_ID: String = "Xiaohongshu"

/** `MicroBlogKey` 里的 host，只写域名不带 scheme。 */
public const val XHS_HOST: String = "xiaohongshu.com"

public const val XHS_LOGIN_URL: String = "https://www.xiaohongshu.com/explore"

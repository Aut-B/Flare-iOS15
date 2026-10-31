package dev.dimension.flare.data.network.weread

import kotlinx.serialization.Serializable

/**
 * 微信读书的登录态。
 *
 * 网页版只需要两个 cookie：
 * - `wr_vid`：账号 id，稳定不变
 * - `wr_skey`：会话本身，掉了要重新扫码
 */
@Serializable
public data class WeReadCredential(
    public val cookie: String,
    public val userId: String,
    public val userName: String = "",
) {
    public companion object {
        /** 判断有没有登录态的那一项。只贴了值没贴名字时按它补。 */
        public const val PRIMARY_KEY: String = "wr_vid"

        public fun fromCookie(raw: String): WeReadCredential {
            val map = parseCookiePairs(normalize(raw))
            return WeReadCredential(
                // 重新拼一遍：粘贴进来的串经常带换行，塞进 HTTP header 就是非法值。
                cookie = map.entries.joinToString("; ") { "${it.key}=${it.value}" },
                userId = map["wr_vid"].orEmpty().ifBlank { "weread" },
            )
        }

        /**
         * 把各种粘贴姿势归一成 `k=v; k=v`。
         *
         * 只贴了 `wr_vid` 后面那串值（没带名字）时按 `wr_vid=` 补上。
         */
        public fun normalize(raw: String): String {
            val text = clean(raw)
            if (text.isEmpty()) return ""
            if (!text.contains('=')) return "$PRIMARY_KEY=$text"
            return text
        }

        /** 兼容 `Cookie:` 前缀、一行一条的粘贴方式、首尾引号。 */
        internal fun parseCookiePairs(raw: String): Map<String, String> =
            clean(raw)
                .split(";")
                .mapNotNull { part ->
                    val index = part.indexOf('=')
                    if (index <= 0) return@mapNotNull null
                    val name = part.substring(0, index).trim()
                    val value = part.substring(index + 1).trim().trim('"')
                    if (name.isEmpty()) null else name to value
                }.toMap()

        private fun clean(raw: String): String {
            var text = raw.trim().trim('"').trim()
            if (text.startsWith("Cookie:", ignoreCase = true)) {
                text = text.substring("Cookie:".length)
            }
            return text
                .replace("\r\n", "; ")
                .replace("\n", "; ")
                .replace("\r", "; ")
                .replace("\t", " ")
                .trim()
                .trim(';', ' ')
        }
    }
}

/** 平台 id。它同时出现在 `MicroBlogKey.host` 里，会和别的平台拼成缓存 key。 */
public const val WEREAD_PLATFORM_ID: String = "WeRead"

/** `MicroBlogKey` 里的 host。只写域名，不带 scheme。 */
public const val WEREAD_HOST: String = "weread.qq.com"

public const val WEREAD_LOGIN_URL: String = "https://weread.qq.com/"

/**
 * 把登录态交给宿主。
 *
 * 微信读书的书架是原生页面（Swift 侧 `WereadStore`），Kotlin 这边只负责
 * 「在添加账号里能被搜到、能登录」，登录成功后把 cookie 交过去就行。
 */
public interface WeReadBridge {
    /** 返回是否被接受（cookie 里没有 `wr_vid` 会被拒）。 */
    public fun adopt(cookie: String): Boolean
}

public object WeReadBridgeHolder {
    public var bridge: WeReadBridge? = null
}

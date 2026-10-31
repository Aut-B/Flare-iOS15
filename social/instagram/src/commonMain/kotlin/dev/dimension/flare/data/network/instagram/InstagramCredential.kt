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
        /** 判断有没有登录态的那一项。只贴了值没贴名字时按它补。 */
        public const val PRIMARY_KEY: String = "sessionid"

        /** 从浏览器 cookie 串里挑出需要的几项，顺便补齐 header 要用的值。 */
        public fun fromCookie(raw: String): InstagramCredential {
            val map = parseCookiePairs(normalize(raw))
            return InstagramCredential(
                // 重新拼一遍而不是直接用原文：粘贴进来的串里经常带换行 / 制表符，
                // 塞进 HTTP header 就是非法值，Instagram 会直接回 400。
                cookie = map.entries.joinToString("; ") { "${it.key}=${it.value}" },
                csrfToken = map["csrftoken"].orEmpty(),
                userId = map["ds_user_id"].orEmpty(),
            )
        }

        /**
         * 把各种粘贴姿势都归一成 `k=v; k=v`。
         *
         * 只贴了 `sessionid` 后面那串值（没带名字）时按 `sessionid=` 补上；
         * 但 Instagram 还需要 `ds_user_id` 才能建账号，所以纯值通常还是不够 ——
         * 调用方会给出对应的提示。
         */
        public fun normalize(raw: String): String {
            val text = clean(raw)
            if (text.isEmpty()) return ""
            if (!text.contains('=')) return "$PRIMARY_KEY=$text"
            return text
        }

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

        /**
         * 归一化：去 `Cookie:` 前缀、去首尾引号、把换行 / 制表符压成 `; `。
         *
         * 换行是必须去掉的：cookie 里带 `\r\n` 会让 HTTP header 非法，服务端直接 400。
         */
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

public object InstagramConstants {
    public const val HOST: String = "https://www.instagram.com"

    /** 网页端公开的 app id，所有 web 接口都要带。 */
    public const val APP_ID: String = "936619743392459"
    public const val ASBD_ID: String = "129477"

    /**
     * 必须用桌面 Chrome 的 UA。
     *
     * `X-IG-App-ID` 就是桌面网页版那一份，UA 自称 iPhone 时部分接口（尤其是
     * `/api/v1/accounts/...` 这一族）会判定为「客户端和 app id 不匹配」，
     * 回一个没有 body 的 400 —— 这正是之前网页登录后卡在 400 的原因。
     */
    public const val USER_AGENT: String =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}

/**
 * 平台 id 用大写开头，和 Fanbox / Pixiv 一致 —— 它同时出现在 `MicroBlogKey.host`
 * 里，会和别的平台拼成缓存 key。
 */
public const val INSTAGRAM_PLATFORM_ID: String = "Instagram"

/** `MicroBlogKey` 里的 host。只写域名，不带 scheme。 */
public const val INSTAGRAM_HOST: String = "instagram.com"


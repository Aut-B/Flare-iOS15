package dev.dimension.flare.data.network.instagram

import dev.dimension.flare.data.network.ktorClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** 一页结果：`nextMaxId` 为空表示到底了。 */
internal data class InstagramPage(
    val items: List<JsonObject>,
    val nextMaxId: String?,
)

/**
 * Instagram 网页接口。
 *
 * 只用 `www.instagram.com/api/v1/...` 这套：鉴权靠 cookie + `X-IG-App-ID`，
 * 不需要 GraphQL 那种天天变的 `doc_id`。响应体直接按 `JsonObject` 读，
 * 不写几十个 data class —— 这些接口的字段经常增删，写死反而更容易崩。
 */
internal class InstagramService {
    private val json =
        Json {
            ignoreUnknownKeys = true
            isLenient = true
        }

    // 用项目统一的工厂：它会把当前平台的 engine 装好，
    // 直接 `HttpClient()` 在 Kotlin/Native 上不一定能发现 engine。
    private val client =
        ktorClient {
            expectSuccess = false
            install(HttpTimeout) {
                requestTimeoutMillis = 20_000
                connectTimeoutMillis = 15_000
            }
        }

    suspend fun homeTimeline(
        credential: InstagramCredential,
        maxId: String?,
    ): InstagramPage {
        val params =
            buildList {
                add("is_prefetch" to "false")
                add("reason" to "pull_to_refresh")
                add("phone_id" to phoneId())
                add("battery_level" to "100")
                add("timezone_offset" to "28800")
                maxId?.takeIf { it.isNotBlank() }?.let { add("max_id" to it) }
            }
        // 网页端这个接口收的是 **表单体**，不是 JSON。之前发 application/json
        // 会被直接打回 400（而且 body 是空的，看错误信息也看不出原因）。
        val formBody = params.joinToString("&") { (k, v) -> "$k=$v" }

        val posted =
            runCatching {
                request(
                    client.post("${InstagramConstants.HOST}/api/v1/feed/timeline/") {
                        applyHeaders(credential)
                        contentType(ContentType.Application.FormUrlEncoded)
                        setBody(formBody)
                    },
                )
            }
        posted.getOrNull()?.let { return parsePage(it, key = "feed_items") }

        // 登录失效不用再试，那是真的没登录。
        posted.exceptionOrNull()?.let { if (it is InstagramException && it.needLogin) throw it }

        // 还有一批账号只认 GET 的 query 参数，POST 被拒就换一种姿势。
        val text =
            request(
                client.get("${InstagramConstants.HOST}/api/v1/feed/timeline/?$formBody") {
                    applyHeaders(credential)
                },
            )
        return parsePage(text, key = "feed_items")
    }

    suspend fun userTimeline(
        credential: InstagramCredential,
        userId: String,
        maxId: String?,
    ): InstagramPage {
        val url =
            buildString {
                append("${InstagramConstants.HOST}/api/v1/feed/user/$userId/?count=12")
                if (!maxId.isNullOrBlank()) append("&max_id=$maxId")
            }
        val text = request(client.get(url) { applyHeaders(credential) })
        return parsePage(text, key = "items")
    }

    suspend fun mediaInfo(
        credential: InstagramCredential,
        mediaId: String,
    ): JsonObject? {
        val text =
            request(
                client.get("${InstagramConstants.HOST}/api/v1/media/$mediaId/info/") {
                    applyHeaders(credential)
                },
            )
        val root = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return null
        return root["items"]?.jsonArray?.firstOrNull()?.jsonObject
    }

    /**
     * 用 cookie 认一次身份。
     *
     * 这几个入口在不同账号 / 不同灰度里能用的不一样（`current_user` 有时直接 400），
     * 所以挨个试。全部失败返回 null —— 调用方还会用 cookie 里的 `ds_user_id` 兜底，
     * 不该因为一个「探测身份」的接口把登录卡死。
     */
    suspend fun currentUser(credential: InstagramCredential): JsonObject? {
        val candidates =
            buildList {
                add("${InstagramConstants.HOST}/api/v1/accounts/current_user/?edit=false")
                add("${InstagramConstants.HOST}/api/v1/accounts/edit/web_form_data/")
                credential.userId.takeIf { it.isNotBlank() }?.let {
                    add("${InstagramConstants.HOST}/api/v1/users/$it/info/")
                }
            }
        for (url in candidates) {
            val text =
                runCatching {
                    request(client.get(url) { applyHeaders(credential) })
                }.getOrNull() ?: continue
            extractUser(text)?.let { return it }
        }
        return null
    }

    /** 按用户名取主页。网页版的 `web_profile_info` 是最稳的一个入口。 */
    suspend fun userInfo(
        credential: InstagramCredential,
        userName: String,
    ): JsonObject? {
        val text =
            request(
                client.get("${InstagramConstants.HOST}/api/v1/users/web_profile_info/?username=$userName") {
                    applyHeaders(credential)
                },
            )
        return runCatching {
            json.parseToJsonElement(text).jsonObject["data"]?.jsonObject?.get("user")?.jsonObject
        }.getOrNull()
    }

    suspend fun userInfoById(
        credential: InstagramCredential,
        userId: String,
    ): JsonObject? {
        val text =
            request(
                client.get("${InstagramConstants.HOST}/api/v1/users/$userId/info/") {
                    applyHeaders(credential)
                },
            )
        return runCatching { json.parseToJsonElement(text).jsonObject["user"]?.jsonObject }.getOrNull()
    }

    // MARK: - 工具

    private fun HttpRequestBuilder.applyHeaders(credential: InstagramCredential) {
        header("Cookie", credential.cookie)
        header("X-IG-App-ID", InstagramConstants.APP_ID)
        header("X-ASBD-ID", InstagramConstants.ASBD_ID)
        // 空的 X-CSRFToken 会让部分接口直接 400，没拿到就别发。
        credential.csrfToken.takeIf { it.isNotBlank() }?.let { header("X-CSRFToken", it) }
        header("X-IG-WWW-Claim", "0")
        header("X-Requested-With", "XMLHttpRequest")
        header("User-Agent", InstagramConstants.USER_AGENT)
        header("Accept", "*/*")
        header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
        header("Origin", InstagramConstants.HOST)
        header("Referer", "${InstagramConstants.HOST}/")
    }

    private suspend fun request(response: HttpResponse): String {
        val text = response.bodyAsText()
        val status = response.status.value
        // 未登录时 Instagram 会跳到登录页，跟随跳转后拿到的是一整页 HTML。
        // 当成接口结果去解析会静默变成空列表，这里显式识别成「掉登录」。
        val looksLikeHtml = text.trimStart().startsWith("<")
        if (status !in 200..299) {
            if (status == 401 || status == 403 || looksLikeHtml) {
                throw InstagramException("Instagram 登录已失效，请重新登录", needLogin = true)
            }
            val detail = errorMessage(text)
            throw InstagramException(
                if (detail != null) {
                    "Instagram 请求被拒绝（HTTP $status：$detail）"
                } else {
                    "Instagram 请求失败（HTTP $status）"
                },
            )
        }
        if (looksLikeHtml) {
            throw InstagramException("Instagram 登录已失效，请重新登录", needLogin = true)
        }
        // 未登录时接口也会返回 200 + {"message":"login_required",...}
        if (text.contains("\"login_required\"") || text.contains("\"checkpoint_required\"")) {
            throw InstagramException("Instagram 登录已失效，请重新登录", needLogin = true)
        }
        return text
    }

    /** 从错误响应里捞 `message`，拿不到就算了。 */
    private fun errorMessage(text: String): String? =
        runCatching {
            json.parseToJsonElement(text).jsonObject["message"]?.jsonPrimitive?.content
        }.getOrNull()?.takeIf { it.isNotBlank() && it != "null" }

    private fun extractUser(text: String): JsonObject? {
        val root = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return null
        // {"user": {...}}
        (root["user"] as? JsonObject)?.let { return it }
        // {"data": {"user": {...}}}
        ((root["data"] as? JsonObject)?.get("user") as? JsonObject)?.let { return it }
        // {"form_data": {"username": "...", "pk": ...}} —— edit/web_form_data 的形状
        (root["form_data"] as? JsonObject)?.let { form ->
            if (form.containsKey("username") || form.containsKey("pk") || form.containsKey("user_id")) {
                return form
            }
        }
        // 直接就是一个用户对象
        if (root.containsKey("username") || root.containsKey("pk")) return root
        return null
    }

    private fun parsePage(
        text: String,
        key: String,
    ): InstagramPage {
        val root =
            runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
                ?: return InstagramPage(emptyList(), null)
        val raw = root[key]?.jsonArray ?: return InstagramPage(emptyList(), null)
        val items =
            raw.mapNotNull { element ->
                val entry = element.jsonObject
                // 时间线里混着推荐用户之类的条目，只要帖子。
                entry["media_or_ad"]?.jsonObject ?: entry.takeIf { it.containsKey("id") }
            }
        val next = root["next_max_id"]?.jsonPrimitive?.contentOrNullSafe()
        return InstagramPage(items, next?.takeIf { it.isNotBlank() })
    }

    private fun JsonPrimitive.contentOrNullSafe(): String? =
        runCatching { content }.getOrNull()?.takeIf { it.isNotBlank() && it != "null" }

    private fun phoneId(): String = "android-${(1000..9999).random()}"
}

internal class InstagramException(
    override val message: String,
    /** true 表示 cookie 已经不能用了，重试没意义。 */
    val needLogin: Boolean = false,
) : Exception(message)

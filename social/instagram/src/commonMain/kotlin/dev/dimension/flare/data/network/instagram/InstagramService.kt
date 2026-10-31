package dev.dimension.flare.data.network.instagram

import dev.dimension.flare.data.network.ktorClient
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
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
    private val json = Json {
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
        val body =
            buildString {
                append("{\"is_prefetch\":false,\"reason\":\"pull_to_refresh\",")
                append("\"feed_view_info\":\"\",\"phone_id\":\"${phoneId()}\",")
                append("\"battery_level\":100,\"timezone_offset\":28800,")
                append("\"is_pull_to_refresh\":false")
                if (!maxId.isNullOrBlank()) {
                    append(",\"max_id\":\"$maxId\"")
                }
                append("}")
            }
        val text =
            request(
                client.post("${InstagramConstants.HOST}/api/v1/feed/timeline/") {
                    applyHeaders(credential)
                    contentType(ContentType.Application.Json)
                    setBody(body)
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

    suspend fun currentUser(credential: InstagramCredential): JsonObject? {
        val text =
            request(
                client.get("${InstagramConstants.HOST}/api/v1/accounts/current_user/?edit=false") {
                    applyHeaders(credential)
                },
            )
        return runCatching { json.parseToJsonElement(text).jsonObject["user"]?.jsonObject }.getOrNull()
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

    private fun io.ktor.client.request.HttpRequestBuilder.applyHeaders(credential: InstagramCredential) {
        header("Cookie", credential.cookie)
        header("X-IG-App-ID", InstagramConstants.APP_ID)
        header("X-ASBD-ID", InstagramConstants.ASBD_ID)
        header("X-CSRFToken", credential.csrfToken)
        header("X-IG-WWW-Claim", "0")
        header("X-Requested-With", "XMLHttpRequest")
        header("User-Agent", InstagramConstants.USER_AGENT)
        header("Referer", "${InstagramConstants.HOST}/")
    }

    private suspend fun request(response: HttpResponse): String {
        val text = response.bodyAsText()
        if (response.status.value !in 200..299) {
            throw InstagramException(
                if (response.status.value == 401 || response.status.value == 403) {
                    "Instagram 登录已失效，请重新登录"
                } else {
                    "Instagram 请求失败（HTTP ${response.status.value}）"
                },
            )
        }
        // 未登录时接口会返回 {"message":"login_required",...}
        if (text.contains("\"login_required\"")) {
            throw InstagramException("Instagram 登录已失效，请重新登录")
        }
        return text
    }

    private fun parsePage(
        text: String,
        key: String,
    ): InstagramPage {
        val root = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
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

    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
        runCatching { content }.getOrNull()?.takeIf { it.isNotBlank() && it != "null" }

    private fun phoneId(): String = "android-${(1000..9999).random()}"
}

internal class InstagramException(
    override val message: String,
) : Exception(message)

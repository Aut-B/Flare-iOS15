package dev.dimension.flare.data.datasource.xiaohongshu

import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** 一页结果，`next` 为空表示到底了。 */
internal data class XhsPage(
    val items: List<JsonObject>,
    val next: String?,
)

/**
 * 小红书数据服务。
 *
 * 所有网络请求都由 [XhsBridge] 的宿主实现完成（iOS 侧是带隐藏 WKWebView 的
 * Swift 实现），这里只负责把返回的 JSON 拆成结构化数据。
 *
 * 宿主实现没法把异常穿过 Kotlin 边界（suspend 函数没标 `@Throws`），
 * 所以错误也走 JSON：`{"error":"..."}`，这里再翻回异常。
 */
internal class XhsService {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    suspend fun homeFeed(
        credential: XhsCredential,
        cursor: String?,
        follow: Boolean,
    ): XhsPage = parsePage(requireBridge().homeFeed(credential.cookie, cursor, follow))

    suspend fun userNotes(
        credential: XhsCredential,
        userId: String,
        cursor: String?,
    ): XhsPage = parsePage(requireBridge().userNotes(credential.cookie, userId, cursor))

    suspend fun note(
        credential: XhsCredential,
        id: String,
    ): JsonObject {
        val root =
            parseObject(requireBridge().note(credential.cookie, id))
                ?: throw IllegalStateException("小红书返回格式异常")
        root.xhsString("error")?.let { throw IllegalStateException(it) }
        return root.xhsObjects("items").firstOrNull()
            ?: throw IllegalStateException("笔记已删除或不可见")
    }

    private fun requireBridge(): XhsBridge =
        XhsBridgeHolder.bridge
            ?: throw IllegalStateException("小红书需要网页端签名，当前平台还不支持")

    private fun parsePage(text: String): XhsPage {
        val root = parseObject(text) ?: return XhsPage(emptyList(), null)
        root.xhsString("error")?.let { throw IllegalStateException(it) }
        val next = root.xhsString("next")
        return XhsPage(root.xhsObjects("items"), next?.takeIf { it.isNotBlank() })
    }

    private fun parseObject(text: String): JsonObject? =
        runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull()
}

package dev.dimension.flare.data.datasource.xiaohongshu

import dev.dimension.flare.data.network.xiaohongshu.XHS_HOST
import dev.dimension.flare.data.network.xiaohongshu.XHS_PLATFORM_ID
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.ClickEvent
import dev.dimension.flare.ui.model.UiHandle
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.model.UiMedia
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.model.UiTranslatableText
import dev.dimension.flare.ui.render.toUi
import dev.dimension.flare.ui.render.toUiPlainText
import dev.dimension.flare.ui.route.DeeplinkRoute
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlin.time.Clock

/**
 * 宿主吐出来的 JSON 是固定契约（见 `XhsJsonContract`），所以这里可以放心按字段读。
 */

internal fun JsonObject.xhsString(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() && it != "null" }

internal fun JsonObject.xhsObject(key: String): JsonObject? = this[key] as? JsonObject

internal fun JsonObject.xhsStrings(key: String): List<String> =
    (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

internal fun JsonObject.xhsObjects(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

internal fun JsonObject.xhsFloat(key: String, fallback: Float): Float =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toFloatOrNull()?.takeIf { it.isFinite() } ?: fallback

internal fun JsonObject.xhsBool(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

/**
 * 小红书笔记 → 时间线帖子。
 *
 * 小红书没有「发布时间」这个稳定字段（接口给的是相对时间，比如「3 天前」），
 * 所以 `createdAt` 用当前时间兜底 —— 时间线按接口顺序排，不受影响。
 */
internal fun JsonObject.toUiPost(accountKey: MicroBlogKey): UiTimelineV2.Post? {
    val id = xhsString("id") ?: return null
    val images = xhsStrings("images").filter { it.isNotBlank() }
    if (images.isEmpty()) return null

    val aspect = xhsFloat("aspect", 0.75f)
    val user = xhsObject("user")?.toUiProfile(accountKey)
    val statusKey = MicroBlogKey(id, XHS_HOST)
    val title = xhsString("title").orEmpty()
    val desc = xhsString("desc").orEmpty()
    // 标题和正文拼在一起：小红书正文里经常带话题标签，标题反而是短的。
    val content = listOf(title, desc).filter { it.isNotBlank() }.joinToString("\n\n")

    return UiTimelineV2.Post(
        platformId = XHS_PLATFORM_ID,
        images =
            images
                .map {
                    UiMedia.Image(
                        url = it,
                        previewUrl = it,
                        description = null,
                        width = aspect,
                        height = 1f,
                        sensitive = false,
                    )
                }.toPersistentList(),
        sensitive = false,
        contentWarning = null,
        user = user,
        content = UiTranslatableText(original = content.toUiPlainText()),
        actions = persistentListOf(),
        poll = null,
        statusKey = statusKey,
        card = null,
        createdAt = Clock.System.now().toUi(),
        clickEvent =
            ClickEvent.Deeplink(
                DeeplinkRoute.Status.Detail(
                    statusKey = statusKey,
                    accountType = AccountType.Specific(accountKey),
                ),
            ),
        accountType = AccountType.Specific(accountKey),
    )
}

/**
 * 没有头像 / 昵称时用的占位资料。
 *
 * 小红书「按 id 取用户」的接口要 `X-S` 签名，而宿主那边（`XhsBridge`）只实现了
 * 笔记相关的几个请求。账号页只需要有个能渲染的资料，先给这个 —— 至少不会整页报错。
 */
internal fun placeholderProfile(
    id: String,
    name: String,
    accountKey: MicroBlogKey,
): UiProfile {
    val userKey = MicroBlogKey(id, XHS_HOST)
    val display = name.ifBlank { "小红书" }
    return UiProfile(
        key = userKey,
        handle = UiHandle(raw = display, host = XHS_HOST),
        avatar = null,
        nameInternal = display.toUiPlainText(),
        platformId = XHS_PLATFORM_ID,
        platformIcon = UiIcon.World,
        clickEvent =
            ClickEvent.Deeplink(
                DeeplinkRoute.Profile.User(
                    accountType = AccountType.Specific(accountKey),
                    userKey = userKey,
                ),
            ),
        banner = null,
        description = null,
        matrices =
            UiProfile.Matrices(
                fansCount = 0,
                followsCount = 0,
                statusesCount = 0,
            ),
        mark = persistentListOf(),
        bottomContent = null,
    )
}

internal fun JsonObject.toUiProfile(accountKey: MicroBlogKey): UiProfile? {
    val id = xhsString("id") ?: return null
    val name = xhsString("name") ?: return null
    val userKey = MicroBlogKey(id, XHS_HOST)
    val avatar = xhsString("avatar")
    return UiProfile(
        key = userKey,
        handle = UiHandle(raw = name, host = XHS_HOST),
        avatar =
            avatar?.let {
                UiMedia.Image(
                    url = it,
                    previewUrl = it,
                    description = null,
                    width = 0f,
                    height = 0f,
                    sensitive = false,
                )
            },
        nameInternal = name.toUiPlainText(),
        platformId = XHS_PLATFORM_ID,
        platformIcon = UiIcon.World,
        clickEvent =
            ClickEvent.Deeplink(
                DeeplinkRoute.Profile.User(
                    accountType = AccountType.Specific(accountKey),
                    userKey = userKey,
                ),
            ),
        banner = null,
        description = null,
        matrices =
            UiProfile.Matrices(
                fansCount = 0,
                followsCount = 0,
                statusesCount = 0,
            ),
        mark = persistentListOf(),
        bottomContent = null,
    )
}

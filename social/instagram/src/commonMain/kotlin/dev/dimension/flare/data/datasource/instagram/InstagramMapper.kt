package dev.dimension.flare.data.datasource.instagram

import dev.dimension.flare.data.network.instagram.INSTAGRAM_HOST
import dev.dimension.flare.data.network.instagram.INSTAGRAM_PLATFORM_ID
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
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.time.Instant

/**
 * Instagram 的 JSON 结构太活，字段经常增删（同一个 `pk` 有时是数字有时是字符串），
 * 所以这里不写 data class，统一按 `JsonObject` 读，缺字段就退默认值。
 */

internal fun JsonObject.igObject(key: String): JsonObject? =
    (this[key] as? JsonObject) ?: (this[key] as? JsonArray)?.firstOrNull()?.jsonObject

internal fun JsonObject.igArray(key: String): List<JsonObject> =
    (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

internal fun JsonObject.igString(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() && it != "null" }

internal fun JsonObject.igLong(key: String): Long =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull() ?: 0L

internal fun JsonObject.igInt(key: String): Int =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull() ?: 0

/** 帖子的唯一 id。时间线里有时只有 `pk`，有时只有 `id`。 */
internal fun JsonObject.igMediaId(): String? =
    igString("id") ?: igString("pk") ?: (this["pk"] as? JsonPrimitive)?.contentOrNull

/** `image_versions2.candidates` 里挑最宽的一张。 */
internal fun JsonObject.igBestImage(): Pair<String, Pair<Float, Float>>? {
    val candidates = igObject("image_versions2")?.igArray("candidates").orEmpty()
    val widest = candidates.maxByOrNull { it.igInt("width") }
    if (widest != null) {
        val url = widest.igString("url") ?: return null
        return url to (widest.igInt("width").toFloat() to widest.igInt("height").toFloat())
    }
    val fallback = igString("display_url") ?: igString("thumbnail_url") ?: return null
    return fallback to (0f to 0f)
}

internal fun JsonObject.igVideoUrl(): String? =
    igArray("video_versions").firstOrNull()?.igString("url")

/**
 * 把一条媒体（帖子）转成时间线里的 `Post`。
 *
 * 轮播（`carousel_media`）会被摊平成多张图，和微博的多图一致 —— 用户要的就是
 * 「点进截图能看到每一张」。
 */
internal fun JsonObject.toUiPost(accountKey: MicroBlogKey): UiTimelineV2.Post? {
    val id = igMediaId() ?: return null
    // 广告位和「推荐关注」没有 user，直接丢掉。
    val rawUser = igObject("user") ?: return null
    val user = rawUser.toUiProfile(accountKey) ?: return null

    val mediaType = igInt("media_type")
    val carousel = igArray("carousel_media")
    val sources = if (carousel.isNotEmpty()) carousel else listOf(this)

    val images = mutableListOf<UiMedia>()
    var videoUrl: String? = null
    for (source in sources) {
        val image = source.igBestImage()
        if (image != null) {
            images +=
                UiMedia.Image(
                    url = image.first,
                    previewUrl = image.first,
                    description = null,
                    width = image.second.first,
                    height = image.second.second,
                    sensitive = false,
                )
        }
        if (videoUrl == null) {
            videoUrl = source.igVideoUrl()
        }
    }

    // 视频帖：把封面当图，视频地址单独放，点开能播。
    if (videoUrl != null && mediaType == 2) {
        val cover = igBestImage()
        if (cover != null) {
            images.clear()
            images +=
                UiMedia.Video(
                    url = videoUrl,
                    thumbnailUrl = cover.first,
                    description = null,
                    width = cover.second.first,
                    height = cover.second.second,
                )
        }
    }

    if (images.isEmpty()) return null

    val caption = igObject("caption")?.igString("text").orEmpty()
    val statusKey = MicroBlogKey(id, INSTAGRAM_HOST)
    return UiTimelineV2.Post(
        platformId = INSTAGRAM_PLATFORM_ID,
        images = images.toPersistentList(),
        sensitive = false,
        contentWarning = null,
        user = user,
        content = UiTranslatableText(original = caption.toUiPlainText()),
        actions = persistentListOf(),
        poll = null,
        statusKey = statusKey,
        card = null,
        createdAt = Instant.fromEpochSeconds(igLong("taken_at")).toUi(),
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

internal fun JsonObject.toUiProfile(accountKey: MicroBlogKey): UiProfile? {
    // 时间线里是 `pk`，主页接口里是 `id`。
    val id = igMediaId() ?: return null
    val userName = igString("username") ?: igString("user_name") ?: return null
    val userKey = MicroBlogKey(id, INSTAGRAM_HOST)
    val avatar = igString("profile_pic_url") ?: igString("profile_pic_url_hd")
    return UiProfile(
        key = userKey,
        handle = UiHandle(raw = userName, host = INSTAGRAM_HOST),
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
        nameInternal = (igString("full_name") ?: userName).toUiPlainText(),
        platformId = INSTAGRAM_PLATFORM_ID,
        platformIcon = UiIcon.World,
        clickEvent =
            ClickEvent.Deeplink(
                DeeplinkRoute.Profile.User(
                    accountType = AccountType.Specific(accountKey),
                    userKey = userKey,
                ),
            ),
        banner = null,
        description = igString("biography")?.toUiPlainText(),
        matrices =
            UiProfile.Matrices(
                fansCount = igLong("follower_count"),
                followsCount = igLong("following_count"),
                statusesCount = igLong("media_count"),
            ),
        mark = persistentListOf(),
        bottomContent = null,
    )
}

/** 把 `JsonElement` 数组里的条目取成 `JsonObject`，过滤掉非对象项。 */
internal fun JsonElement?.asJsonObjectOrNull(): JsonObject? = this as? JsonObject

/**
 * 接口拿不到资料时的占位资料。
 *
 * 账号页只是要一个能渲染的 `UiProfile`。探测接口失败（400 / 掉登录 / 超时）
 * 不该让整行变成错误 —— 之前就是这里一抛异常，账号页那条 Instagram 显示「错误」。
 */
internal fun instagramPlaceholderProfile(
    id: String,
    userName: String,
    accountKey: MicroBlogKey,
): UiProfile {
    val userKey = MicroBlogKey(id, INSTAGRAM_HOST)
    val display = userName.ifBlank { id.ifBlank { "Instagram" } }
    return UiProfile(
        key = userKey,
        handle = UiHandle(raw = display, host = INSTAGRAM_HOST),
        avatar = null,
        nameInternal = display.toUiPlainText(),
        platformId = INSTAGRAM_PLATFORM_ID,
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

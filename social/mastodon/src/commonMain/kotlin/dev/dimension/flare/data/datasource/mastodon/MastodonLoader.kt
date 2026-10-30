package dev.dimension.flare.data.datasource.mastodon

import dev.dimension.flare.data.datasource.microblog.loader.EmojiLoader
import dev.dimension.flare.data.datasource.microblog.loader.NotificationLoader
import dev.dimension.flare.data.datasource.microblog.loader.PostLoader
import dev.dimension.flare.data.datasource.microblog.loader.RelationActionType
import dev.dimension.flare.data.datasource.microblog.loader.RelationLoader
import dev.dimension.flare.data.datasource.microblog.loader.UserLoader
import dev.dimension.flare.data.network.mastodon.MastodonService
import dev.dimension.flare.data.network.mastodon.api.model.PostStatus
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiEmoji
import dev.dimension.flare.ui.model.UiHandle
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiRelation
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.model.mapper.render
import dev.dimension.flare.ui.model.mapper.toUi
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.ImmutableMap
import kotlinx.collections.immutable.toImmutableList
import kotlinx.collections.immutable.toImmutableMap

internal class MastodonLoader(
    val accountKey: MicroBlogKey,
    private val service: MastodonService,
) : NotificationLoader,
    UserLoader,
    PostLoader,
    RelationLoader,
    EmojiLoader {
    override val supportedTypes: Set<RelationActionType> =
        setOf(
            RelationActionType.Follow,
            RelationActionType.Block,
            RelationActionType.Mute,
        )

    override suspend fun userByHandleAndHost(uiHandle: UiHandle): UiProfile =
        service
            .lookupUserByAcct("${uiHandle.normalizedRaw}@${uiHandle.normalizedHost}")
            ?.render(
                accountKey = accountKey,
                host = accountKey.host,
            ) ?: throw Exception("User not found")

    override suspend fun userById(id: String): UiProfile =
        service
            .lookupUser(id)
            .render(
                accountKey = accountKey,
                host = accountKey.host,
            )

    override suspend fun relation(userKey: MicroBlogKey): UiRelation = service.showFriendships(listOf(userKey.id)).first().toUi()

    override suspend fun unfollow(userKey: MicroBlogKey) {
        service.unfollow(userKey.id)
    }

    override suspend fun follow(userKey: MicroBlogKey) {
        service.follow(userKey.id)
    }

    override suspend fun block(userKey: MicroBlogKey) {
        service.block(userKey.id)
    }

    override suspend fun unblock(userKey: MicroBlogKey) {
        service.unblock(userKey.id)
    }

    override suspend fun mute(userKey: MicroBlogKey) {
        service.muteUser(userKey.id)
    }

    override suspend fun unmute(userKey: MicroBlogKey) {
        service.unmuteUser(userKey.id)
    }

    override suspend fun status(statusKey: MicroBlogKey): UiTimelineV2 =
        service
            .lookupStatus(
                statusKey.id,
            ).render(
                accountKey = accountKey,
                host = accountKey.host,
            )

    override suspend fun deleteStatus(statusKey: MicroBlogKey) {
        service.delete(statusKey.id)
    }

    override suspend fun editableContent(statusKey: MicroBlogKey): String =
        service
            .lookupStatus(statusKey.id)
            .content
            .orEmpty()
            .htmlToEditableText()

    override suspend fun editStatus(
        statusKey: MicroBlogKey,
        content: String,
    ) {
        // 只带正文：可见范围、媒体、CW 都由服务端沿用原值。
        service.edit(
            statusKey.id,
            PostStatus(status = content),
        )
    }

    override suspend fun notificationBadgeCount(): Int {
        val marker =
            service.notificationMarkers().notifications?.lastReadID ?: return 0
        val timeline = service.notification(min_id = marker)
        return timeline.size
    }

    override suspend fun emojis(): ImmutableMap<String, ImmutableList<UiEmoji>> =
        service
            .emojis()
            .filter { it.visibleInPicker == true }
            .groupBy { it.category }
            .mapNotNull {
                val category = it.key.orEmpty()
                category to it.value
            }.map { (category, value) ->
                category to
                    value
                        .map {
                            val shortCode =
                                it.shortcode
                                    .orEmpty()
                                    .let { if (!it.startsWith(':') && !it.endsWith(':')) ":$it:" else it }
                            UiEmoji(
                                shortcode = shortCode,
                                url = it.url.orEmpty(),
                                category = it.category.orEmpty(),
                                searchKeywords =
                                    listOfNotNull(
                                        it.shortcode,
                                    ).toImmutableList(),
                                insertText = " $shortCode ",
                            )
                        }.toImmutableList()
            }.toMap()
            .toImmutableMap()
}

// MARK: - HTML 正文 → 可编辑纯文本

private val htmlBreakRegex = Regex("""<br\s*/?>""", RegexOption.IGNORE_CASE)
private val htmlParagraphEndRegex = Regex("""</p\s*>""", RegexOption.IGNORE_CASE)
private val htmlTagRegex = Regex("""<[^>]+>""")
private val htmlBlankLineRegex = Regex("""\n{3,}""")

/**
 * 把 Mastodon 返回的 HTML 正文还原成编辑框里的纯文本。
 *
 * 编辑框里必须放用户当初敲的那份文本：直接塞 HTML 的话，用户看到满屏
 * `<p>`、`<br />`，改完再提交这些标签会被当成正文再转义一次。
 */
internal fun String.htmlToEditableText(): String =
    htmlBreakRegex
        .replace(this, "\n")
        .let { htmlParagraphEndRegex.replace(it, "\n\n") }
        .let { htmlTagRegex.replace(it, "") }
        .unescapeHtmlEntities()
        .replace("\r\n", "\n")
        .replace(htmlBlankLineRegex, "\n\n")
        .trim()

/** `&amp;` 必须最后换，否则 `&amp;lt;` 会被当成 `&lt;` 再解一次。 */
private fun String.unescapeHtmlEntities(): String =
    replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")

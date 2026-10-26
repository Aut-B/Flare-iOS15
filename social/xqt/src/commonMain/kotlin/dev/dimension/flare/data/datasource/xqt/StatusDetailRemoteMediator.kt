package dev.dimension.flare.data.datasource.xqt

import androidx.paging.ExperimentalPagingApi
import dev.dimension.flare.common.encodeJson
import dev.dimension.flare.data.database.cache.mapper.XQTTimeline
import dev.dimension.flare.data.database.cache.mapper.cursor
import dev.dimension.flare.data.database.cache.mapper.isBottomEnd
import dev.dimension.flare.data.database.cache.mapper.tweets
import dev.dimension.flare.data.datasource.microblog.paging.ContextPageUpdate
import dev.dimension.flare.data.datasource.microblog.paging.ContextUpdate
import dev.dimension.flare.data.datasource.microblog.paging.PagingRequest
import dev.dimension.flare.data.datasource.microblog.paging.PagingResult
import dev.dimension.flare.data.datasource.microblog.paging.PostContextLoader
import dev.dimension.flare.data.datasource.microblog.paging.toContextUpdate
import dev.dimension.flare.data.network.xqt.XQTService
import dev.dimension.flare.data.network.xqt.model.Tweet
import dev.dimension.flare.data.network.xqt.model.TweetPreviewDisplay
import dev.dimension.flare.data.network.xqt.model.TweetTombstone
import dev.dimension.flare.data.network.xqt.model.TweetUnavailable
import dev.dimension.flare.data.network.xqt.model.TweetWithVisibilityResults
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.model.mapper.render
import kotlinx.serialization.Required
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@OptIn(ExperimentalPagingApi::class)
internal class StatusDetailRemoteMediator(
    override val statusKey: MicroBlogKey,
    private val service: XQTService,
    override val accountKey: MicroBlogKey,
    private val statusOnly: Boolean,
) : PostContextLoader {
    override val collapseReplyChains: Boolean = false

    override val pagingKey: String =
        buildString {
            append("status_detail_")
            if (statusOnly) {
                append("status_only_")
            }
            append(statusKey.toString())
            append("_")
            append(accountKey.toString())
        }

    private var conversationId: String? = null

    override fun contextUpdate(
        request: PagingRequest,
        result: PagingResult<UiTimelineV2>,
        initial: Boolean,
    ): ContextUpdate {
        if (request != PagingRequest.Refresh || statusOnly) {
            return result.toContextUpdate(statusKey, if (initial) PagingRequest.Refresh else request, initial)
        }
        // TweetDetail 首屏响应里本来就同时带着这条推文和第一批回复。
        // 以前这里只留主推文，回复被丢掉，然后 Paging 又串行发一次「初始 Append」
        // （而且那次 Append 还额外请求了一次主推文），进详情要等三个往返。
        // 现在直接把回复填进 after，首屏一个请求就能出评论。
        val anchor = result.data.indexOfFirst { it.statusKey == statusKey }
        if (anchor < 0) {
            return ContextUpdate(posts = result.data)
        }
        return ContextUpdate(
            posts = result.data,
            after =
                ContextPageUpdate(
                    keys = result.data.drop(anchor + 1).map { it.statusKey },
                    cursor = result.nextKey,
                    replace = true,
                ),
        )
    }

    override suspend fun load(
        pageSize: Int,
        request: PagingRequest,
    ): PagingResult<UiTimelineV2> =
        when (request) {
            is PagingRequest.Append -> {
                if (statusOnly) {
                    PagingResult(
                        endOfPaginationReached = true,
                    )
                } else {
                    val cursor = request.nextKey.takeIf { it.isNotEmpty() }
                    val response =
                        service
                            .getTweetDetail(
                                variables =
                                    TweetDetailRequest(
                                        focalTweetID = statusKey.id,
                                        cursor = cursor,
                                    ).encodeJson(),
                            ).body()
                            ?.data
                            ?.threadedConversationWithInjectionsV2
                            ?.instructions
                            .orEmpty()

                    // conversationId 在首屏 Refresh 时就从主推文取到了。
                    // 以前这里为了拿它又整发一次 getTweetResultByRestId，
                    // 等于每翻一页评论都白等一个完整往返。
                    val resolvedConversationId =
                        conversationId
                            ?: response
                                .tweets()
                                .firstOrNull { it.id == statusKey.id }
                                ?.let { conversationIdOf(it.tweets.tweetResults.result) }
                    if (resolvedConversationId != null) {
                        conversationId = resolvedConversationId
                    }

                    val actualTweet =
                        response
                            .tweets()
                            .filter { isValidInConversation(it, resolvedConversationId) }

                    PagingResult(
                        endOfPaginationReached = response.isBottomEnd() || actualTweet.size == 1 || response.cursor() == null,
                        data =
                            actualTweet.mapNotNull {
                                it.render(accountKey)
                            },
                        nextKey = response.cursor(),
                    )
                }
            }

            is PagingRequest.Prepend -> {
                PagingResult(
                    endOfPaginationReached = true,
                )
            }

            PagingRequest.Refresh -> {
                val response =
                    service
                        .getTweetDetail(
                            variables =
                                TweetDetailRequest(
                                    focalTweetID = statusKey.id,
                                    cursor = null,
                                ).encodeJson(),
                        ).body()
                        ?.data
                        ?.threadedConversationWithInjectionsV2
                        ?.instructions
                        .orEmpty()
                val tweet = response.tweets()
                val item = tweet.firstOrNull { it.id == statusKey.id }
                conversationId = item?.let { conversationIdOf(it.tweets.tweetResults.result) }

                // 首屏响应里本来就带着第一批回复，一并交给 Paging，
                // 这样进详情一个请求就能同时出主推文和评论。
                val data =
                    if (statusOnly) {
                        listOfNotNull(item)
                    } else {
                        tweet.filter { isValidInConversation(it, conversationId) }
                    }

                PagingResult(
                    endOfPaginationReached = statusOnly,
                    data = data.mapNotNull { it.render(accountKey) },
                    nextKey = if (statusOnly) null else response.cursor(),
                )
            }
        }
}

/**
 * 过滤掉墓碑 / 不可见 / 推广等无效推文，并只保留同一条对话里的内容。
 * conversationId 为空时（首屏拿不到主推文）退化为只做有效性过滤。
 */
private fun isValidInConversation(
    item: XQTTimeline,
    conversationId: String?,
): Boolean {
    val result = item.tweets.tweetResults.result
    return when (result) {
        is TweetTombstone,
        is TweetPreviewDisplay,
        is TweetUnavailable,
        null,
        -> false

        else -> conversationId == null || conversationIdOf(result) == conversationId
    }
}

private fun conversationIdOf(result: Any?): String? =
    when (result) {
        is Tweet -> result.legacy?.conversationIdStr
        is TweetWithVisibilityResults -> result.tweet.legacy?.conversationIdStr
        else -> null
    }

@Serializable
internal data class TweetDetailWithRestIdRequest(
    @SerialName("tweetId")
    val tweetID: String,
    @Required
    val withCommunity: Boolean = false,
    @Required
    val includePromotedContent: Boolean = false,
    @Required
    val withVoice: Boolean = false,
    @Required
    val withBirdwatchNotes: Boolean = true,
)

@Serializable
internal data class TweetDetailRequest(
    @SerialName("focalTweetId")
    val focalTweetID: String,
    val cursor: String? = null,
    @Required
    val referrer: String = "tweet",
    @SerialName("with_rux_injections")
    @Required
    val withRuxInjections: Boolean = false,
    @Required
    val includePromotedContent: Boolean = true,
    @Required
    val withCommunity: Boolean = true,
    @Required
    val withQuickPromoteEligibilityTweetFields: Boolean = true,
    @Required
    val withBirdwatchNotes: Boolean = true,
    @Required
    val withVoice: Boolean = true,
    @Required
    val withV2Timeline: Boolean = true,
)

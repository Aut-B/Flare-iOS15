package dev.dimension.flare.data.datasource.instagram

import dev.dimension.flare.data.datasource.microblog.loader.PostLoader
import dev.dimension.flare.data.datasource.microblog.loader.RelationActionType
import dev.dimension.flare.data.datasource.microblog.loader.RelationLoader
import dev.dimension.flare.data.datasource.microblog.loader.UserLoader
import dev.dimension.flare.data.datasource.microblog.paging.CacheableRemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.PagingRequest
import dev.dimension.flare.data.datasource.microblog.paging.PagingResult
import dev.dimension.flare.data.network.instagram.InstagramCredential
import dev.dimension.flare.data.network.instagram.InstagramPage
import dev.dimension.flare.data.network.instagram.InstagramService
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiHandle
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiRelation
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

internal abstract class InstagramTimelineLoader(
    protected val service: InstagramService,
    protected val accountKey: MicroBlogKey,
    protected val credentialFlow: Flow<InstagramCredential>,
) : CacheableRemoteLoader<UiTimelineV2> {
    override suspend fun load(
        pageSize: Int,
        request: PagingRequest,
    ): PagingResult<UiTimelineV2> {
        // Instagram 的时间线只能往后翻，没有「往新的方向加载」。
        if (request is PagingRequest.Prepend) {
            return PagingResult(endOfPaginationReached = true)
        }
        val nextKey =
            when (request) {
                PagingRequest.Refresh -> null
                is PagingRequest.Append -> request.nextKey
                is PagingRequest.Prepend -> null
            }
        val credential = credentialFlow.first()
        val page = loadPage(credential, nextKey)
        return PagingResult(
            data = page.items.mapNotNull { it.toUiPost(accountKey) },
            nextKey = page.nextMaxId,
            endOfPaginationReached = page.nextMaxId == null,
        )
    }

    protected abstract suspend fun loadPage(
        credential: InstagramCredential,
        nextKey: String?,
    ): InstagramPage
}

internal class InstagramHomeTimelineLoader(
    service: InstagramService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<InstagramCredential>,
) : InstagramTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "instagram_home_$accountKey"
    override val canJoinTimeline: Boolean = true

    override suspend fun loadPage(
        credential: InstagramCredential,
        nextKey: String?,
    ): InstagramPage = service.homeTimeline(credential, nextKey)
}

internal class InstagramUserTimelineLoader(
    service: InstagramService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<InstagramCredential>,
    private val userId: String,
) : InstagramTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "instagram_user_${userId}_$accountKey"

    override suspend fun loadPage(
        credential: InstagramCredential,
        nextKey: String?,
    ): InstagramPage = service.userTimeline(credential, userId, nextKey)
}

internal class InstagramStatusDetailLoader(
    service: InstagramService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<InstagramCredential>,
    private val statusKey: MicroBlogKey,
) : InstagramTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "instagram_status_${statusKey.id}_$accountKey"

    override suspend fun loadPage(
        credential: InstagramCredential,
        nextKey: String?,
    ): InstagramPage {
        // 详情只返回这一条，评论接口另有一套，先只给正文和配图。
        val media = service.mediaInfo(credential, statusKey.id) ?: return InstagramPage(emptyList(), null)
        return InstagramPage(listOf(media), null)
    }
}

internal class InstagramLoader(
    private val accountKey: MicroBlogKey,
    private val service: InstagramService,
    private val credentialFlow: Flow<InstagramCredential>,
) : PostLoader,
    UserLoader,
    RelationLoader {
    override suspend fun status(statusKey: MicroBlogKey): UiTimelineV2 {
        val credential = credentialFlow.first()
        val media =
            service.mediaInfo(credential, statusKey.id)
                ?: throw IllegalStateException("Instagram 帖子不存在或已被删除")
        return media.toUiPost(accountKey)
            ?: throw IllegalStateException("Instagram 帖子解析失败")
    }

    override suspend fun deleteStatus(statusKey: MicroBlogKey) {
        throw UnsupportedOperationException("Instagram 暂不支持删除帖子")
    }

    override suspend fun userByHandleAndHost(uiHandle: UiHandle): UiProfile {
        val credential = credentialFlow.first()
        val raw =
            service.userInfo(credential, uiHandle.normalizedRaw)
                ?: throw IllegalStateException("Instagram 用户不存在：${uiHandle.normalizedRaw}")
        return raw.toUiProfile(accountKey)
            ?: throw IllegalStateException("Instagram 用户解析失败")
    }

    override suspend fun userById(id: String): UiProfile {
        val credential = credentialFlow.first()
        val raw =
            service.userInfoById(credential, id)
                ?: throw IllegalStateException("Instagram 用户不存在：$id")
        return raw.toUiProfile(accountKey)
            ?: throw IllegalStateException("Instagram 用户解析失败")
    }

    // 关注 / 拉黑 / 静音都要写操作接口，先不开放，UI 上也就不会出现这些按钮。
    override val supportedTypes: Set<RelationActionType> = emptySet()

    override suspend fun relation(userKey: MicroBlogKey): UiRelation = throw UnsupportedOperationException("Instagram 暂不支持查看关注关系")

    override suspend fun follow(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持关注")

    override suspend fun unfollow(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持取消关注")

    override suspend fun block(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持拉黑")

    override suspend fun unblock(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持解除拉黑")

    override suspend fun mute(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持静音")

    override suspend fun unmute(userKey: MicroBlogKey) = throw UnsupportedOperationException("Instagram 暂不支持取消静音")
}

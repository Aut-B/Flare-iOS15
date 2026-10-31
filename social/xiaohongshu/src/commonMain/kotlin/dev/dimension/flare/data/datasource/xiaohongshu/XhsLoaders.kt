package dev.dimension.flare.data.datasource.xiaohongshu

import dev.dimension.flare.data.datasource.microblog.loader.UserLoader
import dev.dimension.flare.data.datasource.microblog.paging.CacheableRemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.PagingRequest
import dev.dimension.flare.data.datasource.microblog.paging.PagingResult
import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiHandle
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

internal abstract class XhsTimelineLoader(
    protected val service: XhsService,
    protected val accountKey: MicroBlogKey,
    protected val credentialFlow: Flow<XhsCredential>,
) : CacheableRemoteLoader<UiTimelineV2> {
    override suspend fun load(
        pageSize: Int,
        request: PagingRequest,
    ): PagingResult<UiTimelineV2> {
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
            nextKey = page.next,
            endOfPaginationReached = page.next == null,
        )
    }

    protected abstract suspend fun loadPage(
        credential: XhsCredential,
        nextKey: String?,
    ): XhsPage
}

internal class XhsHomeTimelineLoader(
    service: XhsService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<XhsCredential>,
    private val follow: Boolean = false,
) : XhsTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "xhs_home_${if (follow) "follow" else "recommend"}_$accountKey"
    override val canJoinTimeline: Boolean = true

    override suspend fun loadPage(
        credential: XhsCredential,
        nextKey: String?,
    ): XhsPage = service.homeFeed(credential, nextKey, follow)
}

internal class XhsUserTimelineLoader(
    service: XhsService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<XhsCredential>,
    private val userId: String,
) : XhsTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "xhs_user_${userId}_$accountKey"

    override suspend fun loadPage(
        credential: XhsCredential,
        nextKey: String?,
    ): XhsPage = service.userNotes(credential, userId, nextKey)
}

internal class XhsStatusDetailLoader(
    service: XhsService,
    accountKey: MicroBlogKey,
    credentialFlow: Flow<XhsCredential>,
    private val statusKey: MicroBlogKey,
) : XhsTimelineLoader(service, accountKey, credentialFlow) {
    override val pagingKey: String = "xhs_status_${statusKey.id}_$accountKey"

    override suspend fun loadPage(
        credential: XhsCredential,
        nextKey: String?,
    ): XhsPage = XhsPage(listOf(service.note(credential, statusKey.id)), null)
}

/**
 * 小红书用户资料。
 *
 * 账号页会用 `accountKey.id` 取一次资料，没有这个能力就会直接报
 * 「Account service is not authenticated user data source」。
 * 真正按 id 拉用户资料的接口要 `X-S` 签名，宿主只实现了笔记相关的几个，
 * 所以这里先返回占位资料 —— 名字 / 头像拿不到，但页面能正常渲染。
 */
internal class XhsLoader(
    private val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<XhsCredential>,
) : UserLoader {
    override suspend fun userByHandleAndHost(uiHandle: UiHandle): UiProfile =
        placeholderProfile(
            id = uiHandle.normalizedRaw,
            name = uiHandle.normalizedRaw,
            accountKey = accountKey,
        )

    override suspend fun userById(id: String): UiProfile {
        val credential = credentialFlow.first()
        return placeholderProfile(
            id = id,
            name = credential.userName,
            accountKey = accountKey,
        )
    }
}

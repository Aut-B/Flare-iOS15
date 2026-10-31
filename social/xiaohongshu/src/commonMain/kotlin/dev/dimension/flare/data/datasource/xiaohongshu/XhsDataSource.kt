package dev.dimension.flare.data.datasource.xiaohongshu

import dev.dimension.flare.data.datasource.microblog.AuthenticatedMicroblogDataSource
import dev.dimension.flare.data.datasource.microblog.ProfileTab
import dev.dimension.flare.data.datasource.microblog.paging.RemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.notSupported
import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiHashtag
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiStrings
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.Flow

/**
 * 小红书数据源。
 *
 * 只做浏览：推荐流、用户主页、笔记详情。签名由宿主的 [XhsBridge] 提供。
 */
internal class XhsDataSource(
    override val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<XhsCredential>,
) : AuthenticatedMicroblogDataSource {
    private val service = XhsService()

    override fun homeTimeline(): RemoteLoader<UiTimelineV2> =
        XhsHomeTimelineLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
        )

    override fun userTimeline(
        userKey: MicroBlogKey,
        mediaOnly: Boolean,
    ): RemoteLoader<UiTimelineV2> =
        XhsUserTimelineLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
            userId = userKey.id,
        )

    override fun context(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        XhsStatusDetailLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
            statusKey = statusKey,
        )

    override fun searchStatus(query: String): RemoteLoader<UiTimelineV2> = notSupported()

    override fun searchUser(query: String): RemoteLoader<UiProfile> = notSupported()

    override fun discoverUsers(): RemoteLoader<UiProfile> = notSupported()

    override fun discoverStatuses(): RemoteLoader<UiTimelineV2> = notSupported()

    override fun discoverHashtags(): RemoteLoader<UiHashtag> = notSupported()

    override fun following(userKey: MicroBlogKey): RemoteLoader<UiProfile> = notSupported()

    override fun fans(userKey: MicroBlogKey): RemoteLoader<UiProfile> = notSupported()

    override suspend fun profileTabs(userKey: MicroBlogKey): ImmutableList<ProfileTab> =
        persistentListOf(
            ProfileTab(
                name = UiStrings.Posts,
                loader =
                    XhsUserTimelineLoader(
                        service = service,
                        accountKey = accountKey,
                        credentialFlow = credentialFlow,
                        userId = userKey.id,
                    ),
            ),
        )
}

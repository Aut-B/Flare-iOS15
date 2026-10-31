package dev.dimension.flare.data.datasource.instagram

import dev.dimension.flare.data.datasource.microblog.AuthenticatedMicroblogDataSource
import dev.dimension.flare.data.datasource.microblog.ProfileTab
import dev.dimension.flare.data.datasource.microblog.paging.RemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.notSupported
import dev.dimension.flare.data.network.instagram.InstagramCredential
import dev.dimension.flare.data.network.instagram.InstagramService
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiHashtag
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiStrings
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.Flow

/**
 * Instagram 的数据源。
 *
 * 只做了「看」的部分：首页时间线、用户主页、帖子详情。
 * 发帖 / 点赞 / 关注都还没接，对应的能力接口一个都没实现，
 * 所以 UI 上不会出现那些按钮，而不是点了才报错。
 */
internal class InstagramDataSource(
    override val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<InstagramCredential>,
) : AuthenticatedMicroblogDataSource {
    private val service = InstagramService()

    override fun homeTimeline(): RemoteLoader<UiTimelineV2> =
        InstagramHomeTimelineLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
        )

    override fun userTimeline(
        userKey: MicroBlogKey,
        mediaOnly: Boolean,
    ): RemoteLoader<UiTimelineV2> =
        InstagramUserTimelineLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
            userId = userKey.id,
        )

    override fun context(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        InstagramStatusDetailLoader(
            service = service,
            accountKey = accountKey,
            credentialFlow = credentialFlow,
            statusKey = statusKey,
        )

    // 下面这些 Instagram 网页接口没有对应能力，或者需要写操作权限，先空着。
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
                    InstagramUserTimelineLoader(
                        service = service,
                        accountKey = accountKey,
                        credentialFlow = credentialFlow,
                        userId = userKey.id,
                    ),
            ),
        )
}

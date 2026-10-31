package dev.dimension.flare.data.datasource.instagram

import dev.dimension.flare.data.datasource.microblog.AuthenticatedMicroblogDataSource
import dev.dimension.flare.data.datasource.microblog.ProfileTab
import dev.dimension.flare.data.datasource.microblog.datasource.RelationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.TimelineTabConfigurationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.UserDataSource
import dev.dimension.flare.data.datasource.microblog.handler.RelationHandler
import dev.dimension.flare.data.datasource.microblog.handler.UserHandler
import dev.dimension.flare.data.datasource.microblog.loader.RelationActionType
import dev.dimension.flare.data.datasource.microblog.paging.RemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.notSupported
import dev.dimension.flare.data.model.IconType
import dev.dimension.flare.data.model.tab.ShortcutSpec
import dev.dimension.flare.data.model.tab.TimelineCandidate
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.instagram.INSTAGRAM_HOST
import dev.dimension.flare.data.network.instagram.InstagramCredential
import dev.dimension.flare.data.network.instagram.InstagramService
import dev.dimension.flare.data.platform.CommonTimelineSpecs
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiHashtag
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiStrings
import dev.dimension.flare.ui.model.UiText
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
) : AuthenticatedMicroblogDataSource,
    UserDataSource,
    RelationDataSource,
    TimelineTabConfigurationDataSource {
    private val service = InstagramService()

    // 账号页要按 accountKey.id 取一次资料，没有 UserDataSource 就会直接报
    // 「Account service is not authenticated user data source」。
    override val userHandler: UserHandler =
        UserHandler(
            host = INSTAGRAM_HOST,
            loader =
                InstagramLoader(
                    accountKey = accountKey,
                    service = service,
                    credentialFlow = credentialFlow,
                ),
        )

    /** 个人主页会读这个字段，缺了 `ProfilePresenter` 会直接抛异常闪退。 */
    override val relationHandler: RelationHandler by lazy {
        RelationHandler(
            accountType = AccountType.Specific(accountKey),
            dataSource = InstagramRelationLoader,
        )
    }

    override val supportedRelationTypes: Set<RelationActionType> = InstagramRelationLoader.supportedTypes

    /** 新账号登录后自动落一个「主页」标签页，否则标签栏里看不到这个平台。 */
    override val defaultTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("Instagram"),
            ),
        )
    }

    override val builtInTimelineTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("Instagram"),
            ),
        )
    }

    override val shortcuts: ImmutableList<ShortcutSpec> = persistentListOf()

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

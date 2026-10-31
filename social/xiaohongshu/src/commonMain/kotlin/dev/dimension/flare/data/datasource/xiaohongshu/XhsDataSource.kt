package dev.dimension.flare.data.datasource.xiaohongshu

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
import dev.dimension.flare.data.network.xiaohongshu.XHS_HOST
import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
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
 * 小红书数据源。
 *
 * 只做浏览：推荐流、用户主页、笔记详情。签名由宿主的 [XhsBridge] 提供。
 */
internal class XhsDataSource(
    override val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<XhsCredential>,
) : AuthenticatedMicroblogDataSource,
    UserDataSource,
    RelationDataSource,
    TimelineTabConfigurationDataSource {
    private val service = XhsService()

    // 账号页要按 accountKey.id 取一次资料，缺了就会报
    // 「Account service is not authenticated user data source」。
    override val userHandler: UserHandler =
        UserHandler(
            host = XHS_HOST,
            loader =
                XhsLoader(
                    accountKey = accountKey,
                    credentialFlow = credentialFlow,
                ),
        )

    /**
     * 个人主页会读这个字段。之前没实现 `RelationDataSource`，
     * `ProfilePresenter` 里的 `require(service is RelationDataSource)` 直接抛异常，
     * 于是点「我的主页」就闪退。
     */
    override val relationHandler: RelationHandler by lazy {
        RelationHandler(
            accountType = AccountType.Specific(accountKey),
            dataSource = XhsRelationLoader,
        )
    }

    override val supportedRelationTypes: Set<RelationActionType> = XhsRelationLoader.supportedTypes

    /**
     * 新账号登录后自动落一个「主页」标签页。
     *
     * 标签页是用户自己维护的列表，之前小红书没声明 defaultTabs，
     * 账号加进去了但标签栏里什么都没有 —— 用户会觉得「登了但没法刷」。
     */
    override val defaultTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("小红书"),
            ),
        )
    }

    override val builtInTimelineTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("小红书"),
            ),
        )
    }

    override val shortcuts: ImmutableList<ShortcutSpec> = persistentListOf()

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

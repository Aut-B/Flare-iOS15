package dev.dimension.flare.data.datasource.weread

import dev.dimension.flare.data.datasource.microblog.AuthenticatedMicroblogDataSource
import dev.dimension.flare.data.datasource.microblog.ProfileTab
import dev.dimension.flare.data.datasource.microblog.datasource.TimelineTabConfigurationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.UserDataSource
import dev.dimension.flare.data.datasource.microblog.handler.UserHandler
import dev.dimension.flare.data.datasource.microblog.loader.UserLoader
import dev.dimension.flare.data.datasource.microblog.paging.RemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.notSupported
import dev.dimension.flare.data.model.IconType
import dev.dimension.flare.data.model.tab.ShortcutSpec
import dev.dimension.flare.data.model.tab.TimelineCandidate
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.weread.WEREAD_HOST
import dev.dimension.flare.data.network.weread.WEREAD_PLATFORM_ID
import dev.dimension.flare.data.network.weread.WeReadBridgeHolder
import dev.dimension.flare.data.network.weread.WeReadCredential
import dev.dimension.flare.data.platform.CommonTimelineSpecs
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.ClickEvent
import dev.dimension.flare.ui.model.UiHandle
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiStrings
import dev.dimension.flare.ui.model.UiText
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.render.toUiPlainText
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.firstOrNull

/**
 * 微信读书的「账号壳」。
 *
 * 它没有时间线，书架是 Swift 原生页面；但账号列表、侧边栏和「我」入口都要求
 * 一个 `UserDataSource`。这里只提供占位资料和空时间线，真正的书架仍由
 * `WereadShelfView` 读取 `WereadStore`。
 */
internal class WeReadDataSource(
    override val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<WeReadCredential>,
) : AuthenticatedMicroblogDataSource,
    UserDataSource,
    TimelineTabConfigurationDataSource {
    override val userHandler: UserHandler =
        UserHandler(
            host = WEREAD_HOST,
            loader = WeReadUserLoader(accountKey, credentialFlow),
        )

    // 用一个标题为「微信读书」的占位时间线标签，让首页标签栏也有入口；
    // 真正的加载器是 notSupported，iOS 侧会按标题直接渲染原生书架。
    override val defaultTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("微信读书"),
            ),
        )
    }

    override val builtInTimelineTabs: ImmutableList<TimelineCandidate<*>> by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.World),
                title = UiText.Raw("微信读书"),
            ),
        )
    }
    override val shortcuts: ImmutableList<ShortcutSpec> = persistentListOf<ShortcutSpec>()

    override fun homeTimeline(): RemoteLoader<UiTimelineV2> = notSupported()
    override fun userTimeline(
        userKey: MicroBlogKey,
        mediaOnly: Boolean,
    ): RemoteLoader<UiTimelineV2> = notSupported()

    override fun context(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> = notSupported()
    override fun searchStatus(query: String): RemoteLoader<UiTimelineV2> = notSupported()
    override fun searchUser(query: String): RemoteLoader<UiProfile> = notSupported()
    override fun discoverUsers(): RemoteLoader<UiProfile> = notSupported()
    override fun discoverStatuses(): RemoteLoader<UiTimelineV2> = notSupported()
    override fun discoverHashtags(): RemoteLoader<dev.dimension.flare.ui.model.UiHashtag> = notSupported()
    override fun following(userKey: MicroBlogKey): RemoteLoader<UiProfile> = notSupported()
    override fun fans(userKey: MicroBlogKey): RemoteLoader<UiProfile> = notSupported()

    override suspend fun profileTabs(userKey: MicroBlogKey): ImmutableList<ProfileTab> =
        persistentListOf(
            ProfileTab(
                name = UiStrings.Posts,
                loader = notSupported(),
            ),
        )
}

private class WeReadUserLoader(
    private val accountKey: MicroBlogKey,
    private val credentialFlow: Flow<WeReadCredential>,
) : UserLoader {
    override suspend fun userByHandleAndHost(uiHandle: UiHandle): UiProfile =
        placeholderProfile(
            id = uiHandle.normalizedRaw,
            name = uiHandle.normalizedRaw,
            accountKey = accountKey,
        )

    override suspend fun userById(id: String): UiProfile {
        // 触发一次 credentialFlow，保证账号确实已经写入；顺手把 cookie
        // 推给原生 WereadStore，书架页不用再登录一次。
        credentialFlow.firstOrNull()?.let { credential ->
            WeReadBridgeHolder.bridge?.adopt(credential.cookie)
        }
        return placeholderProfile(
            id = id,
            name = "微信读书",
            accountKey = accountKey,
        )
    }
}

private fun placeholderProfile(
    id: String,
    name: String,
    accountKey: MicroBlogKey,
): UiProfile {
    val userKey = MicroBlogKey(id, WEREAD_HOST)
    val display = name.ifBlank { "微信读书" }
    return UiProfile(
        key = userKey,
        handle = UiHandle(raw = display, host = WEREAD_HOST),
        avatar = null,
        nameInternal = display.toUiPlainText(),
        platformId = WEREAD_PLATFORM_ID,
        platformIcon = UiIcon.World,
        clickEvent = ClickEvent.Noop,
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

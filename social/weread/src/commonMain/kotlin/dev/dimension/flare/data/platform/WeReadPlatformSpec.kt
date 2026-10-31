package dev.dimension.flare.data.platform

import dev.dimension.flare.data.datasource.microblog.MicroblogDataSource
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.weread.WEREAD_HOST
import dev.dimension.flare.data.network.weread.WEREAD_PLATFORM_ID
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.model.PlatformDataSourceContext
import dev.dimension.flare.model.PlatformDeepLink
import dev.dimension.flare.model.PlatformMetadata
import dev.dimension.flare.model.PlatformSpec
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.presenter.login.LoginPlatformProvider
import dev.dimension.flare.ui.presenter.login.WeReadLoginProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlin.native.HiddenFromObjC

/**
 * 微信读书平台。
 *
 * 它只参与**登录**，不参与时间线：书架是原生页面（Swift 侧 `WereadStore`），
 * 登录成功后 cookie 直接交给宿主，不会在账号列表里多出一个空账号。
 * 所以 [createDataSource] / [guestDataSource] 都是不支持 —— 正常路径不会走到。
 */
@HiddenFromObjC
public data object WeReadPlatformSpec :
    PlatformSpec,
    LoginPlatformProvider by WeReadLoginProvider {
    override val platformId: String = WEREAD_PLATFORM_ID

    // 必须显式覆盖：LoginPlatformProvider 的默认实现会反过来取这里，
    // 不覆盖就成死循环了。
    override val metadata: PlatformMetadata =
        PlatformMetadata(
            displayName = "微信读书",
            icon = UiIcon.World,
        )

    override val order: Int = 52

    override val timelineSpecs: ImmutableList<TimelineSpec<out TimelineSpec.Data>> =
        persistentListOf()

    override fun deepLinks(accountKey: MicroBlogKey): ImmutableList<PlatformDeepLink<*>> =
        persistentListOf()

    override fun createDataSource(context: PlatformDataSourceContext): MicroblogDataSource =
        throw UnsupportedOperationException("微信读书没有时间线，书架走原生页面")

    override fun guestDataSource(
        host: String,
        locale: String,
    ): MicroblogDataSource = throw UnsupportedOperationException("微信读书不支持游客模式")

    internal val host: String = WEREAD_HOST
}

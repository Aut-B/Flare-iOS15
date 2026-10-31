package dev.dimension.flare.data.platform

import dev.dimension.flare.data.datasource.microblog.MicroblogDataSource
import dev.dimension.flare.data.datasource.weread.WeReadDataSource
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.weread.WEREAD_HOST
import dev.dimension.flare.data.network.weread.WEREAD_PLATFORM_ID
import dev.dimension.flare.data.network.weread.WeReadCredential
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
 * 它不参与时间线：书架是原生页面（Swift 侧 `WereadStore`）。但账号列表、
 * 侧边栏和「我」入口要求一个 `UserDataSource`，所以 [createDataSource]
 * 返回一个只有占位资料的账号壳，真正的书架仍走原生页。
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
        WeReadDataSource(
            accountKey = context.accountKey,
            credentialFlow = context.credentialFlow(WeReadCredential.serializer()),
        )

    override fun guestDataSource(
        host: String,
        locale: String,
    ): MicroblogDataSource = throw UnsupportedOperationException("微信读书不支持游客模式")

    internal val host: String = WEREAD_HOST
}

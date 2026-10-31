package dev.dimension.flare.data.platform

import dev.dimension.flare.data.datasource.microblog.MicroblogDataSource
import dev.dimension.flare.data.datasource.xiaohongshu.XhsDataSource
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.xiaohongshu.XHS_HOST
import dev.dimension.flare.data.network.xiaohongshu.XHS_PLATFORM_ID
import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.model.PlatformDataSourceContext
import dev.dimension.flare.model.PlatformDeepLink
import dev.dimension.flare.model.PlatformMetadata
import dev.dimension.flare.model.PlatformSpec
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.presenter.login.LoginPlatformProvider
import dev.dimension.flare.ui.presenter.login.XhsLoginProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlin.native.HiddenFromObjC

/**
 * 小红书平台。
 *
 * 和 Instagram 一样走网页 cookie 登录。区别在于接口签名：`X-S` / `X-T` 要在网页里
 * 用 `window._webmsxyw` 算，Kotlin 侧算不了，所以真正的请求由宿主通过
 * [dev.dimension.flare.data.datasource.xiaohongshu.XhsBridge] 完成。
 */
@HiddenFromObjC
public data object XhsPlatformSpec :
    PlatformSpec,
    LoginPlatformProvider by XhsLoginProvider {
    override val platformId: String = XHS_PLATFORM_ID

    override val metadata: PlatformMetadata =
        PlatformMetadata(
            displayName = "小红书",
            icon = UiIcon.World,
        )

    override val order: Int = 51

    override val timelineSpecs: ImmutableList<TimelineSpec<out TimelineSpec.Data>> =
        persistentListOf(CommonTimelineSpecs.home)

    override fun deepLinks(accountKey: MicroBlogKey): ImmutableList<PlatformDeepLink<*>> =
        persistentListOf()

    override fun createDataSource(context: PlatformDataSourceContext): MicroblogDataSource =
        XhsDataSource(
            accountKey = context.accountKey,
            credentialFlow = context.credentialFlow(XhsCredential.serializer()),
        )

    override fun guestDataSource(
        host: String,
        locale: String,
    ): MicroblogDataSource = throw UnsupportedOperationException("小红书不支持游客模式")
}

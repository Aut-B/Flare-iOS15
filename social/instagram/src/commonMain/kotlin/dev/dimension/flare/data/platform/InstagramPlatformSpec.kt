package dev.dimension.flare.data.platform

import dev.dimension.flare.data.datasource.instagram.InstagramDataSource
import dev.dimension.flare.data.datasource.microblog.MicroblogDataSource
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.instagram.INSTAGRAM_HOST
import dev.dimension.flare.data.network.instagram.INSTAGRAM_PLATFORM_ID
import dev.dimension.flare.data.network.instagram.InstagramCredential
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.model.PlatformDataSourceContext
import dev.dimension.flare.model.PlatformDeepLink
import dev.dimension.flare.model.PlatformMetadata
import dev.dimension.flare.model.PlatformSpec
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.presenter.login.InstagramLoginProvider
import dev.dimension.flare.ui.presenter.login.LoginPlatformProvider
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlin.native.HiddenFromObjC

/**
 * Instagram 平台。
 *
 * 走网页版 cookie 登录（和微博、FANBOX 一致）：用户在网页里登录一次，
 * 之后所有请求只靠 cookie + `X-IG-App-ID`，没有需要频繁变动的签名。
 * 登录态失效时客户端会退到登录页，重新扫一次即可。
 */
@HiddenFromObjC
public data object InstagramPlatformSpec :
    PlatformSpec,
    LoginPlatformProvider by InstagramLoginProvider {
    override val platformId: String = INSTAGRAM_PLATFORM_ID

    // 必须显式覆盖：LoginPlatformProvider 的默认实现会反过来取这里，
    // 不覆盖就成死循环了。
    override val metadata: PlatformMetadata =
        PlatformMetadata(
            displayName = "Instagram",
            icon = UiIcon.World,
        )

    override val order: Int = 50

    override val timelineSpecs: ImmutableList<TimelineSpec<out TimelineSpec.Data>> =
        persistentListOf(CommonTimelineSpecs.home)

    override fun deepLinks(accountKey: MicroBlogKey): ImmutableList<PlatformDeepLink<*>> =
        persistentListOf()

    override fun createDataSource(context: PlatformDataSourceContext): MicroblogDataSource =
        InstagramDataSource(
            accountKey = context.accountKey,
            credentialFlow = context.credentialFlow(InstagramCredential.serializer()),
        )

    override fun guestDataSource(
        host: String,
        locale: String,
    ): MicroblogDataSource = throw UnsupportedOperationException("Instagram 不支持游客模式")

    internal val host: String = INSTAGRAM_HOST
}

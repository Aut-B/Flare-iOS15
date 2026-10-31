package dev.dimension.flare.ui.presenter.login

import dev.dimension.flare.data.datasource.instagram.igMediaId
import dev.dimension.flare.data.datasource.instagram.igString
import dev.dimension.flare.data.network.instagram.INSTAGRAM_HOST
import dev.dimension.flare.data.network.instagram.INSTAGRAM_PLATFORM_ID
import dev.dimension.flare.data.network.instagram.InstagramCredential
import dev.dimension.flare.data.network.instagram.InstagramPlatformDetector
import dev.dimension.flare.data.network.instagram.InstagramService
import dev.dimension.flare.data.platform.InstagramPlatformSpec
import dev.dimension.flare.data.repository.AccountService
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.model.PlatformMetadata
import dev.dimension.flare.model.RecommendedInstance
import dev.dimension.flare.ui.model.UiAccount
import dev.dimension.flare.ui.model.UiInstance
import dev.dimension.flare.ui.model.UiInstanceMetadata
import dev.dimension.flare.ui.model.UiStrings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

private const val LOGIN_ACTION = "login"

/** 网页登录入口。桌面 UA 才能走完整的账号密码 / 验证码流程。 */
private const val INSTAGRAM_LOGIN_URL = "https://www.instagram.com/accounts/login/"

public data object InstagramLoginProvider : LoginPlatformProvider {
    override val platformId: String = INSTAGRAM_PLATFORM_ID

    override val metadata: PlatformMetadata
        get() = InstagramPlatformSpec.metadata

    override val detector: PlatformDetector = InstagramPlatformDetector

    override val methods: List<LoginMethodSpec> =
        listOf(
            LoginMethodSpec(
                type = LoginMethodType.WebCookie,
                title = UiStrings.WebCookieLogin,
            ),
        )

    override fun agreementUrl(host: String): String? = "https://help.instagram.com/581066165581870"

    override suspend fun recommendInstances(): List<RecommendedInstance> =
        listOf(
            RecommendedInstance(
                instance =
                    UiInstance(
                        name = "Instagram",
                        description = "照片与短视频。网页登录后直接用 cookie 访问。",
                        iconUrl = null,
                        domain = INSTAGRAM_HOST,
                        platformId = platformId,
                        bannerUrl = null,
                        usersCount = 0,
                    ),
                // 排在微博 / 毛象这些主力平台后面，但要在 RSS 之前。
                priority = 60,
            ),
        )

    override suspend fun instanceMetadata(host: String): UiInstanceMetadata =
        throw UnsupportedOperationException("$platformId metadata is not supported yet")

    override fun createHandler(context: LoginContext): LoginMethodHandler {
        require(context.methodType == LoginMethodType.WebCookie) {
            "Unsupported Instagram login method: ${context.methodType}"
        }
        return InstagramWebCookieLoginHandler(context)
    }
}

private class InstagramWebCookieLoginHandler(
    private val context: LoginContext,
) : LoginMethodHandler {
    private val accountService: AccountService by koinInject()
    private val _state = MutableStateFlow(state())
    private val _effects = MutableSharedFlow<LoginEffect>(extraBufferCapacity = 1)

    override val state: StateFlow<LoginFlowState> = _state
    override val effects: Flow<LoginEffect> = _effects

    override fun updateField(
        id: String,
        value: String,
    ) = Unit

    override suspend fun perform(actionId: String) {
        if (actionId != LOGIN_ACTION) return
        _effects.emit(LoginEffect.OpenWebCookieLogin(url = INSTAGRAM_LOGIN_URL))
    }

    override suspend fun resume(value: String) {
        _state.value = state(loading = true)
        runCatching {
            val parsed = InstagramCredential.fromCookie(value)
            require(InstagramCredential.normalize(value).contains("sessionid=")) {
                "没有拿到 Instagram 的登录 cookie，请确认网页里已经登录成功"
            }
            // 网页里的 cookie 只是「可能登录了」，再问一次接口确认身份，顺便拿用户名。
            // 这一步只是锦上添花：cookie 里本来就有 ds_user_id，探测接口 400 / 超时
            // 不该把人挡在登录外面 —— 否则就变成「明明登录成功了却加不上账号」。
            val user = runCatching { InstagramService().currentUser(parsed) }.getOrNull()
            val userId =
                (user?.igMediaId() ?: parsed.userId)
                    .orEmpty()
                    .takeIf { it.isNotBlank() }
                    ?: throw IllegalStateException(
                        "Cookie 里缺少 ds_user_id。只贴 sessionid 的值不够，" +
                            "请把整段 Cookie 一起复制（至少含 sessionid 与 ds_user_id）。",
                    )
            val credential =
                parsed.copy(
                    userId = userId,
                    userName = user?.igString("username").orEmpty(),
                )
            val accountKey = MicroBlogKey(userId, INSTAGRAM_HOST)
            context.requireReloginAccount(accountKey)
            accountService.addAccount(
                account =
                    UiAccount(
                        accountKey = accountKey,
                        platformId = INSTAGRAM_PLATFORM_ID,
                    ),
                credential = credential,
                serializer = InstagramCredential.serializer(),
            )
            context.onSuccess()
        }.onFailure {
            _state.value = state(error = it.message)
        }
    }

    override fun canResume(value: String): Boolean =
        InstagramCredential.normalize(value).contains("sessionid=")

    override fun clear() {
        _state.value = state()
    }

    private fun state(
        loading: Boolean = false,
        error: String? = null,
    ): LoginFlowState =
        LoginFlowState(
            actions =
                listOf(
                    LoginAction(
                        id = LOGIN_ACTION,
                        label = UiStrings.Login,
                        enabled = !loading,
                    ),
                ),
            loading = loading,
            error = error,
        )
}

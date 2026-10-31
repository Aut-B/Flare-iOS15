package dev.dimension.flare.ui.presenter.login

import dev.dimension.flare.data.network.xiaohongshu.XHS_HOST
import dev.dimension.flare.data.network.xiaohongshu.XHS_LOGIN_URL
import dev.dimension.flare.data.network.xiaohongshu.XHS_PLATFORM_ID
import dev.dimension.flare.data.network.xiaohongshu.XhsCredential
import dev.dimension.flare.data.network.xiaohongshu.XhsPlatformDetector
import dev.dimension.flare.data.platform.XhsPlatformSpec
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

public data object XhsLoginProvider : LoginPlatformProvider {
    override val platformId: String = XHS_PLATFORM_ID

    override val metadata: PlatformMetadata
        get() = XhsPlatformSpec.metadata

    override val detector: PlatformDetector = XhsPlatformDetector

    override val methods: List<LoginMethodSpec> =
        listOf(
            LoginMethodSpec(
                type = LoginMethodType.WebCookie,
                title = UiStrings.WebCookieLogin,
            ),
        )

    override fun agreementUrl(host: String): String? = "https://www.xiaohongshu.com/protocols/user"

    override suspend fun recommendInstances(): List<RecommendedInstance> =
        listOf(
            RecommendedInstance(
                instance =
                    UiInstance(
                        name = "小红书",
                        description = "图文与短视频笔记。网页登录后直接用 cookie 访问。",
                        iconUrl = null,
                        domain = XHS_HOST,
                        platformId = platformId,
                        bannerUrl = null,
                        usersCount = 0,
                    ),
                priority = 59,
            ),
        )

    override suspend fun instanceMetadata(host: String): UiInstanceMetadata =
        throw UnsupportedOperationException("$platformId metadata is not supported yet")

    override fun createHandler(context: LoginContext): LoginMethodHandler {
        require(context.methodType == LoginMethodType.WebCookie) {
            "Unsupported 小红书 login method: ${context.methodType}"
        }
        return XhsWebCookieLoginHandler(context)
    }
}

private class XhsWebCookieLoginHandler(
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
        _effects.emit(LoginEffect.OpenWebCookieLogin(url = XHS_LOGIN_URL))
    }

    override suspend fun resume(value: String) {
        _state.value = state(loading = true)
        runCatching {
            require(value.contains("web_session=")) {
                "没有拿到小红书的登录 cookie，请确认网页里已经登录成功"
            }
            val credential = XhsCredential.fromCookie(value)
            val accountKey = MicroBlogKey(credential.userId, XHS_HOST)
            context.requireReloginAccount(accountKey)
            accountService.addAccount(
                account =
                    UiAccount(
                        accountKey = accountKey,
                        platformId = XHS_PLATFORM_ID,
                    ),
                credential = credential,
                serializer = XhsCredential.serializer(),
            )
            context.onSuccess()
        }.onFailure {
            _state.value = state(error = it.message)
        }
    }

    override fun canResume(value: String): Boolean = value.contains("web_session=")

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

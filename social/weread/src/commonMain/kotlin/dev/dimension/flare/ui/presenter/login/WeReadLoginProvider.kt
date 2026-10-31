package dev.dimension.flare.ui.presenter.login

import dev.dimension.flare.data.network.weread.WEREAD_HOST
import dev.dimension.flare.data.network.weread.WEREAD_LOGIN_URL
import dev.dimension.flare.data.network.weread.WEREAD_PLATFORM_ID
import dev.dimension.flare.data.network.weread.WeReadBridgeHolder
import dev.dimension.flare.data.network.weread.WeReadCredential
import dev.dimension.flare.data.network.weread.WeReadPlatformDetector
import dev.dimension.flare.data.platform.WeReadPlatformSpec
import dev.dimension.flare.model.PlatformMetadata
import dev.dimension.flare.model.RecommendedInstance
import dev.dimension.flare.ui.model.UiInstance
import dev.dimension.flare.ui.model.UiInstanceMetadata
import dev.dimension.flare.ui.model.UiStrings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

private const val LOGIN_ACTION = "login"

/**
 * 微信读书的登录入口。
 *
 * 微信读书没有「时间线」这种东西（它是书架），所以这里**不建账号**：
 * 登录成功后只把 cookie 交给宿主（Swift 侧 `WereadStore`），
 * 书架页自己去读。这样「添加账号 → 实例」里能搜到它，
 * 又不会在账号列表里多出一个点进去空空的账号。
 */
public data object WeReadLoginProvider : LoginPlatformProvider {
    override val platformId: String = WEREAD_PLATFORM_ID

    override val metadata: PlatformMetadata
        get() = WeReadPlatformSpec.metadata

    override val detector: PlatformDetector = WeReadPlatformDetector

    override val methods: List<LoginMethodSpec> =
        listOf(
            LoginMethodSpec(
                type = LoginMethodType.WebCookie,
                title = UiStrings.WebCookieLogin,
            ),
        )

    override fun agreementUrl(host: String): String? = "https://weread.qq.com/agreement"

    override suspend fun recommendInstances(): List<RecommendedInstance> =
        listOf(
            RecommendedInstance(
                instance =
                    UiInstance(
                        name = "微信读书",
                        description = "书架与阅读进度。网页登录或粘贴 cookie 后可用。",
                        iconUrl = null,
                        domain = WEREAD_HOST,
                        platformId = platformId,
                        bannerUrl = null,
                        usersCount = 0,
                    ),
                priority = 55,
            ),
        )

    override suspend fun instanceMetadata(host: String): UiInstanceMetadata =
        throw UnsupportedOperationException("$platformId metadata is not supported yet")

    override fun createHandler(context: LoginContext): LoginMethodHandler {
        require(context.methodType == LoginMethodType.WebCookie) {
            "Unsupported WeRead login method: ${context.methodType}"
        }
        return WeReadWebCookieLoginHandler(context)
    }
}

private class WeReadWebCookieLoginHandler(
    private val context: LoginContext,
) : LoginMethodHandler {
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
        _effects.emit(LoginEffect.OpenWebCookieLogin(url = WEREAD_LOGIN_URL))
    }

    override suspend fun resume(value: String) {
        _state.value = state(loading = true)
        runCatching {
            val normalized = WeReadCredential.normalize(value)
            require(normalized.contains("wr_vid=")) {
                "没有拿到微信读书的登录 cookie，请确认网页里已经扫码成功"
            }
            val credential = WeReadCredential.fromCookie(normalized)
            val bridge =
                WeReadBridgeHolder.bridge
                    ?: throw IllegalStateException("微信读书模块没有接上，请更新到最新版本")
            check(bridge.adopt(credential.cookie)) {
                "Cookie 被拒绝：需要包含 wr_vid 与 wr_skey，且未过期"
            }
            context.onSuccess()
        }.onFailure {
            _state.value = state(error = it.message)
        }
    }

    override fun canResume(value: String): Boolean =
        WeReadCredential.normalize(value).contains("wr_vid=")

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

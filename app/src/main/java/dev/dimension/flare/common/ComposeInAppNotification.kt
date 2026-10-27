package dev.dimension.flare.common

import androidx.annotation.StringRes
import dev.dimension.flare.R
import dev.dimension.flare.data.repository.LoginExpiredException
import dev.dimension.flare.ui.presenter.login.ReloginTarget
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.koin.core.annotation.Single

internal sealed interface Notification {
    data class Progress(
        val progress: Int,
        val total: Int,
    ) : Notification {
        val percentage: Float
            get() = progress.toFloat() / total
    }

    data class StringNotification(
        @param:StringRes
        @field:StringRes
        val messageId: Int,
        val success: Boolean,
        val args: List<Any> = emptyList(),
        val reloginTarget: ReloginTarget? = null,
        // 平台返回的真实失败原因（如「微博转发失败：xxx」），用于替代只有一句「发布失败」的提示。
        val detail: String? = null,
    ) : Notification
}

@Single(binds = [InAppNotification::class])
internal class ComposeInAppNotification : InAppNotification {
    private val _source = MutableStateFlow(Event<Notification>(null, initialHandled = true))
    val source
        get() = _source.asStateFlow()

    override fun onProgress(
        message: Message,
        progress: Int,
        total: Int,
    ) {
        _source.value = Event(Notification.Progress(progress, total))
    }

    override fun onSuccess(message: Message) {
        _source.value = Event(Notification.StringNotification(message.successTitle, success = true))
    }

    fun message(
        @StringRes messageId: Int,
    ) {
        _source.value = Event(Notification.StringNotification(messageId, success = true))
    }

    override fun onError(
        message: Message,
        throwable: Throwable,
    ) {
        _source.value =
            Event(
                Notification.StringNotification(
                    message.errorTitle,
                    success = false,
                    args =
                        listOfNotNull(
                            if (throwable is LoginExpiredException) {
                                throwable.accountKey
                            } else {
                                null
                            },
                        ),
                    reloginTarget =
                        if (throwable is LoginExpiredException) {
                            ReloginTarget(
                                accountKey = throwable.accountKey,
                                platformId = throwable.platformId,
                            )
                        } else {
                            null
                        },
                    // 微博等平台把失败原因放在返回体里（ok=0 + msg），必须透出来，
                    // 否则用户只看到「发布失败」无法判断是风控、重复转发还是内容问题。
                    detail = throwable.message?.trim()?.takeIf { it.isNotEmpty() },
                ),
            )
    }
}

private val Message.successTitle
    get() =
        when (this) {
            Message.Compose -> R.string.compose_notification_success
            Message.LoginExpired -> R.string.notification_login_expired
        }

private val Message.errorTitle
    get() =
        when (this) {
            Message.Compose -> R.string.compose_notification_error
            Message.LoginExpired -> R.string.notification_login_expired
        }

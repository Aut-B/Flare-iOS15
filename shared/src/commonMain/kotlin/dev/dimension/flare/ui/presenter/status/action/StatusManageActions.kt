package dev.dimension.flare.ui.presenter.status.action

import dev.dimension.flare.data.datasource.microblog.datasource.PostDataSource
import dev.dimension.flare.data.repository.AccountRepository
import dev.dimension.flare.data.repository.accountServiceFlow
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * 自己发的帖子右上角「更多」菜单背后的操作：置顶 / 改可见范围。
 * 删除走 `DeleteStatusPresenter`。
 *
 * 这里刻意用 object 而不是 PresenterBase：菜单是点一下触发一次的动作，
 * 走 Presenter 得先等 molecule 合成出首帧、`models.value` 才有值，
 * 既慢又可能在首帧之前读到空值崩掉。
 *
 * 所有方法都通过 [onResult] 回报结果：`null` 表示成功，否则是失败原因。
 * 微博侧经常以 200 + `ok=0` 的形式返回「操作频繁」「没有权限」，
 * 不把原因带出来，用户点完菜单只会觉得「点了没反应」。
 */
public object StatusManageActions {
    private val scope: CoroutineScope by koinInject()
    private val accountRepository: AccountRepository by koinInject()

    public fun pin(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        pinned: Boolean,
        onResult: (String?) -> Unit,
    ) {
        perform(accountType, onResult) { it.postHandler.pinStatus(statusKey, pinned) }
    }

    public fun updateVisibility(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        visibility: UiTimelineV2.Post.Visibility,
        onResult: (String?) -> Unit,
    ) {
        perform(accountType, onResult) { it.postHandler.updateStatusVisibility(statusKey, visibility) }
    }

    private fun perform(
        accountType: AccountType,
        onResult: (String?) -> Unit,
        block: suspend (PostDataSource) -> Unit,
    ) {
        scope.launch {
            val error: String? =
                try {
                    val source =
                        accountServiceFlow(
                            accountType = accountType,
                            repository = accountRepository,
                        ).map {
                            require(it is PostDataSource) { "当前账号不支持这个操作" }
                            it
                        }.first()
                    block(source)
                    null
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (throwable: Throwable) {
                    throwable.message?.takeIf { it.isNotBlank() } ?: "操作失败，请稍后再试"
                }
            // 回调由 UI 侧切回主线程（common 层没有 Main dispatcher 的保证）。
            onResult(error)
        }
    }
}

package dev.dimension.flare.ui.presenter.status.action

import dev.dimension.flare.data.datasource.microblog.datasource.PostDataSource
import dev.dimension.flare.data.repository.AccountRepository
import dev.dimension.flare.data.repository.accountServiceFlow
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
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
 */
public object StatusManageActions {
    private val scope: CoroutineScope by koinInject()
    private val accountRepository: AccountRepository by koinInject()

    public fun pin(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        pinned: Boolean,
    ) {
        perform(accountType) { it.postHandler.pin(statusKey, pinned) }
    }

    public fun updateVisibility(
        accountType: AccountType,
        statusKey: MicroBlogKey,
        visibility: UiTimelineV2.Post.Visibility,
    ) {
        perform(accountType) { it.postHandler.updateVisibility(statusKey, visibility) }
    }

    private fun perform(
        accountType: AccountType,
        block: (PostDataSource) -> Unit,
    ) {
        scope.launch {
            accountServiceFlow(
                accountType = accountType,
                repository = accountRepository,
            ).map {
                require(it is PostDataSource)
                it
            }.first()
                .let(block)
        }
    }
}

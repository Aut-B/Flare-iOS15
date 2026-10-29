package dev.dimension.flare.ui.presenter.status.action

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import dev.dimension.flare.data.datasource.microblog.datasource.PostDataSource
import dev.dimension.flare.data.repository.AccountRepository
import dev.dimension.flare.data.repository.accountServiceFlow
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.presenter.PresenterBase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * 自己发的帖子右上角那个「更多」菜单背后的操作：
 * 置顶 / 好友可见 / 粉丝可见 / 仅自己可见（删除复用 DeleteStatusPresenter）。
 */
public class ManageStatusPresenter(
    private val accountType: AccountType,
    private val statusKey: MicroBlogKey,
) : PresenterBase<ManageStatusState>() {
    private val scope by koinInject<CoroutineScope>()
    private val accountRepository: AccountRepository by koinInject()

    @Composable
    override fun body(): ManageStatusState =
        object : ManageStatusState {
            override fun pin(pinned: Boolean) {
                perform { it.postHandler.pin(statusKey, pinned) }
            }

            override fun updateVisibility(visibility: UiTimelineV2.Post.Visibility) {
                perform { it.postHandler.updateVisibility(statusKey, visibility) }
            }

            private fun perform(block: (PostDataSource) -> Unit) {
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
}

@Immutable
public interface ManageStatusState {
    public fun pin(pinned: Boolean)

    public fun updateVisibility(visibility: UiTimelineV2.Post.Visibility)
}

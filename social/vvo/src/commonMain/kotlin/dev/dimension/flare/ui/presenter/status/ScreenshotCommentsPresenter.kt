package dev.dimension.flare.ui.presenter.status

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import dev.dimension.flare.data.datasource.vvo.VVODataSource
import dev.dimension.flare.data.repository.AccountService
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.presenter.PresenterBase
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.map

/**
 * 截图面板的评论列表：只取第一页热门评论，供用户勾选要截进图片的评论。
 * 非微博平台暂时返回空列表（截图本身仍然可用，只是没有评论可选）。
 *
 * 这里不用 UiState<T>，是因为 Swift 侧 StateView 要求泛型是 AnyObject，
 * 而 List 导出到 Swift 是数组（值类型），直接用会编译不过。
 */
@OptIn(ExperimentalCoroutinesApi::class)
public class ScreenshotCommentsPresenter(
    private val accountType: AccountType,
    private val statusKey: MicroBlogKey,
) : PresenterBase<ScreenshotCommentsState>() {
    private val accountService: AccountService by koinInject()

    private val flow =
        accountService
            .accountServiceFlow(accountType)
            .map { service ->
                val vvo = service as? VVODataSource
                if (vvo == null) {
                    ScreenshotCommentsData(emptyList(), null, false)
                } else {
                    runCatching { vvo.screenshotComments(statusKey) }.fold(
                        onSuccess = { ScreenshotCommentsData(it, null, false) },
                        onFailure = { ScreenshotCommentsData(emptyList(), it, false) },
                    )
                }
            }

    @Composable
    override fun body(): ScreenshotCommentsState {
        val state by flow.collectAsState(ScreenshotCommentsData(emptyList(), null, true))
        return object : ScreenshotCommentsState {
            override val comments: List<UiTimelineV2> = state.comments
            override val error: Throwable? = state.error
            override val isLoading: Boolean = state.loading
        }
    }
}

@Immutable
public interface ScreenshotCommentsState {
    public val comments: List<UiTimelineV2>
    public val error: Throwable?
    public val isLoading: Boolean
}

@Immutable
private data class ScreenshotCommentsData(
    val comments: List<UiTimelineV2>,
    val error: Throwable?,
    val loading: Boolean,
)

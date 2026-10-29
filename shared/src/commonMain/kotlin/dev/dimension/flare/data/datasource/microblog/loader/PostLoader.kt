package dev.dimension.flare.data.datasource.microblog.loader

import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlin.native.HiddenFromObjC

@HiddenFromObjC
public interface PostLoader {
    public suspend fun status(statusKey: MicroBlogKey): UiTimelineV2

    public suspend fun deleteStatus(statusKey: MicroBlogKey)

    /**
     * 置顶 / 取消置顶自己的帖子。
     * 默认实现直接抛错，只有支持该能力的平台（目前是微博）才覆盖。
     */
    public suspend fun pinStatus(
        statusKey: MicroBlogKey,
        pinned: Boolean,
    ) {
        throw UnsupportedOperationException("pin is not supported on this platform")
    }

    /** 修改已发帖子的可见范围，默认不支持。 */
    public suspend fun updateStatusVisibility(
        statusKey: MicroBlogKey,
        visibility: UiTimelineV2.Post.Visibility,
    ) {
        throw UnsupportedOperationException("visibility is not supported on this platform")
    }
}

package dev.dimension.flare.data.datasource.xiaohongshu

import dev.dimension.flare.data.datasource.microblog.loader.RelationActionType
import dev.dimension.flare.data.datasource.microblog.loader.RelationLoader
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiRelation

/**
 * 小红书的「关系」能力：什么都没有。
 *
 * 关注 / 拉黑这些写操作要 `X-S` 签名，宿主（`XhsBridge`）只实现了笔记相关的几个请求。
 * 但 `ProfilePresenter` 里写的是 `require(service is RelationDataSource)`，
 * 不实现就会在打开个人主页的瞬间抛异常 —— 表现就是点「我的主页」直接闪退。
 *
 * 所以给一个空实现：关系恒为默认值（没关注、没拉黑），写操作直接忽略。
 * `supportedTypes` 为空集，UI 上就不会出现关注 / 拉黑按钮。
 */
internal object XhsRelationLoader : RelationLoader {
    override val supportedTypes: Set<RelationActionType> = emptySet()

    override suspend fun relation(userKey: MicroBlogKey): UiRelation = UiRelation()

    override suspend fun follow(userKey: MicroBlogKey) = Unit

    override suspend fun unfollow(userKey: MicroBlogKey) = Unit

    override suspend fun block(userKey: MicroBlogKey) = Unit

    override suspend fun unblock(userKey: MicroBlogKey) = Unit

    override suspend fun mute(userKey: MicroBlogKey) = Unit

    override suspend fun unmute(userKey: MicroBlogKey) = Unit
}

package dev.dimension.flare.data.datasource.instagram

import dev.dimension.flare.data.datasource.microblog.loader.RelationActionType
import dev.dimension.flare.data.datasource.microblog.loader.RelationLoader
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiRelation

/**
 * Instagram 的「关系」能力：暂时什么都不做。
 *
 * 关注 / 取关在网页接口里是 POST + `X-CSRFToken`，和发帖同一套写权限，
 * 还没接。但 `ProfilePresenter` 里写的是 `require(service is RelationDataSource)`，
 * 不实现就会在打开个人主页时抛异常闪退。
 *
 * 关系恒为默认值，`supportedTypes` 为空集 —— UI 上不会出现关注按钮。
 */
internal object InstagramRelationLoader : RelationLoader {
    override val supportedTypes: Set<RelationActionType> = emptySet()

    override suspend fun relation(userKey: MicroBlogKey): UiRelation = UiRelation()

    override suspend fun follow(userKey: MicroBlogKey) = Unit

    override suspend fun unfollow(userKey: MicroBlogKey) = Unit

    override suspend fun block(userKey: MicroBlogKey) = Unit

    override suspend fun unblock(userKey: MicroBlogKey) = Unit

    override suspend fun mute(userKey: MicroBlogKey) = Unit

    override suspend fun unmute(userKey: MicroBlogKey) = Unit
}

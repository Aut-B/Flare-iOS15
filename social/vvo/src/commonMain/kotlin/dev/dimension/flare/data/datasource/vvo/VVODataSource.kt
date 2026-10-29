package dev.dimension.flare.data.datasource.vvo

import androidx.paging.ExperimentalPagingApi
import dev.dimension.flare.common.CacheData
import dev.dimension.flare.common.FileItem
import dev.dimension.flare.common.MemCacheable
import dev.dimension.flare.common.decodeJson
import dev.dimension.flare.data.datasource.microblog.AuthenticatedMicroblogDataSource
import dev.dimension.flare.data.datasource.microblog.ComposeConfig
import dev.dimension.flare.data.datasource.microblog.ComposeData
import dev.dimension.flare.data.datasource.microblog.ComposeDataSource
import dev.dimension.flare.data.datasource.microblog.ComposeType
import dev.dimension.flare.data.datasource.microblog.DatabaseUpdater
import dev.dimension.flare.data.datasource.microblog.NotificationFilter
import dev.dimension.flare.data.datasource.microblog.NotificationTimelineDataSource
import dev.dimension.flare.data.datasource.microblog.PostEvent
import dev.dimension.flare.data.datasource.microblog.ProfileTab
import dev.dimension.flare.data.datasource.microblog.datasource.NotificationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.PostDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.RelationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.TimelineTabConfigurationDataSource
import dev.dimension.flare.data.datasource.microblog.datasource.UserDataSource
import dev.dimension.flare.data.datasource.microblog.handler.EmojiHandler
import dev.dimension.flare.data.datasource.microblog.handler.NotificationHandler
import dev.dimension.flare.data.datasource.microblog.handler.PostEventHandler
import dev.dimension.flare.data.datasource.microblog.handler.PostHandler
import dev.dimension.flare.data.datasource.microblog.handler.RelationHandler
import dev.dimension.flare.data.datasource.microblog.handler.UserHandler
import dev.dimension.flare.data.datasource.microblog.paging.PagingRequest
import dev.dimension.flare.data.datasource.microblog.paging.PagingResult
import dev.dimension.flare.data.datasource.microblog.paging.RemoteLoader
import dev.dimension.flare.data.model.IconType
import dev.dimension.flare.data.model.tab.ShortcutSpec
import dev.dimension.flare.data.model.tab.TimelineSpec
import dev.dimension.flare.data.network.vvo.VVOService
import dev.dimension.flare.data.network.vvo.model.StatusDetailItem
import dev.dimension.flare.data.network.vvo.model.VVOResponse
import dev.dimension.flare.data.platform.CommonTimelineSpecs
import dev.dimension.flare.data.platform.VVO_PLATFORM_ID
import dev.dimension.flare.data.platform.VVoCredential
import dev.dimension.flare.data.platform.VvoPlatformSpec
import dev.dimension.flare.data.repository.LoginExpiredException
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.shared.image.ImageCompressor
import dev.dimension.flare.ui.model.UiHashtag
import dev.dimension.flare.ui.model.UiIcon
import dev.dimension.flare.ui.model.UiProfile
import dev.dimension.flare.ui.model.UiState
import dev.dimension.flare.ui.model.UiStrings
import dev.dimension.flare.ui.model.UiText
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.model.mapper.render
import dev.dimension.flare.ui.model.toUi
import dev.dimension.flare.ui.presenter.compose.ComposeStatus
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update

private val MEDIA_COMPRESSION =
    ComposeConfig.Media.Compression(
        maxSizeBytes = 5L * 1024 * 1024,
        maxWidth = 4096,
        maxHeight = 4096,
    )

/** 评论兜底缓存的上限与保留量。 */
private const val COMMENT_CACHE_LIMIT = 800
private const val COMMENT_CACHE_KEEP = 600

@OptIn(ExperimentalPagingApi::class)
internal class VVODataSource(
    override val accountKey: MicroBlogKey,
    credentialFlow: Flow<VVoCredential>,
    private val updateCredential: suspend (VVoCredential) -> Unit = {},
) : AuthenticatedMicroblogDataSource,
    NotificationTimelineDataSource,
    ComposeDataSource,
    NotificationDataSource,
    UserDataSource,
    RelationDataSource,
    TimelineTabConfigurationDataSource,
    PostDataSource,
    PostEventHandler.Handler {
    private val imageCompressor: ImageCompressor by koinInject()
    private val service by lazy {
        VVOService(
            credentialFlow = credentialFlow,
            refreshCookieWhenStale = true,
            onCredentialRefreshed = { credential ->
                updateCredential(credential)
            },
        )
    }

    private val loader by lazy {
        VVOLoader(
            accountKey = accountKey,
            service = service,
        )
    }

    private val notificationBadgeStore: VVONotificationBadgeStore by lazy {
        VVONotificationBadgeStore(loader) { total ->
            notificationHandler.update(total)
        }
    }

    override val defaultTabs by lazy {
        persistentListOf(
            CommonTimelineSpecs.home
                .candidate(
                    data = TimelineSpec.AccountBasedData(accountKey),
                    icon = IconType.Material(UiIcon.Weibo),
                    title = UiText.Raw("Weibo"),
                ),
        )
    }

    override val builtInTimelineTabs by lazy {
        persistentListOf(
            CommonTimelineSpecs.home.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.Weibo),
            ),
            CommonTimelineSpecs.discover.candidate(
                data = TimelineSpec.AccountBasedData(accountKey),
                icon = IconType.Material(UiIcon.Weibo),
            ),
            VvoPlatformSpec.favoriteTimelineSpec.candidate(TimelineSpec.AccountBasedData(accountKey)),
            VvoPlatformSpec.likedTimelineSpec.candidate(TimelineSpec.AccountBasedData(accountKey)),
        )
    }

    override val shortcuts by lazy {
        persistentListOf(
            ShortcutSpec(
                title = UiStrings.Featured,
                icon = UiIcon.Featured,
                target =
                    ShortcutSpec.Target.Timeline(
                        CommonTimelineSpecs.discover.candidate(TimelineSpec.AccountBasedData(accountKey)),
                    ),
            ),
            ShortcutSpec(
                title = UiStrings.Bookmark,
                icon = UiIcon.Bookmark,
                target =
                    ShortcutSpec.Target.Timeline(
                        VvoPlatformSpec.favoriteTimelineSpec.candidate(TimelineSpec.AccountBasedData(accountKey)),
                    ),
            ),
            ShortcutSpec(
                title = UiStrings.Liked,
                icon = UiIcon.Heart,
                target =
                    ShortcutSpec.Target.Timeline(
                        VvoPlatformSpec.likedTimelineSpec.candidate(TimelineSpec.AccountBasedData(accountKey)),
                    ),
            ),
        )
    }

    private val emojiHandler by lazy {
        EmojiHandler(
            host = accountKey.host,
            loader = loader,
        )
    }

    override val notificationHandler: NotificationHandler by lazy {
        NotificationHandler(
            accountKey = accountKey,
            loader = loader,
            fetchBadgeCount = {
                notificationBadgeStore.refreshAndGetTotal()
            },
        )
    }

    override val userHandler by lazy {
        UserHandler(
            host = accountKey.host,
            loader = loader,
        )
    }

    override val postHandler by lazy {
        PostHandler(
            accountType = AccountType.Specific(accountKey),
            loader = loader,
        )
    }

    override val relationHandler by lazy {
        RelationHandler(
            dataSource = loader,
            accountType = AccountType.Specific(accountKey),
        )
    }

    override val supportedRelationTypes: Set<dev.dimension.flare.data.datasource.microblog.loader.RelationActionType>
        get() = loader.supportedTypes

    override val postEventHandler by lazy {
        PostEventHandler(
            accountType = AccountType.Specific(accountKey),
            handler = this,
        )
    }

    override suspend fun handle(
        event: PostEvent,
        updater: DatabaseUpdater,
    ) {
        require(event is PostEvent.VVO)
        when (event) {
            is PostEvent.VVO.Favorite -> favorite(event)
            is PostEvent.VVO.Like -> like(event)
            is PostEvent.VVO.LikeComment -> likeComment(event)
        }
    }

    override fun homeTimeline() =
        HomeTimelineRemoteMediator(
            service = service,
            accountKey = accountKey,
        )

    override fun notification(type: NotificationFilter): RemoteLoader<UiTimelineV2> =
        when (type) {
            NotificationFilter.All -> {
                MentionRemoteMediator(
                    service = service,
                    accountKey = accountKey,
                    onClearMarker = {
                        notificationBadgeStore.clearAll()
                    },
                )
            }

            NotificationFilter.Mention -> {
                MentionRemoteMediator(
                    service = service,
                    accountKey = accountKey,
                    onClearMarker = {
                        notificationBadgeStore.clear(NotificationFilter.Mention)
                    },
                )
            }

            NotificationFilter.Comment -> {
                CommentPagingSource(
                    service = service,
                    accountKey = accountKey,
                    onClearMarker = {
                        notificationBadgeStore.clear(NotificationFilter.Comment)
                    },
                )
            }

            NotificationFilter.Like -> {
                LikePagingSource(
                    service = service,
                    accountKey = accountKey,
                    onClearMarker = {
                        notificationBadgeStore.clear(NotificationFilter.Like)
                    },
                )
            }
        }

    override val supportedNotificationFilter: List<NotificationFilter>
        get() =
            listOf(
                NotificationFilter.Mention,
                NotificationFilter.Comment,
                NotificationFilter.Like,
            )

    override fun userTimeline(
        userKey: MicroBlogKey,
        mediaOnly: Boolean,
    ) = UserTimelineRemoteMediator(
        userKey = userKey,
        service = service,
        accountKey = accountKey,
        mediaOnly = mediaOnly,
    )

    override fun context(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        object : RemoteLoader<UiTimelineV2> {
            override suspend fun load(
                pageSize: Int,
                request: PagingRequest,
            ): PagingResult<UiTimelineV2> {
                when (request) {
                    is PagingRequest.Prepend,
                    is PagingRequest.Append,
                    -> {
                        return PagingResult(
                            endOfPaginationReached = true,
                        )
                    }

                    PagingRequest.Refresh -> {}
                }

                val status = loadStatusDetail(statusKey)
                val comments =
                    service
                        .getHotComments(
                            id = statusKey.id,
                            mid = statusKey.id,
                            maxId = null,
                        ).data
                        ?.data
                        .orEmpty()
                        .map { it.render(accountKey) }

                return PagingResult(
                    endOfPaginationReached = true,
                    data = listOf(status) + comments,
                )
            }
        }

    override fun searchStatus(query: String) =
        SearchStatusRemoteMediator(
            service = service,
            accountKey = accountKey,
            query = query,
        )

    override fun searchUser(query: String): RemoteLoader<UiProfile> =
        SearchUserPagingSource(
            service = service,
            accountKey = accountKey,
            query = query,
        )

    override fun discoverUsers(): RemoteLoader<UiProfile> =
        object : RemoteLoader<UiProfile> {
            override suspend fun load(
                pageSize: Int,
                request: PagingRequest,
            ): PagingResult<UiProfile> =
                PagingResult(
                    endOfPaginationReached = true,
                )
        }

    override fun discoverStatuses() =
        DiscoverStatusRemoteMediator(
            service = service,
            accountKey = accountKey,
        )

    override fun discoverHashtags(): RemoteLoader<UiHashtag> =
        TrendHashtagPagingSource(
            accountKey = accountKey,
            service = service,
        )

    override fun following(userKey: MicroBlogKey): RemoteLoader<UiProfile> =
        FollowingPagingSource(
            service = service,
            userKey = userKey,
            accountKey = accountKey,
        )

    override fun fans(userKey: MicroBlogKey): RemoteLoader<UiProfile> =
        FansPagingSource(
            service = service,
            userKey = userKey,
            accountKey = accountKey,
        )

    override suspend fun profileTabs(userKey: MicroBlogKey): ImmutableList<ProfileTab> =
        persistentListOf(
            ProfileTab(
                name = UiStrings.Posts,
                loader = userTimeline(userKey, false),
            ),
        )

    override suspend fun publish(
        data: ComposeData,
        progress: () -> Unit,
    ) {
        val st = ensureWriteLogin()

        val mediaIds =
            data.medias.mapIndexed { index, (it, _) ->
                uploadMedia(it, st).also {
                    progress()
                }
            }
        val mediaId = mediaIds.joinToString(",")
        val referenceStatus = data.referenceStatus
        val composeStatus = referenceStatus?.composeStatus
        // 可见范围始终传合法值（0 公开 / 1 仅自己 / 6 互相关注 / 10 仅粉丝），
        // 避免 null 被序列化成非法值后整条请求被判异常。
        val visible = data.visibility.toVvoVisible()
        try {
            if (composeStatus is ComposeStatus.VVOComment) {
                service.replyComment(
                    cid = composeStatus.statusKey.id,
                    reply = composeStatus.statusKey.id,
                    id = composeStatus.rootId,
                    mid = composeStatus.rootId,
                    content = data.content,
                    st = st,
                    picId = mediaId,
                )
            } else if (composeStatus is ComposeStatus.Reply) {
                service.commentStatus(
                    id = composeStatus.statusKey.id,
                    content = data.content,
                    st = st,
                    picId = mediaId,
                )
            } else if (composeStatus is ComposeStatus.Quote) {
                service.repostStatus(
                    id = composeStatus.statusKey.id,
                    // 纯转发保持空内容，由微博服务端生成「转发微博」。
                    // 之前客户端塞固定文案「转发微博」，连续转发时内容完全一致，
                    // 会被当成重复内容刷屏，是「操作频繁」的诱因之一。
                    content = data.content,
                    st = st,
                    picId = mediaId,
                    visible = visible,
                ).requireSuccess("转发")
            } else {
                service.updateStatus(
                    content = data.content,
                    st = st,
                    picId = mediaId,
                    visible = visible,
                ).requireSuccess("发布")
            }
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: LoginExpiredException) {
            throw error
        } catch (error: Exception) {
            // 写失败常见原因是 st / 登录态过期，清缓存让下一次读取重新校验。
            service.invalidateConfigCache()
            throw error
        }
    }

    override fun composeConfig(type: ComposeType): ComposeConfig =
        ComposeConfig(
            text = ComposeConfig.Text(2000),
            media =
                ComposeConfig.Media(
                    if (type == ComposeType.New) 18 else 1,
                    false,
                    altTextMaxLength = -1,
                    allowMediaOnly = false,
                    compression = MEDIA_COMPRESSION,
                ),
            // 微博的可见范围：公开 / 仅自己可见 / 互相关注 / 仅粉丝可见。
            // 评论（Reply）没有可见范围概念，因此只在发博和转发时提供。
            visibility =
                if (type == ComposeType.Reply) {
                    null
                } else {
                    ComposeConfig.Visibility(
                        allVisibilities =
                            persistentListOf(
                                UiTimelineV2.Post.Visibility.Public,
                                UiTimelineV2.Post.Visibility.Private,
                                UiTimelineV2.Post.Visibility.Mutual,
                                UiTimelineV2.Post.Visibility.Followers,
                            ),
                        defaultVisibility = UiTimelineV2.Post.Visibility.Public,
                    )
                },
            emoji =
                ComposeConfig.Emoji(
                    emoji = emojiHandler.emoji,
                    mergeTag = "vvo@${accountKey.host}",
                    accountKey = accountKey,
                ),
        )

    private suspend fun like(event: PostEvent.VVO.Like) {
        val st = ensureWriteLogin()
        if (event.liked) {
            service.unlikeStatus(id = event.postKey.id, st = st)
        } else {
            service.likeStatus(id = event.postKey.id, st = st)
        }
    }

    private suspend fun likeComment(event: PostEvent.VVO.LikeComment) {
        val st = ensureWriteLogin()
        if (event.liked) {
            service.likesDestroy(id = event.postKey.id, st = st)
        } else {
            service.likesUpdate(id = event.postKey.id, st = st)
        }
    }

    private suspend fun favorite(event: PostEvent.VVO.Favorite) {
        val st = ensureWriteLogin()
        if (event.favorited) {
            service.unfavoriteStatus(id = event.postKey.id, st = st)
        } else {
            service.favoriteStatus(id = event.postKey.id, st = st)
        }
    }

    fun favouriteTimeline() =
        FavouriteRemoteMediator(
            service = service,
            accountKey = accountKey,
        )

    fun likeRemoteMediator() =
        LikeRemoteMediator(
            service = service,
            accountKey = accountKey,
        )

    fun statusComment(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        StatusCommentRemoteMediator(
            service = service,
            accountKey = accountKey,
            statusKey = statusKey,
            onRendered = ::cacheComments,
        )

    /**
     * 截图面板用：一次性取第一页热门评论。
     * 这里不走 Pager，只是给「挑选要截进图片的评论」提供一个列表。
     */
    suspend fun screenshotComments(statusKey: MicroBlogKey): List<UiTimelineV2> =
        service
            .getHotComments(
                id = statusKey.id,
                mid = statusKey.id,
                maxId = null,
            ).data
            ?.data
            .orEmpty()
            .map { it.render(accountKey) }

    fun statusRepost(statusKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        StatusRepostRemoteMediator(
            service = service,
            accountKey = accountKey,
            statusKey = statusKey,
        )

    fun commentChild(commentKey: MicroBlogKey): RemoteLoader<UiTimelineV2> =
        CommentChildRemoteMediator(
            service = service,
            accountKey = accountKey,
            commentKey = commentKey,
            onRendered = ::cacheComments,
        )

    /**
     * 最近渲染过的评论（id -> 评论本身）。
     *
     * 微博的 `comments/hotFlowChild` 在「这条评论没有任何回复」时不会返回 rootComment，
     * 导致点进 0 回复的评论只会看到 `status not found`。而这条评论其实刚刚在列表里
     * 渲染过，所以这里留一份内存缓存做兜底：先查缓存，缓存没有再去请求。
     *
     * 放在 companion 里是因为 DataSource 实例会随订阅重建，缓存要跨实例共享。
     */
    internal fun cacheComments(items: List<UiTimelineV2>) {
        if (items.isEmpty()) return
        commentCache.update { current ->
            val merged = current + items.associateBy { it.statusKey.id }
            // 只保留最近的一批，避免长时间使用后无限增长。
            if (merged.size <= COMMENT_CACHE_LIMIT) {
                merged
            } else {
                merged.entries
                    .drop(merged.size - COMMENT_CACHE_KEEP)
                    .associate { it.key to it.value }
            }
        }
    }

    fun comment(statusKey: MicroBlogKey): CacheData<UiTimelineV2> =
        MemCacheable("vvo_comment_${accountKey}_$statusKey") {
            // 0 回复的评论拿不到 rootComment，属于正常情况，不要把异常抛出去。
            // 但要放行 CancellationException，否则协程取消会被吞掉。
            val remote =
                try {
                    service
                        .getHotFlowChild(statusKey.id)
                        .rootComment
                        ?.firstOrNull()
                        ?.render(accountKey)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    null
                }
            remote
                ?: commentCache.value[statusKey.id]
                ?: throw Exception("status not found")
        }

    private companion object {
        /**
         * 评论兜底缓存（评论 id -> 渲染好的评论），跨 DataSource 实例共享，
         * 见 [cacheComments]。
         */
        val commentCache = MutableStateFlow<Map<String, UiTimelineV2>>(emptyMap())
    }

    fun statusExtendedText(statusKey: MicroBlogKey): Flow<UiState<String>> =
        MemCacheable(
            "status_extended_text_$statusKey",
        ) {
            val st = ensureLogin()
            val response = service.getStatusExtend(statusKey.id, st)
            response.data?.longTextContent.orEmpty()
        }.toUi()

    fun status(statusKey: MicroBlogKey): Flow<UiState<UiTimelineV2>> =
        MemCacheable(
            "vvo_status_$statusKey",
        ) {
            loadStatusDetail(statusKey)
        }.toUi()

    private suspend fun uploadMedia(
        fileItem: FileItem,
        st: String,
    ): String {
        val media = fileItem.uploadMedia()
        require(!media.isVideo) { "Weibo video uploads are not supported" }
        media.validate("Weibo")
        val response =
            service.uploadPic(
                st = st,
                media = media.compressImage(imageCompressor, MEDIA_COMPRESSION),
            )
        return response.picID ?: throw Exception("upload failed")
    }

    /**
     * 写操作专用：先续签 Cookie 再取 st。
     * 微博的 SUB 只在 passport 的 SSO 跳转链里重新签名，旧 SUB 读接口还能用，
     * 写接口会被风控直接拦下（「转发频繁」/「操作频繁」）。
     */
    private suspend fun ensureWriteLogin(): String {
        service.refreshCredentialForWrite()
        return ensureLogin()
    }

    private suspend fun ensureLogin(): String {
        val config = service.config()
        if (config.data?.login != true) {
            throw LoginExpiredException(
                accountKey = accountKey,
                platformId = VVO_PLATFORM_ID,
            )
        }
        return requireNotNull(config.data.st) { "st is null" }
    }

    private suspend fun loadStatusDetail(statusKey: MicroBlogKey): UiTimelineV2 {
        val regex =
            "\\\$render_data\\s*=\\s*(\\[\\{.*?\\}\\])\\[0\\]\\s*\\|\\|\\s*\\{\\};".toRegex()
        val response =
            service
                .getStatusDetail(statusKey.id)
                .split("\n")
                .joinToString("")
        val json =
            regex
                .find(response)
                ?.groupValues
                ?.get(1)
                ?.decodeJson<List<StatusDetailItem>>()
                ?: throw Exception("status not found")

        return json.firstOrNull()?.status?.render(accountKey) ?: throw Exception("status not found")
    }
}

/**
 * 微博「谁可以看」对应的 visible 值（与网页版 / App 一致）：
 * 0 公开、1 仅自己可见、6 互相关注（好友圈）、10 仅粉丝可见。
 * 始终返回合法值，不返回 null，避免表单里出现空值/非法值。
 */
internal fun UiTimelineV2.Post.Visibility.toVvoVisible(): String =
    when (this) {
        UiTimelineV2.Post.Visibility.Private -> "1"
        UiTimelineV2.Post.Visibility.Mutual -> "6"
        UiTimelineV2.Post.Visibility.Followers -> "10"
        // 公开，以及微博没有对应语义的取值，统一按公开处理
        UiTimelineV2.Post.Visibility.Public,
        UiTimelineV2.Post.Visibility.Home,
        UiTimelineV2.Post.Visibility.Specified,
        UiTimelineV2.Post.Visibility.Channel -> "0"
    }

/**
 * 微博接口失败时 ok=0，之前直接当成功处理，于是「点了发送但主页没有帖子」。
 * 这里把失败显式抛出来，让 UI 显示错误而不是静默吞掉。
 */
private fun VVOResponse<*>.requireSuccess(action: String) {
    val failed = ok == 0L || (ok == null && data == null)
    if (!failed) return
    val detail =
        msg?.takeIf { it.isNotBlank() }
            ?: httpCode?.let { "HTTP $it" }
            ?: "ok=$ok"
    throw Exception("微博${action}失败：$detail")
}

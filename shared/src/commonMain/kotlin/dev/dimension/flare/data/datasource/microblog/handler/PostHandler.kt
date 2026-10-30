package dev.dimension.flare.data.datasource.microblog.handler

import dev.dimension.flare.common.Cacheable
import dev.dimension.flare.data.database.cache.CacheDatabase
import dev.dimension.flare.data.database.cache.connect
import dev.dimension.flare.data.database.cache.mapper.saveToDatabase
import dev.dimension.flare.data.database.cache.model.DbStatus
import dev.dimension.flare.data.database.cache.model.TranslationDisplayOptions
import dev.dimension.flare.data.datasource.microblog.loader.PostLoader
import dev.dimension.flare.data.datasource.microblog.paging.TimelinePagingMapper
import dev.dimension.flare.data.datastore.AppDataStore
import dev.dimension.flare.data.repository.tryRun
import dev.dimension.flare.data.translation.PreTranslationService
import dev.dimension.flare.data.translation.TranslationSettingsSupport
import dev.dimension.flare.di.koinInject
import dev.dimension.flare.model.AccountType
import dev.dimension.flare.model.DbAccountType
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlin.native.HiddenFromObjC

@HiddenFromObjC
public class PostHandler(
    public val accountType: AccountType,
    public val loader: PostLoader,
) {
    private val database: CacheDatabase by koinInject()
    private val coroutineScope: CoroutineScope by koinInject()
    private val appDataStore: AppDataStore by koinInject()
    private val preTranslationService: PreTranslationService by koinInject()

    private val translationDisplayFlow by lazy {
        TranslationSettingsSupport.displayOptionsFlow(appDataStore)
    }

    public fun post(
        postKey: MicroBlogKey,
        translationDisplay: PostTranslationDisplay = PostTranslationDisplay.UserSettings,
    ): Cacheable<UiTimelineV2> {
        val pagingKey = "post_only_$postKey"
        return Cacheable(
            fetchSource = {
                val result = loader.status(postKey)
                database.connect {
                    val item =
                        TimelinePagingMapper.toDb(
                            result,
                            pagingKey,
                        )
                    saveToDatabase(database, listOf(item))
                    preTranslationService.enqueueStatuses(
                        listOfNotNull(item.status.status.data) + item.status.references.mapNotNull { it.status?.data },
                        allowLongText = true,
                    )
                }
            },
            cacheSource = {
                val dbAccountType = accountType as DbAccountType
                combine(
                    database
                        .statusDao()
                        .getWithReferences(postKey, dbAccountType),
                    database
                        .pagingTimelineDao()
                        .get(pagingKey, accountType = dbAccountType),
                    translationDisplay.optionsFlow(translationDisplayFlow),
                ) { status, timelineStatus, translationDisplayOptions ->
                    timelineStatus?.let {
                        TimelinePagingMapper.toUi(
                            item = it,
                            pagingKey = pagingKey,
                            translationDisplayOptions = translationDisplayOptions,
                        )
                    } ?: status?.let {
                        TimelinePagingMapper.toUi(
                            item = it,
                            pagingKey = pagingKey,
                            translationDisplayOptions = translationDisplayOptions,
                        )
                    }
                }.filterNotNull()
                    .distinctUntilChanged()
            },
        )
    }

    public fun delete(postKey: MicroBlogKey): Job =
        coroutineScope.launch {
            tryRun {
                loader.deleteStatus(postKey)
            }.onSuccess {
                database.connect {
                    val dbAccountType = accountType as DbAccountType
                    database.pagingTimelineDao().deleteStatus(
                        accountType = dbAccountType,
                        statusId = DbStatus.createId(dbAccountType, postKey),
                    )
                    database.statusDao().delete(
                        statusKey = postKey,
                        accountType = dbAccountType,
                    )
                    database.statusReferenceDao().delete(DbStatus.createId(dbAccountType, postKey))
                }
            }
        }

    /** 置顶 / 取消置顶自己的帖子（微博）。 */
    public fun pin(
        postKey: MicroBlogKey,
        pinned: Boolean,
    ): Job =
        coroutineScope.launch {
            tryRun {
                loader.pinStatus(postKey, pinned)
            }
        }

    /** 修改已发帖子的可见范围（微博）。 */
    public fun updateVisibility(
        postKey: MicroBlogKey,
        visibility: UiTimelineV2.Post.Visibility,
    ): Job =
        coroutineScope.launch {
            tryRun {
                loader.updateStatusVisibility(postKey, visibility)
            }
        }

    /**
     * 与 [pin] 相同，但把异常抛给调用方。
     *
     * 右上角菜单需要「成功/失败」的即时反馈：`tryRun` 会把微博返回的
     * 「操作频繁」「没有权限」之类的原因吞掉，用户点完只能干瞪眼。
     */
    public suspend fun pinStatus(
        postKey: MicroBlogKey,
        pinned: Boolean,
    ) {
        loader.pinStatus(postKey, pinned)
    }

    /** 与 [updateVisibility] 相同，但把异常抛给调用方。 */
    public suspend fun updateStatusVisibility(
        postKey: MicroBlogKey,
        visibility: UiTimelineV2.Post.Visibility,
    ) {
        loader.updateStatusVisibility(postKey, visibility)
    }

    /** 取可编辑的纯文本正文，用来预填编辑框。异常抛给调用方。 */
    public suspend fun editableContent(postKey: MicroBlogKey): String = loader.editableContent(postKey)

    /**
     * 编辑已发布的帖子正文，成功后就地刷新本地缓存。
     *
     * 不刷新的话，改完切回列表看到的还是旧正文 —— 正文存在 `status` 表里，
     * 所有时间线都是 join 这张表，所以重新存一遍这条就能让各处同时变新。
     */
    public suspend fun editStatus(
        postKey: MicroBlogKey,
        content: String,
    ) {
        loader.editStatus(postKey, content)
        runCatching {
            val result = loader.status(postKey)
            database.connect {
                val item = TimelinePagingMapper.toDb(result, "post_only_$postKey")
                saveToDatabase(database, listOf(item))
            }
        }
    }
}

@HiddenFromObjC
public enum class PostTranslationDisplay {
    UserSettings,
    Original,
}

private fun PostTranslationDisplay.optionsFlow(userSettingsFlow: Flow<TranslationDisplayOptions>): Flow<TranslationDisplayOptions> =
    when (this) {
        PostTranslationDisplay.UserSettings -> {
            userSettingsFlow
        }

        PostTranslationDisplay.Original -> {
            flowOf(
                TranslationDisplayOptions(
                    translationEnabled = false,
                    autoDisplayEnabled = false,
                    providerCacheKey = "",
                ),
            )
        }
    }

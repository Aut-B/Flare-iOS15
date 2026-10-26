package dev.dimension.flare.data.datasource.vvo

import androidx.paging.ExperimentalPagingApi
import dev.dimension.flare.data.datasource.microblog.paging.CacheableRemoteLoader
import dev.dimension.flare.data.datasource.microblog.paging.PagingRequest
import dev.dimension.flare.data.datasource.microblog.paging.PagingResult
import dev.dimension.flare.data.network.vvo.VVOService
import dev.dimension.flare.data.platform.VVO_PLATFORM_ID
import dev.dimension.flare.data.repository.LoginExpiredException
import dev.dimension.flare.model.MicroBlogKey
import dev.dimension.flare.ui.model.UiTimelineV2
import dev.dimension.flare.ui.model.mapper.render
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

@OptIn(ExperimentalPagingApi::class)
internal class HomeTimelineRemoteMediator(
    private val service: VVOService,
    private val accountKey: MicroBlogKey,
) : CacheableRemoteLoader<UiTimelineV2> {
    override val canJoinTimeline: Boolean = true
    override val pagingKey: String = "home_$accountKey"

    override suspend fun load(
        pageSize: Int,
        request: PagingRequest,
    ): PagingResult<UiTimelineV2> =
        coroutineScope {
            if (request is PagingRequest.Prepend) {
                ensureLoggedIn()
                return@coroutineScope PagingResult(
                    endOfPaginationReached = true,
                )
            }

            // 登录态校验（api/config）和时间线请求互不依赖，并发发出。
            // config() 命中 10 分钟缓存时几乎没有开销；冷启动或 Cookie 过期时
            // 能省掉一次完整的串行往返（弱网下就是 1~2 秒）。
            val configDeferred = async { service.config() }
            val responseDeferred =
                async {
                    when (request) {
                        PagingRequest.Refresh -> {
                            service.getFriendsTimeline()
                        }

                        is PagingRequest.Append -> {
                            service.getFriendsTimeline(
                                maxId = request.nextKey,
                            )
                        }

                        is PagingRequest.Prepend -> error("handled above")
                    }
                }

            val config = configDeferred.await()
            if (config.data?.login != true) {
                responseDeferred.cancel()
                throw LoginExpiredException(
                    accountKey = accountKey,
                    platformId = VVO_PLATFORM_ID,
                )
            }

            val response = responseDeferred.await()

            PagingResult(
                endOfPaginationReached = response.data?.nextCursorStr == null,
                data =
                    response.data
                        ?.statuses
                        .orEmpty()
                        .map { it.render(accountKey) },
                nextKey = response.data?.nextCursorStr,
            )
        }

    private suspend fun ensureLoggedIn() {
        val config = service.config()
        if (config.data?.login != true) {
            throw LoginExpiredException(
                accountKey = accountKey,
                platformId = VVO_PLATFORM_ID,
            )
        }
    }
}

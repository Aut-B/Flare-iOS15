package dev.dimension.flare.data.network.vvo.api

import de.jensklingenberg.ktorfit.http.Field
import de.jensklingenberg.ktorfit.http.FormUrlEncoded
import de.jensklingenberg.ktorfit.http.GET
import de.jensklingenberg.ktorfit.http.Header
import de.jensklingenberg.ktorfit.http.POST
import de.jensklingenberg.ktorfit.http.Path
import de.jensklingenberg.ktorfit.http.Query
import dev.dimension.flare.data.network.vvo.model.Comment
import dev.dimension.flare.data.network.vvo.model.Status
import dev.dimension.flare.data.network.vvo.model.StatusExtend
import dev.dimension.flare.data.network.vvo.model.VVOResponse
import kotlinx.serialization.json.JsonElement

internal interface StatusApi {
    @GET("statuses/extend")
    suspend fun getStatusExtend(
        @Query("id") id: String,
        @Header("X-Xsrf-Token") xsrfToken: String,
    ): VVOResponse<StatusExtend>

    @GET("detail/{id}")
    suspend fun getStatusDetail(
        @Path("id") id: String,
    ): String

    @POST("api/statuses/update")
    @FormUrlEncoded
    suspend fun updateStatus(
        @Field("content") content: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
        // 0 公开 / 1 仅自己可见 / 6 互相关注 / 10 仅粉丝可见
        @Field("visible") visible: String = "0",
        @Field("picId") picId: String? = null,
    ): VVOResponse<Status>

    @POST("api/statuses/repost")
    @FormUrlEncoded
    suspend fun repostStatus(
        @Field("id") id: String,
        @Field("content") content: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
        @Field("picId") picId: String? = null,
        @Field("mid") mid: String = id,
        // 0 公开 / 1 仅自己可见 / 6 互相关注 / 10 仅粉丝可见
        @Field("visible") visible: String = "0",
    ): VVOResponse<Status>

    @POST("api/comments/create")
    @FormUrlEncoded
    suspend fun commentStatus(
        @Field("id") id: String,
        @Field("content") content: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
        @Field("picId") picId: String? = null,
        @Field("mid") mid: String = id,
    ): VVOResponse<Comment>

    @POST("api/comments/reply")
    @FormUrlEncoded
    suspend fun replyComment(
        @Field("id") id: String,
        @Field("cid") cid: String,
        @Field("content") content: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
        @Field("picId") picId: String? = null,
        @Field("mid") mid: String = id,
        @Field("reply") reply: String = cid,
    ): VVOResponse<Comment>

    @POST("profile/delMyblog")
    @FormUrlEncoded
    suspend fun deleteStatus(
        @Field("mid") mid: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    /** 置顶 / 取消置顶自己的微博。top=1 置顶，top=0 取消。 */
    @POST("profile/setTop")
    @FormUrlEncoded
    suspend fun setTopStatus(
        @Field("id") id: String,
        @Field("top") top: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    /** 修改已发微博的可见范围：0 公开 / 1 仅自己可见 / 6 好友圈 / 10 仅粉丝可见。 */
    @POST("statuses/updateVisibility")
    @FormUrlEncoded
    suspend fun updateVisibility(
        @Field("id") id: String,
        @Field("visibility") visibility: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    @POST("comments/destroy")
    @FormUrlEncoded
    suspend fun deleteComment(
        @Field("cid") cid: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    @POST("api/attitudes/create")
    @FormUrlEncoded
    suspend fun likeStatus(
        @Field("id") id: String,
        @Field("st") st: String,
        @Field("attitude") attitude: String = "heart",
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    @POST("api/attitudes/destroy")
    @FormUrlEncoded
    suspend fun unlikeStatus(
        @Field("id") id: String,
        @Field("st") st: String,
        @Field("attitude") attitude: String = "heart",
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    @POST("api/likes/update")
    @FormUrlEncoded
    suspend fun likesUpdate(
        @Field("id") id: String,
        @Field("st") st: String,
        @Field("type") type: String = "comment",
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<JsonElement>

    @POST("api/likes/destroy")
    @FormUrlEncoded
    suspend fun likesDestroy(
        @Field("id") id: String,
        @Field("st") st: String,
        @Field("type") type: String = "comment",
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<JsonElement>

    @POST("api/statuses/createfav")
    @FormUrlEncoded
    suspend fun favoriteStatus(
        @Field("id") id: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>

    @POST("api/statuses/destroyfav")
    @FormUrlEncoded
    suspend fun unfavoriteStatus(
        @Field("id") id: String,
        @Field("st") st: String,
        @Header("X-Xsrf-Token") xsrfToken: String = st,
    ): VVOResponse<String>
}

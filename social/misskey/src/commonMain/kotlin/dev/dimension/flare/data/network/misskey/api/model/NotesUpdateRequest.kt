package dev.dimension.flare.data.network.misskey.api.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * `notes/update` 的请求体。
 *
 * 只带 [noteId] 和 [text]：CW、可见性、附件省略时由服务端沿用原值，
 * 带上反而可能因为字段缺失把原值清掉。
 *
 * Misskey 从 2023.11 起才允许改正文（此前只允许改 CW），更老的实例会返回
 * `text is not allowed` 之类的错误 —— 这个错误会原样带到 UI 上，用户能看懂。
 */
@Serializable
internal data class NotesUpdateRequest(
    @SerialName("noteId")
    val noteId: String,
    @SerialName("text")
    val text: String,
)

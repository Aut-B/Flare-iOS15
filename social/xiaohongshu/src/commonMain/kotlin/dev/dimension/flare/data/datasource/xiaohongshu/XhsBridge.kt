package dev.dimension.flare.data.datasource.xiaohongshu

/**
 * 小红书的数据桥。
 *
 * 小红书的接口要 `X-S` / `X-T`，这两个值由网页里的 `window._webmsxyw` 算出来，
 * 纯 Kotlin 没法复现（算法在混淆 JS 里，而且随版本变）。所以把「拿数据」这件事
 * 交给宿主实现：iOS 侧有一个隐藏的 WKWebView 常驻网页版，在里面调 `_webmsxyw`。
 *
 * 返回的都是 JSON 字符串，结构见 [XhsJsonContract]。
 */
public interface XhsBridge {
    /**
     * 首页流。`follow == true` 取关注流，否则是推荐流。
     *
     * 返回 `{"items":[...],"next":"cursor"}`。
     */
    public suspend fun homeFeed(
        cookie: String,
        cursor: String?,
        follow: Boolean,
    ): String

    /** 单条笔记详情，返回一个笔记对象。 */
    public suspend fun note(
        cookie: String,
        id: String,
    ): String

    /** 用户主页的笔记列表，返回 `{"items":[...],"next":"cursor"}`。 */
    public suspend fun userNotes(
        cookie: String,
        userId: String,
        cursor: String?,
    ): String
}

/**
 * 宿主（Swift / 未来的 Android）在启动时把实现塞进来。
 *
 * 没有实现时所有请求都会抛错，UI 上会显示「当前平台不支持」，
 * 而不是静默白屏。
 */
public object XhsBridgeHolder {
    public var bridge: XhsBridge? = null
}

/**
 * JSON 契约。宿主只需要吐这些字段，Kotlin 侧负责映射成 `UiTimelineV2`。
 *
 * ```
 * 笔记：
 * {
 *   "id": "65f0...",
 *   "title": "标题",
 *   "desc": "正文",
 *   "user": { "id": "5f2...", "name": "昵称", "avatar": "https://..." },
 *   "images": ["https://...", "https://..."],
 *   "likedCount": "1.2万",
 *   "isVideo": false,
 *   "aspect": 0.75
 * }
 * 列表：{ "items": [笔记...], "next": "cursor 或 null" }
 * ```
 */
public object XhsJsonContract

import Foundation

/// 书架里的一本书。
struct WereadBook: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let cover: String?
    /// 0-100，接口给的是 0-100 的整数，没读过是 0。
    /// 书架里 books 和 bookProgress 是两份数据，合并时会被改写。
    var progress: Int
    let finished: Bool
    /// 最近阅读时间（秒级时间戳），0 = 从没打开过。
    /// 书架默认就按这个倒序排 —— 网页版也是「最近读过」在最前面。
    var updatedAt: TimeInterval = 0
    /// 网页书架上的分组名（「默认分组」「想读」这些），空串 = 没分组。
    var group: String = ""
}

/// 目录里的一章。
struct WereadChapter: Identifiable, Hashable {
    let uid: Int
    let index: Int
    let title: String
    let level: Int
    let wordCount: Int
    /// 官方目录里的译文版本；未翻译章节为 0。字段缺失时也只能当 0。
    let translateVersion: Int

    var id: Int { uid }
}

/// 一本书的阅读进度，用来「接着上次读」。
struct WereadProgress: Hashable {
    let chapterUid: Int
    let chapterOffset: Int
    let percent: Int
}

/// 微读服务端同步下来的一条划线，可能带着用户写的想法。
///
/// 字段来源是 `/web/book/bookmarklist` 的 `updated[]`：
/// `bookmarkId / chapterUid / markText / range / createTime`。
/// 想法不在这个接口里，由 `/web/review/list` 按 `range` 关联（见
/// `WereadService.bookmarks(bookId:cookie:)`）。
struct WereadBookmark: Identifiable, Hashable {
    let id: String
    let chapterUid: Int
    let markText: String
    let note: String
    let range: String
    let createTime: TimeInterval
}

enum WereadError: LocalizedError {
    case notLoggedIn
    case http(Int)
    case empty
    case decodeFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "微信读书登录已过期，请在「微信读书」页面重新扫码登录"
        case .http(let code):
            return "请求失败（HTTP \(code)）"
        case .empty:
            // 正文接口回空/`{}` 的典型原因是会话信标不对，其次是书本身不给读。
            // 文案要把「可以重试」和「可能要付费」都说清楚，别让用户干等。
            return "没能取到本章正文。可能是阅读会话已过期（下拉刷新或重试一次），也可能是这本书需要付费"
        case .decodeFailed:
            return "内容解析失败"
        case .server(let message):
            return message
        }
    }
}

/// 官方翻译开关的确认结果。译文本身不进入 Swift 侧，
/// 这里只记录官方有没有明确接受请求。
enum WereadTranslationAck: Equatable {
    /// 官方回包里有明确成功字段。
    case accepted
    /// 2xx 但没有明确成功字段：只能算「已发送、未确认」。
    case uncertain(String)
    /// 官方明确拒绝（风控、权益、参数等）。
    case rejected(String)
}

/// 一次 `/web/book/enRead` 触发/轮询的状态。
///
/// 官方以 `curStatus` 里当前章节的 `translateVersion` 大于章节原版本作为
/// 译文已生成信号，对应 `completed`；`stop` 只表示官方让停止轮询，不等于
/// 一定有译文。无论哪种状态，最终都要去当前章节正文里数
/// `.wr-translation` 节点，节点为 0 不能算成功。
struct WereadTranslationTrigger: Equatable {
    enum State: Equatable {
        /// 本轮还没看到当前章节的版本增长，继续轮询。
        case pending
        /// `curStatus` 显示当前章节译文已生成。
        case completed
        /// 官方要求停止轮询。
        case stop
    }

    let state: State
    /// 回包里能确认的当前章节最新版本（顶层或 `curStatus`）。
    let translateVersion: Int?
    let tip: String?
}

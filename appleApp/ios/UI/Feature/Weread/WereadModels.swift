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

    var id: Int { uid }
}

/// 一本书的阅读进度，用来「接着上次读」。
struct WereadProgress: Hashable {
    let chapterUid: Int
    let chapterOffset: Int
    let percent: Int
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

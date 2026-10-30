import Foundation

/// 书架里的一本书。
struct WereadBook: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let cover: String?
    /// 0-100，接口给的是 0-100 的整数，没读过是 0。
    let progress: Int
    let finished: Bool
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
            return "微信读书登录已失效，请在「微信读书」页面重新登录"
        case .http(let code):
            return "请求失败（HTTP \(code)）"
        case .empty:
            return "内容为空，可能是这本书需要付费或接口已变更"
        case .decodeFailed:
            return "内容解析失败"
        case .server(let message):
            return message
        }
    }
}

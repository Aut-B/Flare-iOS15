import Foundation

/// 书架的一个分组区块。
struct WereadShelfSection: Identifiable, Hashable {
    let id: String
    let title: String
    let books: [WereadBook]
}

/// 书架的排序与分组。
///
/// 这两段以前直接写在 `WereadShelfView` 里，是纯数据变换，跟 SwiftUI 没关系。
/// 抽出来是为了能在单元测试里跑：书架顺序错了、分组丢了，CI 直接变红，
/// 不用等装到手机上才发现。
enum WereadShelfSections {
    /// 按最近阅读倒序。`updatedAt` 全是 0 的老数据保持接口原顺序，
    /// 免得「一升级顺序全乱」。
    static func sorted(_ books: [WereadBook]) -> [WereadBook] {
        books
            .enumerated()
            .sorted { left, right in
                if left.element.updatedAt == right.element.updatedAt {
                    return left.offset < right.offset
                }
                return left.element.updatedAt > right.element.updatedAt
            }
            .map { $0.element }
    }

    /// 线上书架的分组（`shelf/sync` 里的 `bookGroups`）。
    /// 一个分组都认不出来就平铺，不硬造「最近阅读 / 全部」这种假分组。
    static func make(_ books: [WereadBook]) -> [WereadShelfSection] {
        let sorted = sorted(books)
        var order: [String] = []
        var buckets: [String: [WereadBook]] = [:]
        for book in sorted where !book.group.isEmpty {
            if buckets[book.group] == nil { order.append(book.group) }
            buckets[book.group, default: []].append(book)
        }
        var result = order.map { name in
            WereadShelfSection(id: name, title: name, books: buckets[name] ?? [])
        }
        let ungrouped = sorted.filter { $0.group.isEmpty }
        if !ungrouped.isEmpty {
            if result.isEmpty {
                result = [WereadShelfSection(id: "__all__", title: "", books: ungrouped)]
            } else {
                result.append(WereadShelfSection(id: "__ungrouped__", title: "未分组", books: ungrouped))
            }
        }
        return result
    }
}
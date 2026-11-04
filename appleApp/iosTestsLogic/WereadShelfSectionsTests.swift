import XCTest

/// 微信读书书架的排序与分组测试。
///
/// 用户看到的问题是「书架不按最近读过排序」「线上书架的分组没了」。
/// 这两件事全在 `WereadShelfSections` 里，纯数据变换，可以脱离界面直接测。
final class WereadShelfSectionsTests: XCTestCase {
    private func book(
        _ id: String,
        updatedAt: TimeInterval = 0,
        group: String = ""
    ) -> WereadBook {
        WereadBook(
            id: id,
            title: id,
            author: "",
            cover: nil,
            progress: 0,
            finished: false,
            updatedAt: updatedAt,
            group: group
        )
    }

    func testSortedByRecentlyReadDescending() {
        let books = [
            book("old", updatedAt: 100),
            book("newest", updatedAt: 300),
            book("middle", updatedAt: 200),
        ]

        XCTAssertEqual(
            WereadShelfSections.sorted(books).map(\.id),
            ["newest", "middle", "old"]
        )
    }

    func testEqualTimestampsKeepServerOrder() {
        let books = [book("a"), book("b"), book("c")]

        XCTAssertEqual(WereadShelfSections.sorted(books).map(\.id), ["a", "b", "c"])
    }

    func testGroupsFollowFirstAppearanceInSortedOrder() {
        let books = [
            book("x", updatedAt: 100, group: "想读"),
            book("y", updatedAt: 300, group: "默认分组"),
            book("z", updatedAt: 200, group: "想读"),
        ]

        let sections = WereadShelfSections.make(books)

        XCTAssertEqual(sections.map(\.title), ["默认分组", "想读"])
        XCTAssertEqual(sections.first?.books.map(\.id), ["y"])
        XCTAssertEqual(sections.last?.books.map(\.id), ["z", "x"])
    }

    func testUngroupedOnlyShelfIsASingleSection() {
        let books = [book("a", updatedAt: 10), book("b", updatedAt: 20)]

        let sections = WereadShelfSections.make(books)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "__all__")
        XCTAssertEqual(sections.first?.title, "")
        XCTAssertEqual(sections.first?.books.map(\.id), ["b", "a"])
    }

    func testUngroupedBooksAreAppendedAsLastSection() {
        let books = [
            book("grouped", updatedAt: 100, group: "默认分组"),
            book("loose", updatedAt: 200),
        ]

        let sections = WereadShelfSections.make(books)

        XCTAssertEqual(sections.map(\.title), ["默认分组", "未分组"])
        XCTAssertEqual(sections.last?.books.map(\.id), ["loose"])
    }

    func testEmptyShelfHasNoSections() {
        XCTAssertTrue(WereadShelfSections.make([]).isEmpty)
    }
}
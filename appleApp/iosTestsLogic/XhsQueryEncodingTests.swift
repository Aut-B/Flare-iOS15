import XCTest

/// 小红书评论 query 编码的回归测试。
///
/// 评论打不开的时候，界面上只会显示服务端那句「当前笔记暂时无法浏览」，
/// 看不出究竟是 token 过期、来源不匹配，还是 query 编码不对。这三个原因里
/// 只有「编码」能在不联网的前提下锁死，所以这里把它钉住。
///
/// 被测的是 `XhsQuery`：它不依赖 UIKit/WebKit，能被这个纯逻辑测试目标
/// 直接编译进来。`XhsService` 那边的同名函数只做转发。
final class XhsQueryEncodingTests: XCTestCase {
    // MARK: - 值编码

    /// 逗号必须编码成 `%2C`。
    ///
    /// `CharacterSet.urlQueryAllowed` 本身包含 `,`，所以不手动移出白名单的话
    /// `encode("jpg,webp")` 会原样返回。签名用的是这条 query 原文，
    /// 编码和网页版不一致时算出来的 `X-S` 就和服务端重算的结果对不上。
    func testCommaIsPercentEncoded() {
        XCTAssertEqual(XhsQuery.encode("jpg,webp"), "jpg%2Cwebp")
    }

    func testSemicolonIsPercentEncoded() {
        // 分号同理在 urlQueryAllowed 白名单里，不能漏。
        XCTAssertEqual(XhsQuery.encode("a;b"), "a%3Bb")
    }

    func testQuerySeparatorsAreEncoded() {
        // 这些符号出现在值里必须编码，否则会被当成 query 语法拆开。
        XCTAssertEqual(XhsQuery.encode("a&b"), "a%26b")
        XCTAssertEqual(XhsQuery.encode("a=b"), "a%3Db")
        XCTAssertEqual(XhsQuery.encode("a+b"), "a%2Bb")
        XCTAssertEqual(XhsQuery.encode("a?b"), "a%3Fb")
    }

    func testPlainValueSurvivesEncoding() {
        // note_id / token 都是 [0-9a-zA-Z] 加少量符号，不能被改坏。
        XCTAssertEqual(XhsQuery.encode("65f0a1b2c3d4e5f60718293a"), "65f0a1b2c3d4e5f60718293a")
    }

    // MARK: - 评论 query

    func testCommentQueryAlwaysCarriesEncodedImageFormats() {
        let query = XhsQuery.commentQuery(
            noteId: "note1",
            xsecToken: "tok",
            cursor: nil,
            xsecSource: "pc_note"
        )

        XCTAssertTrue(query.contains("image_formats=jpg%2Cwebp"), query)
        // 回归点：不编码时这里会是 `image_formats=jpg,webp`。
        XCTAssertFalse(query.contains("image_formats=jpg,webp"), query)
    }

    func testCommentQueryIncludesXsecSource() {
        let query = XhsQuery.commentQuery(
            noteId: "note1",
            xsecToken: "tok",
            cursor: nil,
            xsecSource: "pc_user"
        )

        // 少了 xsec_source 服务端一律回「来源不明」。
        XCTAssertTrue(query.contains("xsec_source=pc_user"), query)
    }

    func testCommentQueryOmitsEmptyToken() {
        let query = XhsQuery.commentQuery(
            noteId: "note1",
            xsecToken: "",
            cursor: nil,
            xsecSource: "pc_feed"
        )

        // 公开笔记的 token 本来就可能为空，空 token 是合法请求，不能拼出
        // 一个 `xsec_token=` 空参数。
        XCTAssertFalse(query.contains("xsec_token="), query)
    }

    func testCommentQueryCarriesCursorForPaging() {
        let query = XhsQuery.commentQuery(
            noteId: "note1",
            xsecToken: "tok",
            cursor: "abc123",
            xsecSource: "pc_feed"
        )

        XCTAssertTrue(query.contains("cursor=abc123"), query)
    }

    func testEmptyCursorStillProducesCursorKey() {
        // 首页光标为空是常态，这个键必须还在（只是值为空）。
        let query = XhsQuery.commentQuery(
            noteId: "note1",
            xsecToken: "tok",
            cursor: nil,
            xsecSource: "pc_feed"
        )

        XCTAssertTrue(query.contains("cursor=&") || query.hasSuffix("cursor="), query)
    }
}

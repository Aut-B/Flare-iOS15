import XCTest

/// 小红书首页流状态判定的回归测试。
///
/// build131 的 461 响应体是 `{"code":0,"success":true,"msg":"成功","data":{}}`：
/// 只看业务 code 会把「服务端拒绝」误判成「这一页没有内容」，界面就停在
/// 0 条、`hasMore` 还留着 true，看起来像一次成功的空列表。这些用例把
/// 「能不能继续翻页」和「首屏该显示什么」钉住，不联网、不需要真机。
///
/// 被测的是 `XhsFeedState`：它不依赖 UIKit/WebKit，会被这个纯逻辑测试
/// 目标直接编译进来。`XhsStore` 那边只做状态转发。
final class XhsFeedStateTests: XCTestCase {
    // MARK: - 翻页状态

    /// 「成功但 0 条」不是最后一页的证明，也不是「还有下一页」的证明，
    /// 但绝不能继续声称还有内容。
    func testEmptySuccessDoesNotKeepPaging() {
        XCTAssertFalse(XhsFeedState.hasMore(after: .empty))
    }

    func testContentKeepsPaging() {
        XCTAssertTrue(XhsFeedState.hasMore(after: .content))
    }

    func testRejectedStopsPaging() {
        XCTAssertFalse(XhsFeedState.hasMore(after: .rejected(code: 461)))
        XCTAssertFalse(XhsFeedState.hasMore(after: .rejected(code: -1)))
    }

    // MARK: - 文案

    /// 接口层已经生成的 461 / 登录态不完整文案必须原样保留，
    /// 不能被网页兜底的通用文案盖掉。
    func testRestrictionMessageWinsOverFallback() {
        let restriction =
            "小红书服务端风控/人机验证（HTTP 461），客户端无法绕过。去网页版完成验证后再回来"
        let message = XhsFeedState.message(
            for: .empty,
            restriction: restriction,
            detail: nil,
            fallback: "页面打开了但没抓到首页数据。点「重试」"
        )

        XCTAssertEqual(message, restriction)
    }

    /// 回归点：以前 code 0 + 空 data 会静默 return，用户只看到
    /// 「页面打开了但没抓到首页数据」。现在必须说出「成功但 0 条」。
    func testEmptySuccessMessageIsNotGenericFallback() {
        let fallback = "页面打开了但没抓到首页数据。点「重试」"
        let message = XhsFeedState.message(
            for: .empty,
            restriction: nil,
            detail: nil,
            fallback: fallback
        )

        XCTAssertNotEqual(message, fallback)
        XCTAssertFalse(message.contains("没抓到首页数据"), message)
        XCTAssertTrue(message.contains("0 条"), message)
        XCTAssertTrue(message.contains("风控"), message)
        XCTAssertTrue(message.contains("登录态"), message)
    }

    func testRejectedMessageCarriesCodeAndDetail() {
        let message = XhsFeedState.message(
            for: .rejected(code: 461),
            restriction: nil,
            detail: "需要验证",
            fallback: "兜底"
        )

        XCTAssertTrue(message.contains("461"), message)
        XCTAssertTrue(message.contains("需要验证"), message)
    }

    func testRejectedMessageWithoutDetailStillCarriesCode() {
        let message = XhsFeedState.message(
            for: .rejected(code: -1),
            restriction: nil,
            detail: nil,
            fallback: "兜底"
        )

        XCTAssertTrue(message.contains("-1"), message)
        XCTAssertNotEqual(message, "兜底")
    }
}

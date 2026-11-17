import XCTest

/// Instagram 媒体解析的回归测试。
///
/// 对应真机上反复出现的两类问题：
/// 1. 多图轮播（carousel）里横竖图混排时，后面几张按首图的比例被裁歪；
/// 2. 纯视频帖没有 `image_versions2`，整条帖子在时间线里消失。
///
/// 全部是纯 JSON → 模型，不联网、不需要账号，所以能放进 LogicTests 天天跑。
final class InstagramMediaParsingTests: XCTestCase {
    private func image(_ url: String, width: Int = 1080, height: Int = 1080) -> [String: Any] {
        [
            "image_versions2": [
                "candidates": [
                    ["url": url, "width": width, "height": height]
                ]
            ]
        ]
    }

    private func media(_ extra: [String: Any]) -> [String: Any] {
        var raw: [String: Any] = [
            "pk": "123",
            "id": "123_456",
            "code": "abc",
            "user": ["pk": "u1", "username": "tester"],
            "taken_at": 1_700_000_000,
            "like_count": 10,
            "comment_count": 2,
        ]
        for (key, value) in extra { raw[key] = value }
        return raw
    }

    // MARK: - 纯视频帖

    /// 纯视频帖只给 `video_versions` + `image_versions2`（封面）。
    /// 以前解析把 `bestImageInfo` 当门槛，没有 `image_versions2` 的会整条丢掉。
    func testVideoOnlyPostIsNotDropped() {
        var raw = media([
            "media_type": 2,
            "video_versions": [
                ["url": "https://cdn.example/v.mp4", "width": 720, "height": 1280]
            ],
        ])
        // 刻意不给 image_versions2：模拟只有视频流的情况。
        raw.removeValue(forKey: "image_versions2")

        let parsed = IGJSON.media(raw)

        XCTAssertNotNil(parsed, "纯视频帖不应被丢弃")
        XCTAssertEqual(parsed?.videoURL, "https://cdn.example/v.mp4")
        XCTAssertEqual(parsed?.items.count, 1)
        XCTAssertEqual(parsed?.items.first?.video, "https://cdn.example/v.mp4")
        XCTAssertTrue(parsed?.isVideo == true)
    }

    /// 没有封面时 aspect 必须落成 1，不能是 0 —— 0 会让 aspectRatio 算出
    /// 无限高或除零。
    func testVideoOnlyPostWithoutCoverFallsBackToSquareAspect() {
        var raw = media([
            "media_type": 2,
            "video_versions": [["url": "https://cdn.example/v.mp4", "width": 720, "height": 1280]],
        ])
        raw.removeValue(forKey: "image_versions2")

        XCTAssertEqual(IGJSON.media(raw)?.aspect, 1)
    }

    // MARK: - 多图轮播

    /// carousel 里每一项都要带自己的比例：横图后面跟竖图时，
    /// 用首图比例去渲染会把竖图裁掉一截。
    func testCarouselKeepsPerItemAspect() {
        let raw = media([
            "media_type": 8,
            "carousel_media": [
                image("https://cdn.example/wide.jpg", width: 1080, height: 608),
                image("https://cdn.example/tall.jpg", width: 1080, height: 1350),
            ],
        ])

        let parsed = IGJSON.media(raw)

        XCTAssertEqual(parsed?.items.count, 2)
        let wide = parsed?.items.first?.aspect ?? 0
        let tall = parsed?.items.last?.aspect ?? 0
        // 1080/608 ≈ 1.78（被上限夹到 2 以内），1080/1350 = 0.8
        XCTAssertEqual(wide, 1.7763157, accuracy: 0.01)
        XCTAssertEqual(tall, 0.8, accuracy: 0.01)
        XCTAssertNotEqual(wide, tall, "每一项必须保留自己的比例")
    }

    /// carousel 里的视频项同样要能解析出来，并且和图片项共存。
    func testCarouselWithVideoItemKeepsBoth() {
        let raw = media([
            "media_type": 8,
            "carousel_media": [
                image("https://cdn.example/1.jpg"),
                [
                    "pk": "child2",
                    "media_type": 2,
                    "video_versions": [["url": "https://cdn.example/v.mp4", "width": 720, "height": 1280]],
                ],
            ],
        ])

        let parsed = IGJSON.media(raw)

        XCTAssertEqual(parsed?.items.count, 2)
        XCTAssertEqual(parsed?.items.first?.isVideo, false)
        XCTAssertEqual(parsed?.items.last?.isVideo, true)
        XCTAssertEqual(parsed?.videoURL, "https://cdn.example/v.mp4")
        XCTAssertTrue(parsed?.isCarousel == true)
    }

    /// carousel 全是图片时 `videoURL` 必须是 nil，不能误报成视频帖。
    func testImageCarouselIsNotVideo() {
        let raw = media([
            "media_type": 8,
            "carousel_media": [
                image("https://cdn.example/1.jpg"),
                image("https://cdn.example/2.jpg"),
            ],
        ])

        let parsed = IGJSON.media(raw)

        XCTAssertNil(parsed?.videoURL)
        XCTAssertFalse(parsed?.isVideo == true)
    }

    // MARK: - 单图

    func testSingleImagePostStillParses() {
        let raw = media([
            "media_type": 1,
            "image_versions2": [
                "candidates": [["url": "https://cdn.example/a.jpg", "width": 800, "height": 800]]
            ],
        ])

        let parsed = IGJSON.media(raw)

        XCTAssertEqual(parsed?.images, ["https://cdn.example/a.jpg"])
        XCTAssertEqual(parsed?.items.count, 1)
        XCTAssertNil(parsed?.videoURL)
    }

    /// 既没有图也没有视频（纯文字/异常数据）才该丢。
    func testPostWithoutAnyMediaIsDropped() {
        let raw = media(["media_type": 1])

        XCTAssertNil(IGJSON.media(raw))
    }
}

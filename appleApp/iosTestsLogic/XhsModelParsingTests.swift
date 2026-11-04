import XCTest

/// 小红书 JSON → 模型的解析测试。
///
/// 这些用例对应真机上反复出现的问题：一条笔记明明有好几张图，界面上只显示第一张；
/// 图片是 `http://` 被 ATS 拦掉变成灰块；视频笔记拿不到直链。
/// 全部是纯解析，不联网、不需要账号，所以能放进 CI 天天跑。
final class XhsModelParsingTests: XCTestCase {
    private func image(
        _ url: String,
        width: Int = 1080,
        height: Int = 1440
    ) -> [String: Any] {
        ["url_default": url, "width": width, "height": height]
    }

    private func notePayload(
        images: [[String: Any]]?,
        cover: [String: Any]? = nil,
        title: String = "标题",
        video: [String: Any]? = nil
    ) -> [String: Any] {
        var card: [String: Any] = [
            "note_id": "note-1",
            "title": title,
            "desc": "正文",
            "user": ["user_id": "u1", "nickname": "阿猫", "image": "https://img.example/u1.jpg"],
            "interact_info": ["liked_count": "1.2万", "comment_count": "33"],
        ]
        if let images { card["image_list"] = images }
        if let cover { card["cover"] = cover }
        if let video {
            card["type"] = "video"
            card["video"] = video
        }
        return ["id": "note-1", "model_type": "note", "note_card": card]
    }

    // MARK: - 多图

    func testNoteKeepsEveryImageInList() {
        let payload = notePayload(images: [
            image("https://img.example/a.jpg"),
            image("https://img.example/b.jpg"),
            image("https://img.example/c.jpg"),
            image("https://img.example/d.jpg"),
        ])

        let note = XhsJSON.note(payload)

        XCTAssertEqual(note?.images.count, 4)
        XCTAssertEqual(note?.images.first, "https://img.example/a.jpg")
        XCTAssertEqual(note?.images.last, "https://img.example/d.jpg")
        XCTAssertEqual(note?.cover, "https://img.example/a.jpg")
    }

    func testNoteFallsBackToCoverWhenImageListMissing() {
        let payload = notePayload(images: nil, cover: image("https://img.example/cover.jpg"))

        XCTAssertEqual(XhsJSON.note(payload)?.images, ["https://img.example/cover.jpg"])
    }

    func testNoteWithoutAnyImageIsDropped() {
        XCTAssertNil(XhsJSON.note(notePayload(images: nil)))
    }

    // MARK: - 图片地址

    func testImageURLPrefersJPEGOverAVIF() {
        let info: [String: Any] = [
            "url_default": "https://img.example/a.avif",
            "info_list": [["url": "https://img.example/b.jpg"]],
        ]

        XCTAssertEqual(XhsJSON.imageURL(info)?.url, "https://img.example/b.jpg")
    }

    func testImageURLUpgradesHTTPToHTTPS() {
        let info: [String: Any] = ["url_default": "http://sns-webpic.example/a.jpg"]

        XCTAssertEqual(XhsJSON.imageURL(info)?.url, "https://sns-webpic.example/a.jpg")
    }

    func testProtocolRelativeImageURLGetsScheme() {
        XCTAssertEqual(
            XhsNote.normalizedImageURL("//sns-webpic.example/a.jpg"),
            "https://sns-webpic.example/a.jpg"
        )
    }

    func testAspectIsClampedToSaneRange() {
        let wide = notePayload(images: [image("https://img.example/a.jpg", width: 4000, height: 100)])
        let tall = notePayload(images: [image("https://img.example/a.jpg", width: 100, height: 4000)])

        XCTAssertEqual(XhsJSON.note(wide)?.aspect, 2.0)
        XCTAssertEqual(XhsJSON.note(tall)?.aspect, 0.5)
    }

    // MARK: - 视频

    func testVideoURLPrefersH264MasterURL() {
        let video: [String: Any] = [
            "media": [
                "stream": [
                    "h265": [["master_url": "https://v.example/h265.mp4"]],
                    "h264": [["master_url": "https://v.example/h264.mp4"]],
                ],
            ],
        ]
        let payload = notePayload(images: [image("https://img.example/a.jpg")], video: video)

        let note = XhsJSON.note(payload)

        XCTAssertEqual(note?.isVideo, true)
        XCTAssertEqual(note?.videoURL, "https://v.example/h264.mp4")
    }

    func testVideoURLFallsBackToBackupURLs() {
        let video: [String: Any] = [
            "media": [
                "stream": [
                    "h264": [["backup_urls": ["https://v.example/backup.mp4"]]],
                ],
            ],
        ]
        let payload = notePayload(images: [image("https://img.example/a.jpg")], video: video)

        XCTAssertEqual(XhsJSON.note(payload)?.videoURL, "https://v.example/backup.mp4")
    }

    func testNonVideoNoteHasNoVideoURL() {
        let payload = notePayload(images: [image("https://img.example/a.jpg")])

        XCTAssertEqual(XhsJSON.note(payload)?.isVideo, false)
        XCTAssertNil(XhsJSON.note(payload)?.videoURL)
    }

    // MARK: - 评论 / 资料

    func testCommentKeepsSubComments() {
        let payload: [String: Any] = [
            "id": "c1",
            "content": "顶",
            "user_info": ["user_id": "u2", "nickname": "路人"],
            "sub_comments": [
                ["id": "c1-1", "content": "回复1", "user_info": ["user_id": "u3", "nickname": "B"]],
                ["id": "c1-2", "content": "回复2", "user_info": ["user_id": "u4", "nickname": "C"]],
            ],
            "sub_comment_count": 2,
        ]

        let comment = XhsJSON.comment(payload)

        XCTAssertEqual(comment?.subComments.count, 2)
        XCTAssertEqual(comment?.subCount, 2)
        XCTAssertEqual(comment?.subComments.first?.user.name, "B")
    }

    func testProfileFindsNestedBasicInfo() {
        let payload: [String: Any] = [
            "data": [
                "basic_info": [
                    "user_id": "u1",
                    "nickname": "阿猫",
                    "interactions": [
                        ["type": "fans", "count": "120"],
                        ["type": "follows", "count": "8"],
                    ],
                ],
            ],
        ]

        let profile = XhsJSON.profile(payload)

        XCTAssertEqual(profile?.name, "阿猫")
        XCTAssertEqual(profile?.fans, "120")
        XCTAssertEqual(profile?.follows, "8")
    }

    func testCountTextKeepsChineseSuffix() {
        XCTAssertEqual(XhsJSON.countText("1.2万"), "1.2万")
        XCTAssertEqual(XhsJSON.countText(0), "")
        XCTAssertEqual(XhsJSON.countText(42), "42")
    }

    // MARK: - 标题

    func testDisplayTitleFallsBackToFirstLineOfDesc() {
        let payload = notePayload(images: [image("https://img.example/a.jpg")], title: "")
        let note = XhsJSON.note(payload)

        XCTAssertEqual(note?.displayTitle, "正文")
    }
}
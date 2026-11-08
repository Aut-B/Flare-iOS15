import XCTest

final class InstagramCrashRecoveryUITests: XCTestCase {
    @MainActor
    func testCorruptInstagramStateStillLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--seed-corrupt-instagram")
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "Bad Instagram state crashed cold start")
        Thread.sleep(forTimeInterval: 30)
        XCTAssertEqual(app.state, .runningForeground, "App exited within 30 seconds")

        app.terminate()
        let appRelaunch = XCUIApplication()
        appRelaunch.launch()
        XCTAssertEqual(
            appRelaunch.state,
            .runningForeground,
            "Instagram state was rehydrated or crashed the second cold start"
        )
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(
            appRelaunch.state,
            .runningForeground,
            "App exited shortly after the second cold start"
        )

        let attachment = XCTAttachment(screenshot: appRelaunch.screenshot())
        attachment.name = "corrupt-instagram-launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

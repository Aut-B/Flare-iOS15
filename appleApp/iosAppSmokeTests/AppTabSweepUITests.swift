import XCTest

/// 真机 UI 冒烟：启动 App → 逐个点底部 tab → 每步留截图。
///
/// 这里不校验任何业务数据（CI 里没有账号、也不该依赖外网），只回答三个问题：
/// 1. 启动后 90 秒内还在前台吗（拦「一开机就闪退」）；
/// 2. 切到每个标签页会不会崩（拦「点标签页就退出」）；
/// 3. 每个标签页长什么样（截图随 artifact 上传，不用装到手机上也能看）。
final class AppTabSweepUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testTabSweepKeepsAppAlive() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "启动 90 秒内没有进入前台")

        let started = Date()
        Thread.sleep(forTimeInterval: 8)
        attachScreenshot(app, name: "00-launch")
        attachText(app.debugDescription, name: "00-launch-hierarchy.txt")

        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 20) else {
            // 没账号时可能停在引导页，没有 tabBar：留证据，但不算失败。
            attachScreenshot(app, name: "00-no-tabbar")
            print("TAB-SWEEP: 没有找到 tabBar，跳过逐个切换")
            return
        }

        let buttons = tabBar.buttons
        let count = buttons.count
        print("TAB-SWEEP: 找到 \(count) 个标签页，首屏耗时 \(Int(Date().timeIntervalSince(started)))s")
        XCTAssertGreaterThan(count, 0, "tabBar 存在但一个按钮都没有")

        for index in 0..<count {
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            let label = button.label.isEmpty ? "tab\(index)" : button.label
            button.tap()
            Thread.sleep(forTimeInterval: 6)
            let safe = label.replacingOccurrences(of: "/", with: "-")
            attachScreenshot(app, name: "\(String(format: "%02d", index + 1))-\(safe)")
            XCTAssertEqual(app.state, .runningForeground, "切到第 \(index + 1) 个标签页（\(label)）后 App 不在前台")
        }

        attachScreenshot(app, name: "99-final")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

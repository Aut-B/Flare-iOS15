import XCTest

// iOS 15 回退：RouterNavigationState 由「泛型 + @Perceptible」改为具体 Route 的
// ObservableObject 后，原先用 String 占位路由的断言改用无载荷的叶子路由替代。
@MainActor
final class RouterNavigationStateTests: XCTestCase {
    func testReloginSuccessAtRootDismissesSheetWithoutPoppingEmptyStack() {
        let navigation = RouterNavigationState()
        navigation.sheet = .serviceSelect

        navigation.dismissSheet()

        XCTAssertNil(navigation.sheet)
        XCTAssertTrue(navigation.backStack.isEmpty)
    }

    func testReloginSuccessPreservesParentNavigationAndCanBeRepeated() {
        let navigation = RouterNavigationState()
        navigation.backStack = [.settings, .accountManagement]
        navigation.sheet = .serviceSelect

        navigation.dismissSheet()
        navigation.dismissSheet()

        XCTAssertNil(navigation.sheet)
        XCTAssertEqual(navigation.backStack, [.settings, .accountManagement])
    }

    func testDismissingSheetPreservesCover() {
        let navigation = RouterNavigationState()
        navigation.sheet = .serviceSelect
        navigation.cover = .about

        navigation.dismissSheet()

        XCTAssertNil(navigation.sheet)
        XCTAssertEqual(navigation.cover, .about)
    }

    func testDismissingCoverAtRootDoesNotPopEmptyStack() {
        let navigation = RouterNavigationState()
        navigation.cover = .about

        navigation.dismissCover()

        XCTAssertNil(navigation.cover)
        XCTAssertTrue(navigation.backStack.isEmpty)
    }

    func testDismissingCoverPreservesParentAndSheetAndCanBeRepeated() {
        let navigation = RouterNavigationState()
        navigation.backStack = [.home]
        navigation.sheet = .tabSettings
        navigation.cover = .about

        navigation.dismissCover()
        navigation.dismissCover()

        XCTAssertNil(navigation.cover)
        XCTAssertEqual(navigation.sheet, .tabSettings)
        XCTAssertEqual(navigation.backStack, [.home])
    }

    func testGoingBackPopsOnlyOneNavigationDestination() {
        let navigation = RouterNavigationState()
        navigation.backStack = [.settings, .accountManagement]

        navigation.goBack()

        XCTAssertEqual(navigation.backStack, [.settings])
    }

    func testGoingBackAtRootIsSafe() {
        let navigation = RouterNavigationState()

        navigation.goBack()

        XCTAssertTrue(navigation.backStack.isEmpty)
    }
}

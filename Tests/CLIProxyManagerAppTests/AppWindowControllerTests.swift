import XCTest
@testable import CLIProxyManagerApp

@MainActor
final class AppWindowControllerTests: XCTestCase {
    func testOpenMainActivatesAppAndRequestsMainWindow() {
        let appController = StubAppController()
        let windowController = AppWindowController(appController: appController)

        windowController.openMain()

        XCTAssertEqual(appController.openedWindowIDs, ["main"])
        XCTAssertEqual(appController.activationCount, 1)
    }

    func testOpenSettingsActivatesAppAndRequestsSettingsWindow() {
        let appController = StubAppController()
        let windowController = AppWindowController(appController: appController)

        windowController.openSettings()

        XCTAssertEqual(appController.openedWindowIDs, ["settings"])
        XCTAssertEqual(appController.activationCount, 1)
    }

    func testCloseKeyWindowClosesKeyWindow() {
        let appController = StubAppController()
        let windowController = AppWindowController(appController: appController)

        windowController.closeKeyWindow()

        XCTAssertEqual(appController.closeKeyWindowCount, 1)
    }
}

@MainActor
private final class StubAppController: AppControlling {
    private(set) var openedWindowIDs: [String] = []
    private(set) var activationCount = 0
    private(set) var closeKeyWindowCount = 0

    func openWindow(id: String) {
        openedWindowIDs.append(id)
    }

    func activate() {
        activationCount += 1
    }

    func closeKeyWindow() {
        closeKeyWindowCount += 1
    }
}

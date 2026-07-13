import AppKit
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class UsageOverlayWindowControllerTests: XCTestCase {
    func testDefaultPanelUsesBorderlessStyleForCustomHeader() {
        let controller = UsageOverlayWindowController()

        XCTAssertTrue(controller.window.styleMask.contains(.borderless))
    }

    func testUpdateShowsAndHidesThePanelWithoutChangingPreferenceState() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)

        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.isVisible)

        controller.update(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isVisible)
    }

    func testContentSizeExpandsPanelHeightForAdditionalUsageRows() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)

        controller.updateContentSize(CGSize(width: 300, height: 420))

        XCTAssertEqual(panel.contentView?.frame.size, CGSize(width: 300, height: 420))
    }

    func testFrameIsNotUsableWhenMostOfThePanelIsOffScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 5120, height: 2880)
        let offScreenFrame = CGRect(x: -597, y: 1890, width: 300, height: 252)

        XCTAssertFalse(
            UsageOverlayWindowController.isFrameUsable(
                offScreenFrame,
                within: [screenFrame]
            )
        )
        XCTAssertTrue(
            UsageOverlayWindowController.isFrameUsable(
                CGRect(x: 200, y: 1200, width: 300, height: 252),
                within: [screenFrame]
            )
        )
    }

    func testCustomCloseHidesPanelForTheCurrentSession() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)
        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))

        controller.hideForCurrentSession()

        XCTAssertFalse(panel.isVisible)
    }

    func testPreferenceUpdatesDoNotReshowSessionSuppressedHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)
        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))
        controller.hideForCurrentSession()

        controller.update(.init(isVisible: true, alwaysOnTop: true, backgroundOpacity: 0.45))

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(panel.level, .floating)
    }

    func testPersistedFalseToTrueReshowsSessionSuppressedHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)
        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))
        controller.hideForCurrentSession()

        controller.update(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))
        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))

        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.isVisible)
    }

    func testShowForCurrentSessionRestoresAPreviouslyHiddenHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)
        let preferences = AppConfig.UsageOverlay(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9)
        controller.update(preferences)
        controller.hideForCurrentSession()

        controller.showForCurrentSession(using: preferences)

        XCTAssertTrue(panel.isVisible)
    }

    func testCloseHidesPanelButRetainsTheSavedVisibilityPreference() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(panel: panel)
        controller.update(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))

        XCTAssertFalse(controller.windowShouldClose(panel))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isVisible)
    }
}

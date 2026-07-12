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
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        let controller = UsageOverlayWindowController(
            panel: panel,
            visibleFrameProvider: visibleFrame
        )

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

    func testControllerStartsWithConfiguredDisplayMode() {
        let panel = makePanel(width: 108, height: 240)
        let controller = UsageOverlayWindowController(panel: panel, initialDisplayMode: .compact)

        XCTAssertEqual(controller.displayMode, .compact)
    }

    func testHideAndShowKeepSessionDisplayMode() {
        let panel = makePanel(width: 108, height: 240)
        let controller = UsageOverlayWindowController(panel: panel, initialDisplayMode: .compact)
        let preferences = AppConfig.UsageOverlay(isVisible: true, displayMode: .compact)

        controller.showForCurrentSession(using: preferences)
        controller.hideForCurrentSession()
        controller.showForCurrentSession(using: preferences)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.displayMode, .compact)
    }

    func testCompactResizeKeepsRightTopAnchor() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let original = panel.frame
        let controller = makeCompactController(panel: panel)

        controller.updateContentSize(CGSize(width: 108, height: 360), animated: true)

        let expected = UsageOverlayFrameLayout.targetFrame(
            currentFrame: original,
            targetContentHeight: 360,
            mode: .compact,
            visibleFrame: visibleFrame()!
        )

        XCTAssertEqual(panel.frame, expected)
    }

    func testReduceMotionUsesImmediateFrameUpdate() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = makeCompactController(panel: panel)

        controller.updateContentSize(CGSize(width: 108, height: 320), animated: true)

        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 320))
    }

    func testFailedModePersistenceKeepsSessionMode() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        var attemptedModes: [AppConfig.UsageOverlay.DisplayMode] = []
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: {
                attemptedModes.append($0)
                return false
            },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        controller.toggleDisplayMode()
        controller.update(.init(isVisible: true, displayMode: .expanded))

        XCTAssertEqual(attemptedModes, [.compact])
        XCTAssertEqual(controller.displayMode, .compact)
    }

    func testSecondResizeRetargetsFromCurrentFrame() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = makeCompactController(panel: panel)

        controller.updateContentSize(CGSize(width: 108, height: 360), animated: true)
        let firstAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        controller.updateContentSize(CGSize(width: 108, height: 420), animated: true)

        XCTAssertEqual(panel.frame.maxX, firstAnchor.x)
        XCTAssertEqual(panel.frame.maxY, firstAnchor.y)
        XCTAssertEqual(panel.frame.height, 420)
    }

    private func makePanel(
        x: CGFloat = 400,
        y: CGFloat = 400,
        width: CGFloat,
        height: CGFloat
    ) -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
    }

    private func makeCompactController(panel: NSPanel) -> UsageOverlayWindowController {
        UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )
    }

    private var visibleFrame: () -> CGRect? {
        { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    }
}

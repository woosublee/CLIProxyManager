import AppKit
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

private final class RelaunchPlacementTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {}
}

@MainActor
final class UsageOverlayRelaunchPlacementTests: XCTestCase {
    func testRelaunchRestoresPositionAfterSingleMoveNotification() throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(panel: panel, persistence: persistence)

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        controller.hideForCurrentSession()

        let relaunchedPanel = makePanel(frame: CGRect(x: 0, y: 0, width: 108, height: 72))
        let relaunchedController = makeController(panel: relaunchedPanel, persistence: persistence)
        relaunchedController.update(.init(isVisible: true, displayMode: .compact))
        relaunchedController.updateContentSize(CGSize(width: 108, height: 180))

        XCTAssertEqual(relaunchedPanel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))
    }

    func testRelaunchRestoresFinalPositionAfterMultipleMoveNotifications() throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { true }
        )

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 510, y: 410))
        controller.handleWindowDidMove()
        panel.setFrameOrigin(CGPoint(x: 650, y: 450))
        controller.handleWindowDidMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        XCTAssertEqual(panel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))
        XCTAssertEqual(persistence.load()?.rightOffset, 532)
        XCTAssertEqual(persistence.load()?.topOffset, 220)
        controller.hideForCurrentSession()

        let relaunchedPanel = makePanel(frame: CGRect(x: 0, y: 0, width: 108, height: 72))
        let relaunchedController = makeController(panel: relaunchedPanel, persistence: persistence)
        relaunchedController.update(.init(isVisible: true, displayMode: .compact))
        relaunchedController.updateContentSize(CGSize(width: 108, height: 180))

        XCTAssertEqual(relaunchedPanel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))
    }

    func testRelaunchKeepsTopRightAnchorWhenContentHeightChanges() throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(panel: panel, persistence: persistence)

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        controller.hideForCurrentSession()

        let relaunchedPanel = makePanel(frame: CGRect(x: 0, y: 0, width: 108, height: 72))
        let relaunchedController = makeController(panel: relaunchedPanel, persistence: persistence)
        relaunchedController.update(.init(isVisible: true, displayMode: .compact))
        relaunchedController.updateContentSize(CGSize(width: 108, height: 300))

        XCTAssertEqual(relaunchedPanel.frame.maxX, 908)
        XCTAssertEqual(relaunchedPanel.frame.maxY, 680)
        XCTAssertEqual(relaunchedPanel.frame.height, 300)
    }

    func testScreenChangeWaitsForMouseReleaseWithoutAnotherMoveNotification() async throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        var isMousePressed = true
        var screenCallbacks: [@MainActor () -> Void] = []
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { isMousePressed },
            screenResizeScheduler: { screenCallbacks.append($0) }
        )
        screenCallbacks.removeAll()

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        controller.handleScreenGeometryChange()

        XCTAssertTrue(screenCallbacks.isEmpty)
        isMousePressed = false
        let didFinishMove = await waitUntil { !screenCallbacks.isEmpty }
        XCTAssertTrue(didFinishMove)
        screenCallbacks.last?()
        XCTAssertEqual(panel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))
        XCTAssertEqual(persistence.load()?.rightOffset, 532)
        XCTAssertEqual(persistence.load()?.topOffset, 220)
    }

    func testContentResizeWaitsForDragToFinishWithoutChangingSavedAnchor() async throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        var isMousePressed = true
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { isMousePressed },
            fittingSizeProvider: { CGSize(width: 108, height: 300) }
        )

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        controller.updateContentSize(CGSize(width: 108, height: 300))
        XCTAssertEqual(panel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))

        isMousePressed = false
        let didResize = await waitUntil { panel.frame.height == 300 }
        XCTAssertTrue(didResize)
        XCTAssertEqual(panel.frame.maxX, 908)
        XCTAssertEqual(panel.frame.maxY, 680)
        XCTAssertEqual(persistence.load()?.rightOffset, 532)
        XCTAssertEqual(persistence.load()?.topOffset, 220)
    }

    func testScreenRestoreQueuedBeforeDragCannotReplaceLatestPosition() throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        var screenCallbacks: [@MainActor () -> Void] = []
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { true },
            screenResizeScheduler: { screenCallbacks.append($0) }
        )
        screenCallbacks.removeAll()
        controller.handleScreenGeometryChange()
        let staleScreenRestore = try XCTUnwrap(screenCallbacks.last)

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 510, y: 410))
        controller.handleWindowDidMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()
        staleScreenRestore()

        XCTAssertEqual(panel.frame, CGRect(x: 800, y: 500, width: 108, height: 180))
    }

    func testClickWithoutMovementDoesNotReplaceSavedPlacement() async throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        var screenCallbacks: [@MainActor () -> Void] = []
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            screenResizeScheduler: { screenCallbacks.append($0) }
        )
        screenCallbacks.removeAll()

        controller.handleWindowWillMove()
        controller.handleScreenGeometryChange()
        let didFinishMove = await waitUntil { !screenCallbacks.isEmpty }

        XCTAssertTrue(didFinishMove)
        XCTAssertNil(persistence.load())
    }

    func testMouseReleaseSavesFinalFrameWithoutFinalMoveNotification() async throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        var isMousePressed = true
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { isMousePressed }
        )

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 510, y: 410))
        controller.handleWindowDidMove()
        panel.delegate = nil
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        panel.delegate = controller
        isMousePressed = false

        let didSaveFinalFrame = await waitUntil { persistence.load()?.rightOffset == 532 }
        XCTAssertTrue(didSaveFinalFrame)
        XCTAssertEqual(persistence.load()?.topOffset, 220)

        controller.updateContentSize(CGSize(width: 108, height: 300))
        XCTAssertEqual(panel.frame.height, 300)
        XCTAssertEqual(persistence.load()?.rightOffset, 532)
        XCTAssertEqual(persistence.load()?.topOffset, 220)
    }

    func testFinalPlacementUsesUpdatedScreenAfterFrameStopsMoving() throws {
        let suiteName = "UsageOverlayRelaunchPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UsageOverlayPlacementPersistence.userDefaults(defaults)
        let primary = makeScreen(id: 1, x: 0)
        let secondary = makeScreen(id: 2, x: -1440)
        var currentScreen = primary
        var isMousePressed = true
        let panel = makePanel(frame: CGRect(x: 500, y: 400, width: 108, height: 180))
        let controller = makeController(
            panel: panel,
            persistence: persistence,
            isMousePressed: { isMousePressed },
            screenProvider: .init(
                screens: { [primary, secondary] },
                screenForWindow: { _ in currentScreen }
            )
        )

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: -600, y: 500))
        controller.handleWindowDidMove()
        currentScreen = secondary
        controller.handleScreenGeometryChange()
        isMousePressed = false
        controller.handleWindowDidMove()

        XCTAssertEqual(persistence.load()?.display, secondary.identity)
        XCTAssertEqual(persistence.load()?.rightOffset, 492)
        XCTAssertEqual(persistence.load()?.topOffset, 220)
    }

    private func makeScreen(id: CGDirectDisplayID, x: CGFloat) -> UsageOverlayScreen {
        let frame = CGRect(x: x, y: 0, width: 1440, height: 900)
        return UsageOverlayScreen(
            displayID: id,
            identity: UsageOverlayDisplayIdentity(
                uuid: "test-display-\(id)",
                vendorNumber: 1,
                modelNumber: 2,
                serialNumber: id
            ),
            frame: frame,
            visibleFrame: frame,
            isPrimary: id == 1
        )
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = RelaunchPlacementTestPanel(
            contentRect: frame,
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        return panel
    }

    private func makeController(
        panel: NSPanel,
        persistence: UsageOverlayPlacementPersistence,
        isMousePressed: @escaping () -> Bool = { false },
        screenProvider: UsageOverlayScreenProvider? = nil,
        screenResizeScheduler: @escaping (@escaping @MainActor () -> Void) -> Void = { _ in },
        fittingSizeProvider: @escaping () -> CGSize = { CGSize(width: 108, height: 180) }
    ) -> UsageOverlayWindowController {
        let screen = makeScreen(id: 1, x: 0)
        let frame = screen.visibleFrame
        return UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            refreshStatusOnShow: {},
            shouldReduceMotion: { true },
            visibleFrameProvider: { frame },
            screenProvider: screenProvider ?? UsageOverlayScreenProvider(
                screens: { [screen] },
                screenForWindow: { _ in screen }
            ),
            placementPersistence: persistence,
            deferredScreenResizeScheduler: screenResizeScheduler,
            fittingSizeProvider: fittingSizeProvider,
            isMouseButtonPressed: isMousePressed
        )
    }
}

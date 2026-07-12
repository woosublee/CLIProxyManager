import AppKit
import Combine
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

    func testFailedPersistenceIgnoresDeferredRollbackThenAcceptsLaterAcknowledgement() async {
        let subject = PassthroughSubject<AppConfig.UsageOverlay, Never>()
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { target in
                subject.send(.init(isVisible: true, displayMode: target))
                subject.send(.init(isVisible: true, displayMode: .expanded))
                return false
            },
            usageOverlayPublisher: subject.eraseToAnyPublisher(),
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        controller.toggleDisplayMode()
        await drainMainQueue()
        XCTAssertEqual(controller.displayMode, .compact)

        subject.send(.init(isVisible: false, displayMode: .compact))
        await drainMainQueue()
        XCTAssertEqual(controller.displayMode, .compact)

        subject.send(.init(isVisible: false, displayMode: .expanded))
        await drainMainQueue()
        XCTAssertEqual(controller.displayMode, .expanded)
    }

    func testFailureWithoutOptimisticEmissionsAcknowledgesFirstLaterTarget() async {
        let subject = PassthroughSubject<AppConfig.UsageOverlay, Never>()
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in false },
            usageOverlayPublisher: subject.eraseToAnyPublisher(),
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        controller.toggleDisplayMode()
        XCTAssertEqual(controller.displayMode, .compact)

        subject.send(.init(isVisible: false, displayMode: .compact))
        await drainMainQueue()
        XCTAssertEqual(controller.displayMode, .compact)

        subject.send(.init(isVisible: false, displayMode: .expanded))
        await drainMainQueue()
        XCTAssertEqual(controller.displayMode, .expanded)
    }

    func testModeTransitionAnimationRemainsActiveThroughFollowUpRetarget() {
        var coordinator = UsageOverlayResizeCoordinator()
        let generation = coordinator.beginModeTransition()

        XCTAssertTrue(coordinator.requestResize(animated: true))
        let initial = coordinator.consumeResizeRequest()
        XCTAssertTrue(initial.animated)
        XCTAssertEqual(initial.transitionGeneration, generation)
        coordinator.animationStarted(generation: generation)

        XCTAssertTrue(coordinator.requestResize(animated: false))
        let followUp = coordinator.consumeResizeRequest()
        XCTAssertTrue(followUp.animated)
        XCTAssertEqual(followUp.transitionGeneration, generation)
        coordinator.animationStarted(generation: generation)

        coordinator.animationCompleted(generation: generation)
        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertTrue(coordinator.consumeResizeRequest().animated)

        coordinator.animationCompleted(generation: generation)
        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertFalse(coordinator.consumeResizeRequest().animated)
    }

    func testRapidRetoggleIgnoresOldCompletionBeforeNewCompletion() {
        var coordinator = UsageOverlayResizeCoordinator()
        let generation1 = coordinator.beginModeTransition()
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation1)

        let generation2 = coordinator.beginModeTransition()
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation2)

        coordinator.animationCompleted(generation: generation1)
        coordinator.animationCompleted(generation: generation2)

        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertFalse(coordinator.consumeResizeRequest().animated)
    }

    func testRapidRetoggleIgnoresOldCompletionAfterNewCompletion() {
        var coordinator = UsageOverlayResizeCoordinator()
        let generation1 = coordinator.beginModeTransition()
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation1)

        let generation2 = coordinator.beginModeTransition()
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation2)

        coordinator.animationCompleted(generation: generation2)
        coordinator.animationCompleted(generation: generation1)

        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertFalse(coordinator.consumeResizeRequest().animated)
    }

    func testImmediateTransitionCompletionClearsAnimationIntent() {
        var coordinator = UsageOverlayResizeCoordinator()
        let generation = coordinator.beginModeTransition()
        XCTAssertTrue(coordinator.requestResize(animated: true))
        let request = coordinator.consumeResizeRequest()
        XCTAssertTrue(request.animated)
        XCTAssertEqual(request.transitionGeneration, generation)

        coordinator.transitionCompletedWithoutAnimation(generation: generation)

        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertFalse(coordinator.consumeResizeRequest().animated)
    }

    func testToggleKeepsFrameUnchangedUntilScheduledResizeUsesLayoutTarget() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let original = panel.frame
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        controller.toggleDisplayMode()

        XCTAssertEqual(panel.frame, original)
    }

    func testCompactResizeClampsToScreenAndKeepsSafeRightTopAnchor() {
        let panel = makePanel(x: 1390, y: 850, width: 300, height: 260)
        let controller = makeCompactController(panel: panel)

        controller.updateContentSize(CGSize(width: 108, height: 420), animated: true)

        XCTAssertEqual(panel.frame.maxX, 1424)
        XCTAssertEqual(panel.frame.maxY, 884)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, 16)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, 16)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
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

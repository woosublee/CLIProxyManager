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
        let generation = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))

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
        let generation1 = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation1)

        let generation2 = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
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
        let generation1 = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
        XCTAssertTrue(coordinator.requestResize(animated: true))
        _ = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation1)

        let generation2 = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
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
        let generation = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
        XCTAssertTrue(coordinator.requestResize(animated: true))
        let request = coordinator.consumeResizeRequest()
        XCTAssertTrue(request.animated)
        XCTAssertEqual(request.transitionGeneration, generation)

        coordinator.transitionCompletedWithoutAnimation(generation: generation)

        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertFalse(coordinator.consumeResizeRequest().animated)
    }

    func testCancelActiveTransitionClearsAnchorAndAnimationIntent() {
        var coordinator = UsageOverlayResizeCoordinator()
        let generation = coordinator.beginModeTransition(anchor: CGPoint(x: 800, y: 660))
        XCTAssertTrue(coordinator.requestResize(animated: true))
        let request = coordinator.consumeResizeRequest()
        coordinator.animationStarted(generation: generation)

        coordinator.cancelActiveTransition()
        coordinator.animationCompleted(generation: request.transitionGeneration)

        XCTAssertNil(coordinator.authoritativeAnchor)
        XCTAssertTrue(coordinator.requestResize(animated: false))
        let ordinary = coordinator.consumeResizeRequest()
        XCTAssertFalse(ordinary.animated)
        XCTAssertNil(ordinary.transitionGeneration)
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

    func testModeTransitionRestoresCapturedRightTopAnchorAfterAppKitContentResizeMutation() async {
        var fittingSize = CGSize(width: 108, height: 180)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let originalAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame,
            fittingSizeProvider: { fittingSize }
        )

        controller.toggleDisplayMode()
        simulateTopLeftAnchoredContentResize(panel, to: fittingSize)
        XCTAssertNotEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)

        await drainMainQueue()

        XCTAssertEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)
        XCTAssertEqual(panel.frame.size, fittingSize)

        let compactAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        fittingSize = CGSize(width: 300, height: 320)
        controller.toggleDisplayMode()
        simulateTopLeftAnchoredContentResize(panel, to: fittingSize)
        XCTAssertNotEqual(panel.frame.maxX, compactAnchor.x)
        XCTAssertEqual(panel.frame.maxY, compactAnchor.y)

        await drainMainQueue()

        XCTAssertEqual(panel.frame.maxX, compactAnchor.x)
        XCTAssertEqual(panel.frame.maxY, compactAnchor.y)
        XCTAssertEqual(panel.frame.size, fittingSize)
    }

    func testRapidRetoggleBeforeAnchorRepairPreservesOriginalAnchorInBothDirections() async {
        for initialMode in [AppConfig.UsageOverlay.DisplayMode.expanded, .compact] {
            let initialSize = initialMode == .expanded
                ? CGSize(width: 300, height: 260)
                : CGSize(width: 108, height: 180)
            let finalSize = initialSize
            var fittingSize = initialMode == .expanded
                ? CGSize(width: 108, height: 180)
                : CGSize(width: 300, height: 320)
            let panel = makePanel(x: 500, y: 400, width: initialSize.width, height: initialSize.height)
            panel.contentView = NSView(frame: CGRect(origin: .zero, size: initialSize))
            let originalAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
            let controller = UsageOverlayWindowController(
                panel: panel,
                initialDisplayMode: initialMode,
                persistDisplayMode: { _ in true },
                shouldReduceMotion: { true },
                visibleFrameProvider: visibleFrame,
                fittingSizeProvider: { fittingSize }
            )

            controller.toggleDisplayMode()
            simulateTopLeftAnchoredContentResize(panel, to: fittingSize)
            fittingSize = finalSize
            controller.toggleDisplayMode()
            simulateTopLeftAnchoredContentResize(panel, to: fittingSize)

            await drainMainQueue()

            XCTAssertEqual(panel.frame.maxX, originalAnchor.x, "initial mode: \(initialMode)")
            XCTAssertEqual(panel.frame.maxY, originalAnchor.y, "initial mode: \(initialMode)")
            XCTAssertEqual(panel.frame.size, finalSize, "initial mode: \(initialMode)")
        }
    }

    func testScreenChangeInterruptsAnimationAndStaleCompletionCannotRestoreOldTarget() {
        var visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var deferredScreenResizes: [@MainActor () -> Void] = []
        var pendingAnimations: [() -> Void] = []
        var animationWasInterrupted = false
        var animationCount = 0
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: { visibleFrame },
            deferredScreenResizeScheduler: { deferredScreenResizes.append($0) },
            fittingSizeProvider: { CGSize(width: 108, height: 180) },
            frameAnimator: { panel, target, completion in
                animationCount += 1
                animationWasInterrupted = false
                pendingAnimations.append {
                    if !animationWasInterrupted {
                        panel.setFrame(target, display: false)
                    }
                    completion()
                }
            },
            frameAnimationInterrupter: { _ in
                animationWasInterrupted = true
            }
        )
        deferredScreenResizes.removeAll()

        controller.toggleDisplayMode()
        drainMainQueueSynchronously()
        XCTAssertEqual(animationCount, 1)
        XCTAssertEqual(pendingAnimations.count, 1)

        panel.setFrame(CGRect(x: 300, y: 220, width: 108, height: 180), display: false)
        visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        controller.handleScreenGeometryChange()
        XCTAssertTrue(animationWasInterrupted)
        XCTAssertEqual(deferredScreenResizes.count, 1)

        deferredScreenResizes.removeFirst()()
        let screenAdjustedFrame = panel.frame
        pendingAnimations.removeFirst()()

        XCTAssertEqual(panel.frame, screenAdjustedFrame)
        controller.requestContentResize(animated: false)
        drainMainQueueSynchronously()
        XCTAssertEqual(animationCount, 1)
    }

    func testUserDragCancelsTransitionAndFutureResizeUsesMovedAnchor() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame,
            fittingSizeProvider: { CGSize(width: 108, height: 180) }
        )

        controller.toggleDisplayMode()
        let movedFrame = CGRect(x: 220, y: 180, width: 108, height: 180)
        panel.setFrame(movedFrame, display: false)
        controller.handleWindowDrag()
        drainMainQueueSynchronously()

        XCTAssertEqual(panel.frame.maxX, movedFrame.maxX)
        XCTAssertEqual(panel.frame.maxY, movedFrame.maxY)
    }

    func testHideDuringTransitionCancelsOldAnchorBeforeShow() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let preferences = AppConfig.UsageOverlay(isVisible: true, displayMode: .compact)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame,
            fittingSizeProvider: { CGSize(width: 108, height: 180) }
        )

        controller.toggleDisplayMode()
        simulateTopLeftAnchoredContentResize(panel, to: CGSize(width: 108, height: 180))
        controller.hideForCurrentSession()
        controller.showForCurrentSession(using: preferences)
        drainMainQueueSynchronously()

        XCTAssertLessThanOrEqual(panel.frame.maxX, 784)
        XCTAssertLessThanOrEqual(panel.frame.maxY, 884)
        XCTAssertNotEqual(panel.frame.maxX, 800)
    }

    func testMissingContentViewCompletesConsumedTransition() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        controller.toggleDisplayMode()
        drainMainQueueSynchronously()
        let movedFrame = CGRect(x: 200, y: 160, width: 300, height: 260)
        panel.setFrame(movedFrame, display: false)
        controller.updateContentSize(CGSize(width: 300, height: 300))

        XCTAssertEqual(panel.frame.maxX, movedFrame.maxX)
        XCTAssertEqual(panel.frame.maxY, movedFrame.maxY)
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

    func testScreenChangeRecomputesCompactViewportAndClampsPanel() async {
        var visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = makePanel(x: 1200, y: 700, width: 108, height: 600)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: { visibleFrame }
        )
        let initialMaximum = controller.compactAccountMaximumHeight

        visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        controller.handleScreenGeometryChange()
        await drainMainQueue()

        XCTAssertLessThan(controller.compactAccountMaximumHeight, initialMaximum)
        XCTAssertLessThanOrEqual(panel.frame.maxX, 784)
        XCTAssertLessThanOrEqual(panel.frame.maxY, 484)
    }

    func testScreenGeometryResizeDefersAndCoalescesToLatestGeneration() {
        var callbacks: [@MainActor () -> Void] = []
        var fittingSizeReads = 0
        var visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let panel = makePanel(x: 600, y: 300, width: 108, height: 300)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: { visibleFrame },
            deferredScreenResizeScheduler: { callbacks.append($0) },
            fittingSizeProvider: {
                fittingSizeReads += 1
                return CGSize(width: 108, height: visibleFrame.height - 100)
            }
        )
        callbacks.removeAll()

        controller.handleScreenGeometryChange()
        visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        controller.handleScreenGeometryChange()

        XCTAssertEqual(fittingSizeReads, 0)
        XCTAssertEqual(callbacks.count, 2)

        callbacks[0]()
        XCTAssertEqual(fittingSizeReads, 0)
        callbacks[1]()
        XCTAssertEqual(fittingSizeReads, 1)
        XCTAssertEqual(panel.frame.height, 720)
    }

    func testNilVisibleFrameUsesCompactMetricsAndCurrentAnchor() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let originalAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: { nil },
            screenVisibleFrameProvider: { nil }
        )

        controller.updateContentSize(CGSize(width: 0, height: 1), animated: false)

        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 72))
        XCTAssertEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)
    }

    func testNilVisibleFrameUsesExpandedMetricsAndCurrentAnchor() {
        let panel = makePanel(x: 500, y: 400, width: 108, height: 72)
        let originalAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            shouldReduceMotion: { true },
            visibleFrameProvider: { nil },
            screenVisibleFrameProvider: { nil }
        )

        controller.updateContentSize(CGSize(width: 0, height: 1), animated: false)

        XCTAssertEqual(panel.frame.size, CGSize(width: 300, height: 260))
        XCTAssertEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)
    }

    private func simulateTopLeftAnchoredContentResize(_ panel: NSPanel, to size: CGSize) {
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setFrame(
            CGRect(
                x: topLeft.x,
                y: topLeft.y - size.height,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func drainMainQueueSynchronously() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
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

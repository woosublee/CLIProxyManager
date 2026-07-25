import AppKit
import Combine
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

private final class UnconstrainedTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class UsageOverlayWindowControllerTests: XCTestCase {
    func testDefaultPanelUsesBorderlessStyleForCustomHeader() {
        let controller = UsageOverlayWindowController()

        XCTAssertTrue(controller.window.styleMask.contains(.borderless))
    }

    func testChromeHostingViewIdentityStaysStableAcrossModeToggle() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 330)
        var completeAnimation: (@MainActor () -> Void)?
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: { CGSize(width: 108, height: 168) },
            frameAnimator: { _, _, completion in
                completeAnimation = completion
            }
        )
        await drainMainQueue()

        guard let surfaceView = panel.contentView as? UsageOverlaySurfaceView else {
            return XCTFail("Expected usage overlay surface")
        }
        let chromeIdentity = surfaceView.chromeViewIdentity

        controller.toggleDisplayMode()
        completeAnimation?()
        await drainMainQueue()

        XCTAssertEqual(surfaceView.chromeViewIdentity, chromeIdentity)
    }

    func testUsageOverlaySurfaceFillsPanelBoundsDuringResize() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        _ = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .compact,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )
        await drainMainQueue()

        guard let surfaceView = panel.contentView as? UsageOverlaySurfaceView else {
            return XCTFail("Expected usage overlay surface")
        }

        panel.setFrame(
            CGRect(x: 596, y: 494, width: 204, height: 166),
            display: false
        )
        surfaceView.layoutSubtreeIfNeeded()

        XCTAssertEqual(surfaceView.frame, panel.contentLayoutRect)
        XCTAssertEqual(surfaceView.hostedSurfaceFrame, surfaceView.bounds)
        XCTAssertEqual(surfaceView.layer?.masksToBounds, true)
        XCTAssertEqual(surfaceView.layer?.cornerRadius ?? 0, 16, accuracy: 0.001)
    }

    func testCompactMeasurementDoesNotChangeExpandedSurfaceFittingSizeBeforeResize() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 330)
        var beginResize: (@MainActor () -> Void)?
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { beginResize = $0 }
        )
        await drainMainQueue()

        guard let surfaceView = panel.contentView as? UsageOverlaySurfaceView else {
            return XCTFail("Expected usage overlay surface")
        }
        surfaceView.layoutSubtreeIfNeeded()
        let fittingSizeBeforeToggle = surfaceView.fittingSize

        controller.toggleDisplayMode()
        surfaceView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(beginResize)
        XCTAssertEqual(surfaceView.fittingSize, fittingSizeBeforeToggle)
    }

    func testCompactModeChangeKeepsHostedSurfaceAtExpandedPanelBoundsBeforeAnimation() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            frameAnimator: { _, _, completion in completion() }
        )
        await drainMainQueue()

        guard let surfaceView = panel.contentView as? UsageOverlaySurfaceView else {
            return XCTFail("Expected usage overlay surface")
        }
        let panelSizeBeforeToggle = panel.frame.size

        controller.toggleDisplayMode()
        surfaceView.layoutSubtreeIfNeeded()

        XCTAssertEqual(surfaceView.hostedSurfaceFrame, surfaceView.bounds)
        XCTAssertEqual(surfaceView.hostedSurfaceFrame.size, panelSizeBeforeToggle)
    }

    func testCollapseMeasuresCompactTargetWhileContentIsHidden() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 330)
        var animationTarget: CGRect?
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            frameAnimator: { _, target, _ in
                animationTarget = target
            }
        )
        await drainMainQueue()

        controller.toggleDisplayMode()

        XCTAssertEqual(controller.presentedDisplayMode, .expanded)
        XCTAssertTrue(controller.isContentHiddenForModeTransition)
        XCTAssertEqual(animationTarget?.width, AppWindowMetrics.usageOverlayCompactWidth)
    }

    func testExpansionMeasuresExpandedLayoutWhileContentIsHidden() {
        let panel = makePanel(x: 500, y: 400, width: 108, height: 168)
        var beginResize: (@MainActor () -> Void)?
        var animationTarget: CGRect?
        var controller: UsageOverlayWindowController!
        controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { beginResize = $0 },
            fittingSizeProvider: {
                controller.presentedDisplayMode == .expanded
                    ? CGSize(width: 300, height: 330)
                    : CGSize(width: 108, height: 168)
            },
            frameAnimator: { _, target, _ in
                animationTarget = target
            }
        )

        controller.toggleDisplayMode()

        XCTAssertTrue(controller.isContentHiddenForModeTransition)
        XCTAssertEqual(controller.presentedDisplayMode, .expanded)

        beginResize?()

        XCTAssertEqual(animationTarget?.size, CGSize(width: 300, height: 330))
    }

    func testAnimatedModeToggleHidesContentUntilFinalResizeCompletesInBothDirections() async {
        for initialMode in [AppConfig.UsageOverlay.DisplayMode.expanded, .compact] {
            let initialSize = initialMode == .expanded
                ? CGSize(width: 300, height: 330)
                : CGSize(width: 108, height: 168)
            let targetSize = initialMode == .expanded
                ? CGSize(width: 108, height: 168)
                : CGSize(width: 300, height: 330)
            let panel = makePanel(
                x: 500,
                y: 400,
                width: initialSize.width,
                height: initialSize.height
            )
            var completeAnimation: (@MainActor () -> Void)?
            let controller = UsageOverlayWindowController(
                panel: panel,
                initialDisplayMode: initialMode,
                persistDisplayMode: { _ in true },
                shouldReduceMotion: { false },
                visibleFrameProvider: visibleFrame,
                modeTransitionResizeScheduler: { $0() },
                fittingSizeProvider: { targetSize },
                frameAnimator: { _, _, completion in
                    completeAnimation = completion
                }
            )

            controller.toggleDisplayMode()
            XCTAssertTrue(controller.isContentHiddenForModeTransition)

            completeAnimation?()
            XCTAssertFalse(controller.isContentHiddenForModeTransition)
            XCTAssertEqual(controller.presentedDisplayMode, initialMode.opposite)
        }
    }

    func testCollapseKeepsExpandedContentUntilFinalRetargetCompletes() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 330)
        var fittingSize = CGSize(width: 108, height: 168)
        var animationCompletions: [@MainActor () -> Void] = []
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: { fittingSize },
            frameAnimator: { _, _, completion in
                animationCompletions.append(completion)
            }
        )
        await drainMainQueue()

        controller.toggleDisplayMode()
        fittingSize = CGSize(width: 108, height: 210)
        controller.requestContentResize(animated: false)
        await drainMainQueue()

        XCTAssertEqual(animationCompletions.count, 2)
        animationCompletions[0]()
        XCTAssertEqual(controller.presentedDisplayMode, .expanded)
        XCTAssertTrue(controller.isContentHiddenForModeTransition)

        animationCompletions[1]()
        XCTAssertEqual(controller.presentedDisplayMode, .compact)
    }

    func testModeToggleStartsFrameAnimationAfterContentHides() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        var animationStarted = false
        var beginResize: (@MainActor () -> Void)?
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { beginResize = $0 },
            fittingSizeProvider: { CGSize(width: 108, height: 168) },
            frameAnimator: { _, _, completion in
                animationStarted = true
                completion()
            }
        )
        await drainMainQueue()

        controller.toggleDisplayMode()

        XCTAssertTrue(controller.isContentHiddenForModeTransition)
        XCTAssertFalse(animationStarted)

        beginResize?()

        XCTAssertTrue(animationStarted)
    }

    func testMeasuredCompactContentRetargetsPanelAtControllerAnchor() async {
        let viewModel = DashboardViewModel(config: .default)
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: { CGSize(width: 108, height: 168) },
            frameAnimator: { panel, target, completion in
                panel.setFrame(target, display: false)
                completion()
            }
        )
        await drainMainQueue()

        controller.toggleDisplayMode()
        await drainMainQueue()

        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 168))
        XCTAssertEqual(panel.frame.maxX, 800)
        XCTAssertEqual(panel.frame.maxY, 660)
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

    func testShowForCurrentSessionRefreshesStatusEachTimeReusedHUDAppears() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var refreshCount = 0
        let controller = UsageOverlayWindowController(
            panel: panel,
            refreshStatusOnShow: { refreshCount += 1 }
        )
        let preferences = AppConfig.UsageOverlay(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9)

        controller.showForCurrentSession(using: preferences)
        controller.hideForCurrentSession()
        controller.showForCurrentSession(using: preferences)

        XCTAssertEqual(refreshCount, 2)
        XCTAssertTrue(controller.isVisible)
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

    func testInitiallyVisibleCompactHUDExpandsFromSavedSingleAccountFrame() async {
        var config = AppConfig.default
        config.usageOverlay = .init(isVisible: true, displayMode: .compact)
        let viewModel = DashboardViewModel(config: config)
        viewModel.providerRows = [
            ProviderRowState(
                id: "claude-personal",
                name: "Claude OAuth",
                nickname: "Personal",
                functionName: "claude",
                connectionTitle: "Connected",
                connectionDetail: "personal@example.com",
                isConnected: true
            ),
            ProviderRowState(
                id: "codex-work",
                name: "Codex OAuth",
                nickname: "Work",
                functionName: "codex",
                connectionTitle: "Connected",
                connectionDetail: "work@example.com",
                isConnected: true
            )
        ]
        let panel = makePanel(x: 500, y: 400, width: 108, height: 168)
        let controller = UsageOverlayWindowController(
            panel: panel,
            viewModel: viewModel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame
        )

        await drainMainQueue()
        let didResize = await waitUntil {
            abs(panel.frame.height - 245) < 0.5
        }

        guard let surfaceView = panel.contentView as? UsageOverlaySurfaceView else {
            return XCTFail("Expected usage overlay surface")
        }
        surfaceView.layoutSubtreeIfNeeded()
        XCTAssertTrue(didResize, "Compact HUD did not reach its measured two-account height")
        XCTAssertEqual(panel.frame.height, 245, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxX, 608)
        XCTAssertEqual(panel.frame.maxY, 568)
        withExtendedLifetime(controller) {}
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

    func testImmediateResizeCanConsumePendingScheduledRequestAndClearScheduledFlag() {
        var coordinator = UsageOverlayResizeCoordinator()

        XCTAssertTrue(coordinator.requestResize(animated: false))
        XCTAssertTrue(coordinator.isResizeScheduled)
        XCTAssertFalse(coordinator.requestResize(animated: true))

        let request = coordinator.consumeResizeRequest()

        XCTAssertTrue(request.animated)
        XCTAssertFalse(coordinator.isResizeScheduled)
        XCTAssertTrue(coordinator.requestResize(animated: false))
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

    func testReduceMotionToggleAppliesLayoutTargetBeforeReturning() {
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame,
            fittingSizeProvider: { CGSize(width: 108, height: 180) }
        )

        controller.toggleDisplayMode()

        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 180))
        XCTAssertEqual(panel.frame.maxX, 800)
        XCTAssertEqual(panel.frame.maxY, 660)
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
        XCTAssertEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)

        simulateTopLeftAnchoredContentResize(panel, to: fittingSize)
        await drainMainQueue()

        XCTAssertEqual(panel.frame.maxX, originalAnchor.x)
        XCTAssertEqual(panel.frame.maxY, originalAnchor.y)
        XCTAssertEqual(panel.frame.size, fittingSize)

        let compactAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        fittingSize = CGSize(width: 300, height: 320)
        controller.toggleDisplayMode()
        XCTAssertEqual(panel.frame.maxX, compactAnchor.x)
        XCTAssertEqual(panel.frame.maxY, compactAnchor.y)

        simulateTopLeftAnchoredContentResize(panel, to: fittingSize)
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
            modeTransitionResizeScheduler: { $0() },
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

    func testWindowMoveWithoutActiveTransitionKeepsScheduledFittingResize() {
        var fittingSizeReads = 0
        let panel = makePanel(x: 500, y: 400, width: 108, height: 180)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 108, height: 180))
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: visibleFrame,
            fittingSizeProvider: {
                fittingSizeReads += 1
                return CGSize(width: 108, height: 240)
            }
        )
        drainMainQueueSynchronously()

        let readsBeforeResize = fittingSizeReads
        controller.requestContentResize(animated: false)
        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 220, y: 180))
        controller.handleWindowDidMove()
        drainMainQueueSynchronously()

        XCTAssertEqual(fittingSizeReads, readsBeforeResize + 1)
        XCTAssertEqual(panel.frame.height, 240)
    }

    func testWindowMoveDuringTransitionSettlesAtMovedRightTopAnchorWithoutAnimation() {
        var animationCount = 0
        var animationWasInterrupted = false
        var staleCompletion: (@MainActor () -> Void)?
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: { CGSize(width: 108, height: 180) },
            frameAnimator: { _, _, completion in
                animationCount += 1
                staleCompletion = completion
            },
            frameAnimationInterrupter: { _ in
                animationWasInterrupted = true
            },
            isUserInitiatedMoveDuringAnimation: { true }
        )

        controller.toggleDisplayMode()
        drainMainQueueSynchronously()
        XCTAssertEqual(animationCount, 1)

        controller.handleWindowWillMove()
        let movedFrame = CGRect(x: 220, y: 180, width: 150, height: 210)
        panel.setFrame(movedFrame, display: false)
        controller.handleWindowDidMove()
        staleCompletion?()
        drainMainQueueSynchronously()

        XCTAssertTrue(animationWasInterrupted)
        XCTAssertEqual(animationCount, 1)
        XCTAssertEqual(panel.frame.maxX, movedFrame.maxX)
        XCTAssertEqual(panel.frame.maxY, movedFrame.maxY)
        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 180))
    }

    func testControllerAppliedFrameMoveWithoutWindowWillMoveIsIgnored() {
        var fittingSizeReads = 0
        var controller: UsageOverlayWindowController!
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: {
                fittingSizeReads += 1
                return CGSize(width: 108, height: 180)
            },
            frameAnimator: { panel, target, completion in
                panel.setFrame(target, display: false)
                controller.handleWindowDidMove()
                completion()
            }
        )
        drainMainQueueSynchronously()

        let readsBeforeToggle = fittingSizeReads
        controller.toggleDisplayMode()
        drainMainQueueSynchronously()

        XCTAssertEqual(fittingSizeReads, readsBeforeToggle + 1)
        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 180))
    }

    func testAnimatedProgrammaticMoveDoesNotPersistPlacement() {
        let screen = placementScreen(
            id: 1,
            uuid: "display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isPrimary: true
        )
        var savedPlacements: [UsageOverlayPlacement] = []
        var controller: UsageOverlayWindowController!
        let panel = makePanel(x: 500, y: 400, width: 300, height: 260)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .expanded,
            persistDisplayMode: { _ in true },
            shouldReduceMotion: { false },
            visibleFrameProvider: visibleFrame,
            screenProvider: placementScreenProvider(screens: { [screen] }, windowScreen: { screen }),
            placementPersistence: .init(
                load: { nil },
                save: { savedPlacements.append($0); return true },
                loadLegacyFrame: { nil },
                removeLegacyFrame: {}
            ),
            modeTransitionResizeScheduler: { $0() },
            fittingSizeProvider: { CGSize(width: 108, height: 180) },
            frameAnimator: { panel, target, completion in
                controller.handleWindowWillMove()
                panel.setFrame(target, display: false)
                controller.handleWindowDidMove()
                completion()
            },
            isUserInitiatedMoveDuringAnimation: { false }
        )

        controller.toggleDisplayMode()

        XCTAssertTrue(savedPlacements.isEmpty)
        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 180))
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
        controller.hideForCurrentSession()
        let anchorAfterCancelledTransition = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        controller.showForCurrentSession(using: preferences)
        drainMainQueueSynchronously()

        XCTAssertEqual(panel.frame.maxX, anchorAfterCancelledTransition.x)
        XCTAssertEqual(panel.frame.maxY, anchorAfterCancelledTransition.y)
        XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 180))
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

    func testSavedPlacementRestoresOnItsDisplayInsteadOfPrimaryDisplay() {
        let primary = placementScreen(id: 1, uuid: "primary", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
        let secondary = placementScreen(id: 2, uuid: "secondary", frame: CGRect(x: -100_000, y: 0, width: 1440, height: 900))
        let placement = UsageOverlayPlacement(
            display: secondary.identity,
            frame: CGRect(x: -98_760, y: 600, width: 108, height: 180),
            visibleFrame: secondary.visibleFrame
        )
        let panel = makeUnconstrainedPanel(x: 900, y: 400, width: 108, height: 180)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: { secondary.visibleFrame },
            screenProvider: placementScreenProvider(screens: { [primary, secondary] }, windowScreen: { primary }),
            placementPersistence: .init(
                load: { placement },
                save: { _ in true },
                loadLegacyFrame: { nil },
                removeLegacyFrame: {}
            ),
            fittingSizeProvider: { CGSize(width: 108, height: 180) }
        )

        controller.showForCurrentSession(using: .init(isVisible: true, displayMode: .compact))
        drainMainQueueSynchronously()

        XCTAssertEqual(panel.frame.maxX, -98_652)
        XCTAssertEqual(panel.frame.maxY, 780)
    }

    func testUserMovePersistsPlacementButProgrammaticResizeDoesNot() {
        let screen = placementScreen(id: 1, uuid: "display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
        var savedPlacements: [UsageOverlayPlacement] = []
        let panel = makePanel(x: 500, y: 400, width: 108, height: 180)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            screenProvider: placementScreenProvider(screens: { [screen] }, windowScreen: { screen }),
            placementPersistence: .init(
                load: { nil },
                save: {
                    savedPlacements.append($0)
                    return true
                },
                loadLegacyFrame: { nil },
                removeLegacyFrame: {}
            )
        )

        controller.updateContentSize(CGSize(width: 108, height: 240))
        XCTAssertTrue(savedPlacements.isEmpty)

        controller.handleWindowWillMove()
        panel.setFrameOrigin(CGPoint(x: 800, y: 500))
        controller.handleWindowDidMove()

        XCTAssertEqual(savedPlacements.count, 1)
        XCTAssertEqual(savedPlacements[0].display, screen.identity)
        XCTAssertEqual(savedPlacements[0].rightOffset, screen.visibleFrame.maxX - panel.frame.maxX)
        XCTAssertEqual(savedPlacements[0].topOffset, screen.visibleFrame.maxY - panel.frame.maxY)
    }

    func testMissingSavedDisplayFallsBackWithoutReplacingPlacementAndReturnsWhenReconnected() {
        let primary = placementScreen(id: 1, uuid: "primary", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
        let secondary = placementScreen(id: 2, uuid: "secondary", frame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        let placement = UsageOverlayPlacement(
            display: secondary.identity,
            frame: CGRect(x: -200, y: 600, width: 108, height: 180),
            visibleFrame: secondary.visibleFrame
        )
        var screens = [primary]
        var saves = 0
        var screenCallbacks: [@MainActor () -> Void] = []
        let panel = makeUnconstrainedPanel(x: 900, y: 400, width: 108, height: 180)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: {
                UsageOverlayScreen.match(identity: placement.display, in: screens)?.visibleFrame
                    ?? primary.visibleFrame
            },
            screenProvider: placementScreenProvider(screens: { screens }, windowScreen: { primary }),
            placementPersistence: .init(
                load: { placement },
                save: { _ in saves += 1; return true },
                loadLegacyFrame: { nil },
                removeLegacyFrame: {}
            ),
            deferredScreenResizeScheduler: { screenCallbacks.append($0) },
            fittingSizeProvider: { CGSize(width: 108, height: 180) }
        )

        controller.showForCurrentSession(using: .init(isVisible: true, displayMode: .compact))
        drainMainQueueSynchronously()
        XCTAssertGreaterThanOrEqual(panel.frame.minX, primary.visibleFrame.minX + 16)
        XCTAssertEqual(saves, 0)

        screens = [primary, secondary]
        controller.handleScreenGeometryChange()
        screenCallbacks.removeLast()()

        XCTAssertEqual(panel.frame.maxX, -92)
        XCTAssertEqual(panel.frame.maxY, 780)
        XCTAssertEqual(saves, 0)
    }

    func testLegacyAutosaveMigratesToPlacementAndIsRemoved() {
        let screen = placementScreen(id: 2, uuid: "secondary", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1410))
        var savedPlacement: UsageOverlayPlacement?
        var removedLegacy = false
        let panel = makeUnconstrainedPanel(x: 0, y: 0, width: 108, height: 359)
        let controller = UsageOverlayWindowController(
            panel: panel,
            initialDisplayMode: .compact,
            shouldReduceMotion: { true },
            visibleFrameProvider: { screen.visibleFrame },
            screenProvider: placementScreenProvider(screens: { [screen] }, windowScreen: { screen }),
            placementPersistence: .init(
                load: { nil },
                save: { savedPlacement = $0; return true },
                loadLegacyFrame: { "-124 1035 108 359 -2560 0 2560 1410 " },
                removeLegacyFrame: { removedLegacy = true }
            ),
            fittingSizeProvider: { CGSize(width: 108, height: 359) }
        )

        controller.showForCurrentSession(using: .init(isVisible: true, displayMode: .compact))
        drainMainQueueSynchronously()

        XCTAssertEqual(savedPlacement?.display, screen.identity)
        XCTAssertTrue(removedLegacy)
        XCTAssertEqual(panel.frame, CGRect(x: -124, y: 1035, width: 108, height: 359))
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

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func placementScreenProvider(
        screens: @escaping () -> [UsageOverlayScreen],
        windowScreen: @escaping () -> UsageOverlayScreen?
    ) -> UsageOverlayScreenProvider {
        UsageOverlayScreenProvider(
            screens: screens,
            screenForWindow: { _ in windowScreen() }
        )
    }

    private func placementScreen(
        id: CGDirectDisplayID,
        uuid: String,
        frame: CGRect,
        isPrimary: Bool = false
    ) -> UsageOverlayScreen {
        UsageOverlayScreen(
            displayID: id,
            identity: UsageOverlayDisplayIdentity(
                uuid: uuid,
                vendorNumber: 1,
                modelNumber: 2,
                serialNumber: id
            ),
            frame: frame,
            visibleFrame: frame,
            isPrimary: isPrimary
        )
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

    private func makeUnconstrainedPanel(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> NSPanel {
        UnconstrainedTestPanel(
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

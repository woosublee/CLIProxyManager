import AppKit
import CLIProxyManagerCore
import Combine
import QuartzCore
import SwiftUI

struct UsageOverlayResizeCoordinator {
    struct Request {
        let animated: Bool
        let transitionGeneration: Int?
    }

    private var nextGeneration = 0
    private var activeTransitionGeneration: Int?
    private var activeAnimationCount = 0
    private var pendingAnimation = false
    private var resizeScheduled = false
    private var transitionAnchor: CGPoint?

    mutating func beginModeTransition(anchor: CGPoint) -> Int {
        nextGeneration += 1
        activeTransitionGeneration = nextGeneration
        activeAnimationCount = 0
        pendingAnimation = true
        transitionAnchor = anchor
        return nextGeneration
    }

    var authoritativeAnchor: CGPoint? {
        activeTransitionGeneration == nil ? nil : transitionAnchor
    }

    var hasActiveTransition: Bool {
        activeTransitionGeneration != nil
    }

    mutating func requestResize(animated: Bool) -> Bool {
        pendingAnimation = pendingAnimation || animated || activeTransitionGeneration != nil
        guard !resizeScheduled else { return false }
        resizeScheduled = true
        return true
    }

    mutating func consumeResizeRequest() -> Request {
        resizeScheduled = false
        let animated = pendingAnimation || activeTransitionGeneration != nil
        pendingAnimation = false
        return Request(
            animated: animated,
            transitionGeneration: animated ? activeTransitionGeneration : nil
        )
    }

    mutating func animationStarted(generation: Int?) {
        guard generation == activeTransitionGeneration, generation != nil else { return }
        activeAnimationCount += 1
    }

    mutating func animationCompleted(generation: Int?) {
        guard generation == activeTransitionGeneration, generation != nil else { return }
        activeAnimationCount = max(0, activeAnimationCount - 1)
        if activeAnimationCount == 0, !resizeScheduled {
            clearActiveTransition()
        }
    }

    mutating func transitionCompletedWithoutAnimation(generation: Int?) {
        guard generation == activeTransitionGeneration, generation != nil else { return }
        activeAnimationCount = 0
        pendingAnimation = false
        if !resizeScheduled {
            clearActiveTransition()
        }
    }

    mutating func cancelActiveTransition() {
        nextGeneration += 1
        activeTransitionGeneration = nil
        activeAnimationCount = 0
        pendingAnimation = false
        resizeScheduled = false
        transitionAnchor = nil
    }

    private mutating func clearActiveTransition() {
        activeTransitionGeneration = nil
        transitionAnchor = nil
    }
}

@MainActor
final class UsageOverlayWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let panel: NSPanel
    private let presentationState: UsageOverlayPresentationState
    private let persistDisplayMode: (AppConfig.UsageOverlay.DisplayMode) -> Bool
    private let refreshStatusOnShow: () -> Void
    private let shouldReduceMotion: () -> Bool
    private let visibleFrameProvider: () -> CGRect?
    private let screenVisibleFrameProvider: () -> CGRect?
    private let screenProvider: UsageOverlayScreenProvider
    private let placementPersistence: UsageOverlayPlacementPersistence
    private let deferredScreenResizeScheduler: (@escaping @MainActor () -> Void) -> Void
    private let modeTransitionResizeScheduler: (@escaping @MainActor () -> Void) -> Void
    private let fittingSizeProvider: (() -> CGSize)?
    private let frameAnimator: (NSPanel, CGRect, @escaping @MainActor () -> Void) -> Void
    private let frameAnimationInterrupter: (NSPanel) -> Void
    private let isUserInitiatedMoveDuringAnimation: () -> Bool
    private struct PersistenceTransaction {
        let generation: Int
        let target: AppConfig.UsageOverlay.DisplayMode
        let original: AppConfig.UsageOverlay.DisplayMode
        var recordedEmissions: [AppConfig.UsageOverlay.DisplayMode] = []
        var queuedEmissionsToIgnore: [AppConfig.UsageOverlay.DisplayMode] = []
    }

    private struct FailedPersistenceOverride {
        let generation: Int
        let mode: AppConfig.UsageOverlay.DisplayMode
        var awaitsLaterAcknowledgement: Bool
    }

    private var nextPersistenceGeneration = 0
    private var failedPersistenceOverride: FailedPersistenceOverride?
    private var persistenceTransaction: PersistenceTransaction?
    private var resizeCoordinator = UsageOverlayResizeCoordinator()
    private var resizeScheduleGeneration = 0
    private var isWaitingForModeTransitionResize = false
    private var screenGeometryGeneration = 0
    private var userMoveInterruptedTransition = false
    private var isUserMoveInProgress = false
    private var isApplyingControllerFrame = false
    private var isUsingTemporaryScreenFallback = false
    private var savedPlacement: UsageOverlayPlacement?
    private var configObservation: AnyCancellable?
    private var contentObservation: AnyCancellable?
    private var screenParametersObservation: NSObjectProtocol?
    private var lastSavedVisibility: Bool?
    private var isSuppressedForCurrentSession = false

    @Published private(set) var isVisible = false
    var displayMode: AppConfig.UsageOverlay.DisplayMode { presentationState.displayMode }
    var presentedDisplayMode: AppConfig.UsageOverlay.DisplayMode {
        presentationState.presentedDisplayMode
    }
    var isContentHiddenForModeTransition: Bool {
        presentationState.isContentHiddenForModeTransition
    }
    var compactAccountMaximumHeight: CGFloat { presentationState.compactAccountMaximumHeight }
    var window: NSWindow { panel }

    init(
        panel: NSPanel? = nil,
        viewModel: DashboardViewModel? = nil,
        initialDisplayMode: AppConfig.UsageOverlay.DisplayMode? = nil,
        persistDisplayMode: ((AppConfig.UsageOverlay.DisplayMode) -> Bool)? = nil,
        refreshStatusOnShow: (() -> Void)? = nil,
        usageOverlayPublisher: AnyPublisher<AppConfig.UsageOverlay, Never>? = nil,
        shouldReduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        visibleFrameProvider: (() -> CGRect?)? = nil,
        screenVisibleFrameProvider: (() -> CGRect?)? = nil,
        screenProvider: UsageOverlayScreenProvider = .live,
        placementPersistence: UsageOverlayPlacementPersistence = .disabled,
        deferredScreenResizeScheduler: ((@escaping @MainActor () -> Void) -> Void)? = nil,
        modeTransitionResizeScheduler: ((@escaping @MainActor () -> Void) -> Void)? = nil,
        fittingSizeProvider: (() -> CGSize)? = nil,
        frameAnimator: ((NSPanel, CGRect, @escaping @MainActor () -> Void) -> Void)? = nil,
        frameAnimationInterrupter: ((NSPanel) -> Void)? = nil,
        isUserInitiatedMoveDuringAnimation: @escaping () -> Bool = {
            NSEvent.pressedMouseButtons != 0
        }
    ) {
        let suppliedPanelFrame = panel?.frame
        let mode = initialDisplayMode ?? viewModel?.config.usageOverlay.displayMode ?? .expanded
        self.presentationState = UsageOverlayPresentationState(displayMode: mode)
        self.shouldReduceMotion = shouldReduceMotion
        self.visibleFrameProvider = visibleFrameProvider ?? { nil }
        self.screenVisibleFrameProvider = screenVisibleFrameProvider ?? { nil }
        self.screenProvider = screenProvider
        self.placementPersistence = placementPersistence
        self.savedPlacement = placementPersistence.load()
        self.deferredScreenResizeScheduler = deferredScreenResizeScheduler ?? { action in
            DispatchQueue.main.async { @MainActor in
                action()
            }
        }
        self.modeTransitionResizeScheduler = modeTransitionResizeScheduler ?? { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { @MainActor in
                action()
            }
        }
        self.fittingSizeProvider = fittingSizeProvider
        self.frameAnimator = frameAnimator ?? { panel, target, completion in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            } completionHandler: {
                Task { @MainActor in completion() }
            }
        }
        self.frameAnimationInterrupter = frameAnimationInterrupter ?? { panel in
            panel.setFrame(panel.frame, display: true, animate: false)
        }
        self.isUserInitiatedMoveDuringAnimation = isUserInitiatedMoveDuringAnimation
        self.persistDisplayMode = persistDisplayMode ?? { [weak viewModel] mode in
            guard let viewModel else { return true }
            var usageOverlay = viewModel.config.usageOverlay
            usageOverlay.displayMode = mode
            return viewModel.saveSetting {
                try viewModel.saveUsageOverlay(usageOverlay)
            }
        }
        self.refreshStatusOnShow = refreshStatusOnShow ?? { [weak viewModel] in
            Task { [weak viewModel] in
                await viewModel?.refresh()
            }
        }
        self.panel = panel ?? NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: mode == .expanded
                    ? AppWindowMetrics.usageOverlayExpandedWidth
                    : AppWindowMetrics.usageOverlayCompactWidth,
                height: AppWindowMetrics.usageOverlayExpandedMinimumHeight
            ),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanelAndContent(
            viewModel: viewModel,
            usageOverlayPublisher: usageOverlayPublisher
        )
        if let suppliedPanelFrame {
            applyControllerFrame(suppliedPanelFrame, display: false)
        }
        screenParametersObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenGeometryChange()
            }
        }
    }

    deinit {
        if let screenParametersObservation {
            NotificationCenter.default.removeObserver(screenParametersObservation)
        }
    }

    static func isFrameUsable(_ frame: CGRect, within screenFrames: [CGRect]) -> Bool {
        screenFrames.contains { screenFrame in
            let visibleArea = frame.intersection(screenFrame)
            return visibleArea.width >= min(100, frame.width / 2)
                && visibleArea.height >= min(100, frame.height / 2)
        }
    }

    func toggleDisplayMode() {
        let original = displayMode
        let target = original.opposite
        let transitionAnchor = resizeCoordinator.authoritativeAnchor
            ?? CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let reduceMotion = shouldReduceMotion()
        presentationState.displayMode = target
        if reduceMotion {
            presentationState.presentedDisplayMode = target
            presentationState.isContentHiddenForModeTransition = false
        } else {
            presentationState.presentedDisplayMode = target == .compact ? original : target
            presentationState.isContentHiddenForModeTransition = true
        }
        updatePanelConstraints(for: target)
        _ = resizeCoordinator.beginModeTransition(anchor: transitionAnchor)

        nextPersistenceGeneration += 1
        let generation = nextPersistenceGeneration
        persistenceTransaction = PersistenceTransaction(
            generation: generation,
            target: target,
            original: original
        )
        let didPersist = persistDisplayMode(target)
        if didPersist {
            failedPersistenceOverride = nil
            persistenceTransaction = nil
        } else {
            let recordedEmissions = persistenceTransaction?.recordedEmissions ?? []
            failedPersistenceOverride = FailedPersistenceOverride(
                generation: generation,
                mode: target,
                awaitsLaterAcknowledgement: true
            )
            if recordedEmissions.isEmpty {
                persistenceTransaction = nil
            } else {
                persistenceTransaction?.queuedEmissionsToIgnore = recordedEmissions
            }
        }

        if reduceMotion {
            isWaitingForModeTransitionResize = false
            resizeToFittingContentImmediately(animated: true)
        } else {
            isWaitingForModeTransitionResize = true
            _ = resizeCoordinator.requestResize(animated: true)
            modeTransitionResizeScheduler { @MainActor [weak self] in
                guard let self, self.isWaitingForModeTransitionResize else { return }
                self.isWaitingForModeTransitionResize = false
                self.resizeScheduleGeneration += 1
                self.performScheduledResize()
            }
        }
    }

    func updateContentSize(_ size: CGSize, animated: Bool = false) {
        updateContentSize(size, animated: animated, transitionGeneration: nil)
    }

    private func updateContentSize(
        _ size: CGSize,
        animated: Bool,
        transitionGeneration: Int?
    ) {
        let anchorFrame = frameAnchoredAtAuthoritativeTransitionAnchor()
        guard let visibleFrame = currentVisibleFrame() else {
            applyControllerFrame(
                fallbackFrame(targetContentHeight: size.height, currentFrame: anchorFrame),
                display: true
            )
            resizeCoordinator.transitionCompletedWithoutAnimation(generation: transitionGeneration)
            presentationState.presentedDisplayMode = displayMode
            presentationState.isContentHiddenForModeTransition = false
            return
        }
        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: anchorFrame,
            targetContentHeight: size.height,
            mode: displayMode,
            visibleFrame: visibleFrame
        )
        let shouldAnimate = animated && !shouldReduceMotion()

        guard shouldAnimate else {
            applyControllerFrame(target, display: true)
            resizeCoordinator.transitionCompletedWithoutAnimation(generation: transitionGeneration)
            presentationState.presentedDisplayMode = displayMode
            presentationState.isContentHiddenForModeTransition = false
            return
        }

        resizeCoordinator.animationStarted(generation: transitionGeneration)
        isApplyingControllerFrame = true
        frameAnimator(panel, target) { [weak self] in
            guard let self else { return }
            self.isApplyingControllerFrame = false
            self.resizeCoordinator.animationCompleted(generation: transitionGeneration)
            if !self.resizeCoordinator.hasActiveTransition {
                self.presentationState.presentedDisplayMode = self.displayMode
                self.presentationState.isContentHiddenForModeTransition = false
            }
        }
    }

    func hideForCurrentSession() {
        isSuppressedForCurrentSession = true
        userMoveInterruptedTransition = false
        interruptActiveTransition()
        panel.orderOut(nil)
        isVisible = false
    }

    func windowWillMove(_ notification: Notification) {
        handleWindowWillMove()
    }

    func handleWindowWillMove() {
        if isApplyingControllerFrame, !isUserInitiatedMoveDuringAnimation() {
            return
        }
        isUserMoveInProgress = true
        guard resizeCoordinator.hasActiveTransition else { return }
        interruptActiveTransition()
        userMoveInterruptedTransition = true
    }

    func windowDidMove(_ notification: Notification) {
        handleWindowDidMove()
    }

    func handleWindowDidMove() {
        guard isUserMoveInProgress else { return }
        isUserMoveInProgress = false
        saveCurrentPlacement()
        if userMoveInterruptedTransition {
            userMoveInterruptedTransition = false
            resizeToFittingContent(animated: false)
        }
    }

    func requestContentResize(animated: Bool = false) {
        resizeToFittingContent(animated: animated)
    }

    func showForCurrentSession(using preferences: AppConfig.UsageOverlay) {
        isSuppressedForCurrentSession = false
        UsageOverlayWindowConfigurator().configure(
            window: panel,
            alwaysOnTop: preferences.alwaysOnTop
        )
        restoreSavedPlacement()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        resizeToFittingContent(animated: false)
        refreshStatusOnShow()
    }

    func update(_ preferences: AppConfig.UsageOverlay) {
        let savedVisibilityBecameEnabled = lastSavedVisibility == false && preferences.isVisible
        if savedVisibilityBecameEnabled {
            isSuppressedForCurrentSession = false
        }
        lastSavedVisibility = preferences.isVisible

        UsageOverlayWindowConfigurator().configure(
            window: panel,
            alwaysOnTop: preferences.alwaysOnTop
        )
        if var transaction = persistenceTransaction,
           transaction.queuedEmissionsToIgnore.first == preferences.displayMode {
            transaction.queuedEmissionsToIgnore.removeFirst()
            persistenceTransaction = transaction.queuedEmissionsToIgnore.isEmpty ? nil : transaction
        } else if let override = failedPersistenceOverride,
                  override.awaitsLaterAcknowledgement,
                  preferences.displayMode == override.mode {
            failedPersistenceOverride = nil
        } else {
            applyPersistedDisplayModeIfAllowed(preferences.displayMode)
        }
        if preferences.isVisible, !isSuppressedForCurrentSession {
            if !isVisible {
                restoreSavedPlacement()
            }
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            resizeToFittingContent(animated: false)
        } else if !preferences.isVisible {
            userMoveInterruptedTransition = false
            interruptActiveTransition()
            panel.orderOut(nil)
            isVisible = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideForCurrentSession()
        return false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        handleScreenGeometryChange()
    }

    func handleScreenGeometryChange() {
        guard !isUserMoveInProgress else { return }
        userMoveInterruptedTransition = false
        interruptActiveTransition()
        updatePanelConstraints(for: displayMode)
        screenGeometryGeneration += 1
        let generation = screenGeometryGeneration
        deferredScreenResizeScheduler { @MainActor [weak self] in
            guard let self, generation == self.screenGeometryGeneration else { return }
            if self.savedPlacement != nil || self.isUsingTemporaryScreenFallback {
                self.restoreSavedPlacement(allowMigration: false)
            }
            self.panel.contentView?.layoutSubtreeIfNeeded()
            let fittingSize = self.fittingSizeProvider?()
                ?? self.panel.contentView?.fittingSize
                ?? self.panel.frame.size
            self.updateContentSize(fittingSize, animated: false)
        }
    }

    private func configurePanelAndContent(
        viewModel: DashboardViewModel?,
        usageOverlayPublisher: AnyPublisher<AppConfig.UsageOverlay, Never>?
    ) {
        panel.delegate = self
        panel.title = "Usage"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        updatePanelConstraints(for: displayMode)

        let publisher = usageOverlayPublisher
            ?? viewModel?.$config.map(\.usageOverlay).eraseToAnyPublisher()
        configObservation = publisher?
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.recordPersistenceEmission(preferences.displayMode)
                DispatchQueue.main.async {
                    self?.update(preferences)
                }
            }

        guard let viewModel else { return }
        let surfaceView = UsageOverlaySurfaceView(
            rootView: UsageOverlayView(
                viewModel: viewModel,
                presentationState: presentationState,
                onContentSizeInvalidated: { [weak self] in
                    self?.resizeToFittingContent(animated: false)
                }
            ),
            viewModel: viewModel,
            presentationState: presentationState,
            onToggleDisplayMode: { [weak self] in self?.toggleDisplayMode() },
            onClose: { [weak self] in self?.hideForCurrentSession() }
        )
        surfaceView.frame = panel.contentLayoutRect
        surfaceView.autoresizingMask = [.width, .height]
        panel.contentView = surfaceView
        contentObservation = viewModel.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible else { return }
                    self.resizeToFittingContent(animated: false)
                }
            }
    }

    private func restoreSavedPlacement(allowMigration: Bool = true) {
        let screens = screenProvider.screens()
        if savedPlacement == nil, allowMigration {
            migrateLegacyPlacement(in: screens)
        }
        if let savedPlacement,
           let screen = UsageOverlayScreen.match(identity: savedPlacement.display, in: screens) {
            isUsingTemporaryScreenFallback = false
            applyControllerFrame(
                UsageOverlayFrameLayout.placementFrame(
                    size: panel.frame.size,
                    rightOffset: savedPlacement.rightOffset,
                    topOffset: savedPlacement.topOffset,
                    visibleFrame: screen.visibleFrame
                ),
                display: false
            )
            return
        }

        isUsingTemporaryScreenFallback = savedPlacement != nil
        let screen = screenProvider.screenForWindow(panel)
            ?? screens.first(where: \.isPrimary)
            ?? screens.first
        guard let screen else { return }
        let fallback = UsageOverlayFrameLayout.clampedFrame(panel.frame, visibleFrame: screen.visibleFrame)
        if Self.isFrameUsable(fallback, within: [screen.visibleFrame]) {
            applyControllerFrame(fallback, display: false)
        } else {
            applyControllerFrame(centeredFrame(in: screen.visibleFrame), display: false)
        }
    }

    private func migrateLegacyPlacement(in screens: [UsageOverlayScreen]) {
        guard let descriptor = placementPersistence.loadLegacyFrame(),
              let legacy = LegacyUsageOverlayFrame(descriptor: descriptor),
              let screen = legacy.matchingScreen(in: screens) else {
            return
        }
        let placement = UsageOverlayPlacement(
            display: screen.identity,
            frame: legacy.windowFrame,
            visibleFrame: screen.visibleFrame
        )
        guard placementPersistence.save(placement) else { return }
        savedPlacement = placement
        placementPersistence.removeLegacyFrame()
    }

    private func saveCurrentPlacement() {
        let screens = screenProvider.screens()
        guard let screen = screenProvider.screenForWindow(panel)
                ?? screens.max(by: {
                    panel.frame.intersection($0.visibleFrame).area
                        < panel.frame.intersection($1.visibleFrame).area
                }) else {
            return
        }
        let placement = UsageOverlayPlacement(
            display: screen.identity,
            frame: panel.frame,
            visibleFrame: screen.visibleFrame
        )
        savedPlacement = placement
        isUsingTemporaryScreenFallback = false
        if placementPersistence.save(placement) {
            placementPersistence.removeLegacyFrame()
        }
    }

    private func centeredFrame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    private func recordPersistenceEmission(_ mode: AppConfig.UsageOverlay.DisplayMode) {
        guard var transaction = persistenceTransaction else { return }
        transaction.recordedEmissions.append(mode)
        persistenceTransaction = transaction
    }

    private func applyPersistedDisplayModeIfAllowed(_ mode: AppConfig.UsageOverlay.DisplayMode) {
        guard failedPersistenceOverride == nil, presentationState.displayMode != mode else { return }
        presentationState.displayMode = mode
        presentationState.presentedDisplayMode = mode
        updatePanelConstraints(for: mode)
    }

    private func updatePanelConstraints(for mode: AppConfig.UsageOverlay.DisplayMode) {
        let visibleHeight = currentVisibleFrame()?.height ?? AppWindowMetrics.usageOverlayMaximumHeight
        let maximumHeight = min(
            AppWindowMetrics.usageOverlayMaximumHeight,
            max(72, visibleHeight - AppWindowMetrics.usageOverlayScreenMargin * 2)
        )

        // NSPanel applies width constraints immediately. Keep the current frame untouched so
        // the single layout target owns the visible width/height transition.
        panel.contentMinSize = CGSize(width: 1, height: 1)
        panel.contentMaxSize = CGSize(
            width: max(AppWindowMetrics.usageOverlayExpandedWidth, AppWindowMetrics.usageOverlayCompactWidth),
            height: maximumHeight
        )
        presentationState.compactAccountMaximumHeight = max(72, maximumHeight - 52)
    }

    private func currentVisibleFrame() -> CGRect? {
        visibleFrameProvider()
            ?? screenVisibleFrameProvider()
            ?? panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    private func interruptActiveTransition() {
        isWaitingForModeTransitionResize = false
        resizeScheduleGeneration += 1
        if resizeCoordinator.hasActiveTransition {
            frameAnimationInterrupter(panel)
        }
        isApplyingControllerFrame = false
        resizeCoordinator.cancelActiveTransition()
    }

    private func applyControllerFrame(_ frame: CGRect, display: Bool) {
        isApplyingControllerFrame = true
        panel.setFrame(frame, display: display)
        isApplyingControllerFrame = false
    }

    private func frameAnchoredAtAuthoritativeTransitionAnchor() -> CGRect {
        guard let anchor = resizeCoordinator.authoritativeAnchor else { return panel.frame }
        return CGRect(
            x: anchor.x - panel.frame.width,
            y: anchor.y - panel.frame.height,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    private func fallbackFrame(targetContentHeight: CGFloat, currentFrame: CGRect) -> CGRect {
        let width = displayMode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedWidth
            : AppWindowMetrics.usageOverlayCompactWidth
        let minimumHeight = displayMode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedMinimumHeight
            : 72
        let height = min(
            max(targetContentHeight, minimumHeight),
            AppWindowMetrics.usageOverlayMaximumHeight
        )
        return CGRect(
            x: currentFrame.maxX - width,
            y: currentFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func resizeToFittingContentImmediately(animated: Bool) {
        guard resizeCoordinator.requestResize(animated: animated) else { return }
        resizeScheduleGeneration += 1
        performScheduledResize()
    }

    private func resizeToFittingContent(animated: Bool) {
        guard resizeCoordinator.requestResize(animated: animated) else { return }
        resizeScheduleGeneration += 1
        let scheduleGeneration = resizeScheduleGeneration
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, scheduleGeneration == self.resizeScheduleGeneration else { return }
            self.performScheduledResize()
        }
    }

    private func transitionFittingSize() -> CGSize? {
        guard displayMode == .compact else { return nil }
        return presentationState.compactFittingSize
            ?? CGSize(
                width: AppWindowMetrics.usageOverlayCompactWidth,
                height: CompactUsageMeasurementState.estimatedHeight + 44
            )
    }

    private func performScheduledResize() {
        let request = resizeCoordinator.consumeResizeRequest()
        guard let contentView = panel.contentView else {
            resizeCoordinator.transitionCompletedWithoutAnimation(
                generation: request.transitionGeneration
            )
            return
        }
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = fittingSizeProvider?()
            ?? transitionFittingSize()
            ?? contentView.fittingSize
        updateContentSize(
            fittingSize,
            animated: request.animated,
            transitionGeneration: request.transitionGeneration
        )
    }
}

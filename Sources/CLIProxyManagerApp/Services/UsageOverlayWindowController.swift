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
    private let shouldReduceMotion: () -> Bool
    private let visibleFrameProvider: () -> CGRect?
    private let screenVisibleFrameProvider: () -> CGRect?
    private let deferredScreenResizeScheduler: (@escaping @MainActor () -> Void) -> Void
    private let fittingSizeProvider: (() -> CGSize)?
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
    private var screenGeometryGeneration = 0
    private var configObservation: AnyCancellable?
    private var contentObservation: AnyCancellable?
    private var screenParametersObservation: NSObjectProtocol?

    @Published private(set) var isVisible = false
    var displayMode: AppConfig.UsageOverlay.DisplayMode { presentationState.displayMode }
    var compactAccountMaximumHeight: CGFloat { presentationState.compactAccountMaximumHeight }
    var window: NSWindow { panel }

    init(
        panel: NSPanel? = nil,
        viewModel: DashboardViewModel? = nil,
        initialDisplayMode: AppConfig.UsageOverlay.DisplayMode? = nil,
        persistDisplayMode: ((AppConfig.UsageOverlay.DisplayMode) -> Bool)? = nil,
        usageOverlayPublisher: AnyPublisher<AppConfig.UsageOverlay, Never>? = nil,
        shouldReduceMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        },
        visibleFrameProvider: (() -> CGRect?)? = nil,
        screenVisibleFrameProvider: (() -> CGRect?)? = nil,
        deferredScreenResizeScheduler: ((@escaping @MainActor () -> Void) -> Void)? = nil,
        fittingSizeProvider: (() -> CGSize)? = nil
    ) {
        let suppliedPanelFrame = panel?.frame
        let mode = initialDisplayMode ?? viewModel?.config.usageOverlay.displayMode ?? .expanded
        self.presentationState = UsageOverlayPresentationState(displayMode: mode)
        self.shouldReduceMotion = shouldReduceMotion
        self.visibleFrameProvider = visibleFrameProvider ?? { nil }
        self.screenVisibleFrameProvider = screenVisibleFrameProvider ?? { nil }
        self.deferredScreenResizeScheduler = deferredScreenResizeScheduler ?? { action in
            DispatchQueue.main.async { @MainActor in
                action()
            }
        }
        self.fittingSizeProvider = fittingSizeProvider
        self.persistDisplayMode = persistDisplayMode ?? { [weak viewModel] mode in
            guard let viewModel else { return true }
            var usageOverlay = viewModel.config.usageOverlay
            usageOverlay.displayMode = mode
            return viewModel.saveSetting {
                try viewModel.saveUsageOverlay(usageOverlay)
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
            self.panel.setFrame(suppliedPanelFrame, display: false)
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
        let transitionAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        presentationState.displayMode = target
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

        resizeToFittingContent(animated: true)
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
            panel.setFrame(fallbackFrame(targetContentHeight: size.height, currentFrame: anchorFrame), display: true)
            resizeCoordinator.transitionCompletedWithoutAnimation(generation: transitionGeneration)
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
            panel.setFrame(target, display: true)
            resizeCoordinator.transitionCompletedWithoutAnimation(generation: transitionGeneration)
            return
        }

        resizeCoordinator.animationStarted(generation: transitionGeneration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.resizeCoordinator.animationCompleted(generation: transitionGeneration)
            }
        }
    }

    func hideForCurrentSession() {
        panel.orderOut(nil)
        isVisible = false
    }

    func showForCurrentSession(using preferences: AppConfig.UsageOverlay) {
        UsageOverlayWindowConfigurator().configure(
            window: panel,
            alwaysOnTop: preferences.alwaysOnTop
        )
        restoreSavedFrameIfUsable()
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        resizeToFittingContent(animated: false)
    }

    func update(_ preferences: AppConfig.UsageOverlay) {
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
        if preferences.isVisible {
            restoreSavedFrameIfUsable()
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            resizeToFittingContent(animated: false)
        } else {
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
        updatePanelConstraints(for: displayMode)
        screenGeometryGeneration += 1
        let generation = screenGeometryGeneration
        deferredScreenResizeScheduler { @MainActor [weak self] in
            guard let self, generation == self.screenGeometryGeneration else { return }
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
        panel.setFrameAutosaveName("usage-overlay")
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
        panel.contentView = NSHostingView(
            rootView: UsageOverlayView(
                viewModel: viewModel,
                presentationState: presentationState,
                onToggleDisplayMode: { [weak self] in self?.toggleDisplayMode() },
                onContentSizeInvalidated: { [weak self] in
                    self?.resizeToFittingContent(animated: false)
                },
                onClose: { [weak self] in self?.hideForCurrentSession() }
            )
        )
        contentObservation = viewModel.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible else { return }
                    self.resizeToFittingContent(animated: false)
                }
            }
    }

    private func restoreSavedFrameIfUsable() {
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        guard Self.isFrameUsable(panel.frame, within: screenFrames) else {
            panel.center()
            return
        }
    }

    private func recordPersistenceEmission(_ mode: AppConfig.UsageOverlay.DisplayMode) {
        guard var transaction = persistenceTransaction else { return }
        transaction.recordedEmissions.append(mode)
        persistenceTransaction = transaction
    }

    private func applyPersistedDisplayModeIfAllowed(_ mode: AppConfig.UsageOverlay.DisplayMode) {
        guard failedPersistenceOverride == nil, presentationState.displayMode != mode else { return }
        presentationState.displayMode = mode
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

    private func resizeToFittingContent(animated: Bool) {
        guard resizeCoordinator.requestResize(animated: animated) else { return }
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self else { return }
            let request = self.resizeCoordinator.consumeResizeRequest()
            guard let contentView = self.panel.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            let fittingSize = self.fittingSizeProvider?() ?? contentView.fittingSize
            self.updateContentSize(
                fittingSize,
                animated: request.animated,
                transitionGeneration: request.transitionGeneration
            )
        }
    }
}

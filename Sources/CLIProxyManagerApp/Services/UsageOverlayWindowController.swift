import AppKit
import CLIProxyManagerCore
import Combine
import QuartzCore
import SwiftUI

struct UsageOverlayResizeCoordinator {
    private var pendingAnimation = false
    private var resizeScheduled = false

    mutating func beginModeTransition() {
        pendingAnimation = true
    }

    mutating func requestResize(animated: Bool) -> Bool {
        pendingAnimation = pendingAnimation || animated
        guard !resizeScheduled else { return false }
        resizeScheduled = true
        return true
    }

    mutating func consumeResizeAnimation() -> Bool {
        resizeScheduled = false
        let animated = pendingAnimation
        pendingAnimation = false
        return animated
    }
}

@MainActor
final class UsageOverlayWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let panel: NSPanel
    private let presentationState: UsageOverlayPresentationState
    private let persistDisplayMode: (AppConfig.UsageOverlay.DisplayMode) -> Bool
    private let shouldReduceMotion: () -> Bool
    private let visibleFrameProvider: () -> CGRect?
    private struct PersistenceTransaction {
        let target: AppConfig.UsageOverlay.DisplayMode
        let original: AppConfig.UsageOverlay.DisplayMode
        var didObserveTarget = false
        var didObserveRollback = false
    }

    private var failedPersistenceOverride: AppConfig.UsageOverlay.DisplayMode?
    private var persistenceTransaction: PersistenceTransaction?
    private var resizeCoordinator = UsageOverlayResizeCoordinator()
    private var configObservation: AnyCancellable?
    private var contentObservation: AnyCancellable?

    @Published private(set) var isVisible = false
    var displayMode: AppConfig.UsageOverlay.DisplayMode { presentationState.displayMode }
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
        visibleFrameProvider: (() -> CGRect?)? = nil
    ) {
        let suppliedPanelFrame = panel?.frame
        let mode = initialDisplayMode ?? viewModel?.config.usageOverlay.displayMode ?? .expanded
        self.presentationState = UsageOverlayPresentationState(displayMode: mode)
        self.shouldReduceMotion = shouldReduceMotion
        self.visibleFrameProvider = visibleFrameProvider ?? { nil }
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
        presentationState.displayMode = target
        updatePanelConstraints(for: target)
        resizeCoordinator.beginModeTransition()

        persistenceTransaction = PersistenceTransaction(target: target, original: original)
        let didPersist = persistDisplayMode(target)
        failedPersistenceOverride = didPersist ? nil : target
        if persistenceTransaction?.didObserveRollback == true || !didPersist {
            persistenceTransaction = nil
        }

        resizeToFittingContent(animated: true)
    }

    func updateContentSize(_ size: CGSize, animated: Bool = false) {
        guard let visibleFrame = currentVisibleFrame() else {
            panel.setContentSize(size)
            return
        }
        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: panel.frame,
            targetContentHeight: size.height,
            mode: displayMode,
            visibleFrame: visibleFrame
        )
        let shouldAnimate = animated && !shouldReduceMotion()

        guard shouldAnimate else {
            panel.setFrame(target, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
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
        if var transaction = persistenceTransaction {
            if preferences.displayMode == transaction.target, !transaction.didObserveTarget {
                transaction.didObserveTarget = true
                persistenceTransaction = transaction
            } else if transaction.didObserveTarget,
                      preferences.displayMode == transaction.original,
                      !transaction.didObserveRollback {
                transaction.didObserveRollback = true
                persistenceTransaction = transaction
            } else {
                persistenceTransaction = nil
                applyPersistedDisplayModeIfAllowed(preferences.displayMode)
            }
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
            ?? panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    private func resizeToFittingContent(animated: Bool) {
        guard resizeCoordinator.requestResize(animated: animated) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldAnimate = self.resizeCoordinator.consumeResizeAnimation()
            guard let contentView = self.panel.contentView else { return }
            self.updateContentSize(contentView.fittingSize, animated: shouldAnimate)
        }
    }
}

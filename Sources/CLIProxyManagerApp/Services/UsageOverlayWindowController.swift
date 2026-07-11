import AppKit
import CLIProxyManagerCore
import Combine
import SwiftUI

@MainActor
final class UsageOverlayWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let panel: NSPanel
    @Published private(set) var isVisible = false
    var window: NSWindow { panel }
    private var configObservation: AnyCancellable?
    private var contentObservation: AnyCancellable?

    init(panel: NSPanel? = nil, viewModel: DashboardViewModel? = nil) {
        self.panel = panel ?? NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppWindowMetrics.usageOverlayWidth,
                height: AppWindowMetrics.usageOverlayHeight
            ),
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        self.panel.delegate = self
        self.panel.title = "Usage"
        self.panel.isReleasedWhenClosed = false
        self.panel.hidesOnDeactivate = false
        self.panel.setFrameAutosaveName("usage-overlay")
        if let viewModel {
            let contentView = NSHostingView(
                rootView: UsageOverlayView(
                    viewModel: viewModel,
                    onClose: { [weak self] in self?.hideForCurrentSession() }
                )
            )
            self.panel.contentView = contentView
            self.panel.contentMinSize = CGSize(
                width: AppWindowMetrics.usageOverlayWidth,
                height: AppWindowMetrics.usageOverlayHeight
            )
            self.panel.contentMaxSize = CGSize(
                width: AppWindowMetrics.usageOverlayWidth,
                height: 720
            )
            self.configObservation = viewModel.$config
                .map(\.usageOverlay)
                .removeDuplicates()
                .sink { [weak self] preferences in
                    DispatchQueue.main.async {
                        self?.update(preferences)
                    }
                }
            self.contentObservation = viewModel.objectWillChange
                .sink { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.panel.isVisible, let contentView = self.panel.contentView else { return }
                        self.updateContentSize(contentView.fittingSize)
                    }
                }
        }
    }

    static func isFrameUsable(_ frame: CGRect, within screenFrames: [CGRect]) -> Bool {
        screenFrames.contains { screenFrame in
            let visibleArea = frame.intersection(screenFrame)
            return visibleArea.width >= min(100, frame.width / 2)
                && visibleArea.height >= min(100, frame.height / 2)
        }
    }

    private func restoreSavedFrameIfUsable() {
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        guard Self.isFrameUsable(panel.frame, within: screenFrames) else {
            panel.center()
            return
        }
    }

    func updateContentSize(_ size: CGSize) {
        let clampedHeight = min(max(size.height, AppWindowMetrics.usageOverlayHeight), 720)
        panel.setContentSize(CGSize(width: AppWindowMetrics.usageOverlayWidth, height: clampedHeight))
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
    }

    func update(_ preferences: AppConfig.UsageOverlay) {
        UsageOverlayWindowConfigurator().configure(
            window: panel,
            alwaysOnTop: preferences.alwaysOnTop
        )
        if preferences.isVisible {
            restoreSavedFrameIfUsable()
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let contentView = self.panel.contentView else { return }
                self.updateContentSize(contentView.fittingSize)
            }
        } else {
            panel.orderOut(nil)
            isVisible = false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

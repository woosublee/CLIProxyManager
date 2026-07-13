import AppKit
import SwiftUI

struct MenuBarWindowBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowBridgeView {
        let view = WindowBridgeView()
        view.configureWindow = context.coordinator.configure(window:)
        return view
    }

    func updateNSView(_ view: WindowBridgeView, context: Context) {
        context.coordinator.configure(window: view.window)
    }

    final class Coordinator {
        private let configurator = MenuBarWindowConfigurator()

        func configure(window: NSWindow?) {
            configurator.configure(window: window)
        }
    }
}

final class WindowBridgeView: NSView {
    var configureWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow?(window)
    }
}

@MainActor
final class UsageOverlayWindowConfigurator {
    func configure(window: NSWindow?, alwaysOnTop: Bool) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = alwaysOnTop ? .floating : .normal
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.hasShadow = true
    }
}

final class MenuBarWindowConfigurator {
    private var isResizing = false
    private var resizeScheduled = false
    private weak var scheduledWindow: NSWindow?

    func configure(window: NSWindow?) {
        guard let window else { return }

        window.sharingType = .readOnly
        scheduleResize(for: window)
    }

    private func scheduleResize(for window: NSWindow) {
        scheduledWindow = window
        guard !resizeScheduled else { return }

        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduledWindow()
        }
    }

    private func resizeScheduledWindow() {
        resizeScheduled = false

        guard !isResizing, let window = scheduledWindow, let contentView = window.contentView else { return }

        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        let currentSize = contentView.frame.size
        guard Self.isValid(fittingSize.height), Self.isValid(currentSize.width) else { return }

        let targetSize = NSSize(width: currentSize.width, height: fittingSize.height)
        guard abs(currentSize.height - targetSize.height) > 0.5 else { return }

        isResizing = true
        window.setContentSize(targetSize)
        isResizing = false
    }

    private static func isValid(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value < 10_000
    }
}

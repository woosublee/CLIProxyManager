import AppKit
import SwiftUI

@MainActor
protocol AppControlling: AnyObject {
    func openWindow(id: String)
    func activate()
    func closeKeyWindow()
    func centerSettingsWindow()
}

@MainActor
final class AppWindowController {
    private let appController: any AppControlling

    init(appController: any AppControlling) {
        self.appController = appController
    }

    func openMain() {
        appController.openWindow(id: "main")
        appController.activate()
    }

    func openSettings() {
        appController.openWindow(id: "settings")
        revealSettings()
    }

    func revealSettings() {
        appController.centerSettingsWindow()
        appController.activate()
    }

    func closeSettings() {
        appController.closeKeyWindow()
    }
}

@MainActor
final class SwiftUIAppController: AppControlling {
    private let openWindow: OpenWindowAction

    init(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
    }

    func openWindow(id: String) {
        openWindow(id: id)
    }

    func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeKeyWindow() {
        NSApplication.shared.keyWindow?.performClose(nil)
    }

    func centerSettingsWindow() {
        guard let window = NSApplication.shared.windows.first(where: { $0.title == "Settings" }) else { return }
        let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero }
        if let visibleFrame = primaryScreen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let size = window.frame.size
            let origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

import AppKit
import SwiftUI

@MainActor
protocol AppControlling: AnyObject {
    func openWindow(id: String)
    func activate()
    func closeKeyWindow()
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
        appController.activate()
    }

    func closeKeyWindow() {
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

}

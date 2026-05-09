import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: DashboardViewModel
    @StateObject private var quitCoordinator: QuitCoordinator

    init() {
        let viewModel = DashboardViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _quitCoordinator = StateObject(wrappedValue: QuitCoordinator(shouldStopServerBeforeQuit: {
            viewModel.serverControlState.shouldStopServerBeforeQuit
        }))
    }

    private var appWindowController: AppWindowController {
        AppWindowController(appController: SwiftUIAppController(openWindow: openWindow))
    }

    var body: some Scene {
        WindowGroup("CLIProxyManager", id: "main") {
            DashboardView(
                viewModel: viewModel,
                openSettings: { appWindowController.openSettings() },
                quit: { quitCoordinator.requestQuit() }
            )
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        WindowGroup("Settings", id: "settings") {
            SettingsView(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: AppWindowMetrics.settingsWidth, height: AppWindowMetrics.settingsHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appWindowController.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    appWindowController.closeKeyWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit CLIProxyManager") {
                    quitCoordinator.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarStatusView(
                viewModel: viewModel,
                openMain: {
                    appWindowController.openMain()
                },
                openSettings: {
                    appWindowController.openSettings()
                },
                quit: { quitCoordinator.requestQuit() }
            )
        } label: {
            if let image = AppMarkRenderer.menuBarTemplate() {
                Image(nsImage: image)
            } else {
                Image(systemName: "waveform.path")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

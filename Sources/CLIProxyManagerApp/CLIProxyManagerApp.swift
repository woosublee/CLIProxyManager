import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel = DashboardViewModel()
    @StateObject private var quitCoordinator = QuitCoordinator()

    private var appWindowController: AppWindowController {
        AppWindowController(appController: SwiftUIAppController(openWindow: openWindow))
    }

    var body: some Scene {
        WindowGroup("CLIProxyManager", id: "main") {
            if hasCompletedOnboarding {
                DashboardView(
                    viewModel: viewModel,
                    openSettings: { appWindowController.openSettings() },
                    quit: { quitCoordinator.requestQuit() }
                )
            } else {
                OnboardingView()
                    .toolbar {
                        Button("Get Started") {
                            hasCompletedOnboarding = true
                        }
                    }
            }
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
                    hasCompletedOnboarding = true
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
                    hasCompletedOnboarding = true
                    appWindowController.openMain()
                },
                openSettings: {
                    hasCompletedOnboarding = true
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

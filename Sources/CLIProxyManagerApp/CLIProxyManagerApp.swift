import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(ApplicationTerminationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel: DashboardViewModel
    @StateObject private var quitCoordinator: QuitCoordinator
    @StateObject private var updaterService: UpdaterService
    @StateObject private var cliProxyAPIUpdateService: CLIProxyAPIUpdateService
    @StateObject private var usageOverlayWindowController: UsageOverlayWindowController

    init() {
        let config = LaunchAppearanceBootstrapper().applySavedDockVisibility()
        let viewModel = DashboardViewModel(config: config)
        let cliProxyAPIUpdateService = CLIProxyAPIUpdateService()
        _viewModel = StateObject(wrappedValue: viewModel)
        _cliProxyAPIUpdateService = StateObject(wrappedValue: cliProxyAPIUpdateService)
        _usageOverlayWindowController = StateObject(
            wrappedValue: UsageOverlayWindowController(
                viewModel: viewModel,
                placementPersistence: .userDefaults()
            )
        )
        viewModel.beginApplicationLaunch {
            cliProxyAPIUpdateService.reloadStoredStatus()
        }
        let quitCoordinator = QuitCoordinator(
            shouldStopServerBeforeQuit: {
                viewModel.serverControlState.shouldStopServerBeforeQuit
            },
            beginTermination: {
                viewModel.beginTermination()
            },
            beforeTerminate: {
                try await viewModel.prepareForTermination()
            },
            cancelTerminationPreparation: {
                viewModel.cancelTerminationPreparation()
            }
        )
        _quitCoordinator = StateObject(wrappedValue: quitCoordinator)
        _updaterService = StateObject(wrappedValue: UpdaterService())
        applicationDelegate.quitCoordinator = quitCoordinator
    }

    private var appWindowController: AppWindowController {
        AppWindowController(appController: SwiftUIAppController(openWindow: openWindow))
    }

    var body: some Scene {
        Window("CLIProxyManager", id: "main") {
            DashboardView(
                viewModel: viewModel,
                cliProxyAPIUpdateService: cliProxyAPIUpdateService,
                openSettings: { appWindowController.openSettings() },
                quit: { quitCoordinator.requestQuit() }
            )
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                viewModel: viewModel,
                updaterService: updaterService,
                cliProxyAPIUpdateService: cliProxyAPIUpdateService
            )
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
                isUsageOverlayVisible: usageOverlayWindowController.isVisible,
                toggleUsageOverlay: {
                    if usageOverlayWindowController.isVisible {
                        usageOverlayWindowController.hideForCurrentSession()
                    } else {
                        usageOverlayWindowController.showForCurrentSession(using: viewModel.config.usageOverlay)
                    }
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

import CLIProxyManagerCore
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
    private let buildFlavor: AppBuildFlavor

    init() {
        let buildFlavor = AppBuildFlavor.current
        let appAppearanceService = AppAppearanceService(buildFlavor: buildFlavor)
        self.buildFlavor = buildFlavor

        let config = LaunchAppearanceBootstrapper(
            appAppearanceService: appAppearanceService
        ).applySavedDockVisibility()
        let appLogger = AppLogger(minimumLevel: config.runtimeLogConfiguration.appMinimumLevel)
        let viewModel = DashboardViewModel(
            config: config,
            appAppearanceService: appAppearanceService,
            appLogger: appLogger
        )
        let cliProxyAPIUpdateService = CLIProxyAPIUpdateService(appLogger: appLogger)
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
        _updaterService = StateObject(wrappedValue: UpdaterService(appLogger: appLogger))
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
            MenuBarAppIcon(
                state: MenuBarIconState(
                    serverControlState: viewModel.serverControlState,
                    severity: viewModel.serverStatus.severity
                ),
                buildFlavor: buildFlavor
            )
        }
        .menuBarExtraStyle(.window)
    }
}

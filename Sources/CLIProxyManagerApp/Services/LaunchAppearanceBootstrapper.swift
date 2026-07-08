import CLIProxyManagerCore
import Foundation

@MainActor
struct LaunchAppearanceBootstrapper {
    private let configStore: any AppConfigStoring
    private let appAppearanceService: any AppAppearanceApplying

    init(
        configStore: any AppConfigStoring = AppConfigStore(),
        appAppearanceService: any AppAppearanceApplying = AppAppearanceService()
    ) {
        self.configStore = configStore
        self.appAppearanceService = appAppearanceService
    }

    @discardableResult
    func applySavedDockVisibility() -> AppConfig {
        let config = DashboardViewModel.availableConfig((try? configStore.load()) ?? .default)
        appAppearanceService.apply(showDockIcon: config.showDockIcon)
        return config
    }
}

import CLIProxyManagerCore

struct UsageOverlayAccountButtonPresentation: Equatable {
    let symbolName = "macwindow"
    let accessibilityLabel: String
    let isHighlighted: Bool

    init(showsInUsageOverlay: Bool) {
        accessibilityLabel = showsInUsageOverlay
            ? "Hide from Usage HUD"
            : "Show in Usage HUD"
        isHighlighted = showsInUsageOverlay
    }
}

struct DashboardAccountSnapshot: Equatable, Identifiable {
    enum Status: Equatable {
        case connected
        case disabled
        case disconnected
    }

    let id: ProviderRowState.ID
    let providerType: AuthProfileType
    let title: String
    let commandName: String
    let commandSlug: String
    let detail: String
    let status: Status
    let primaryActionTitle: String
    let showsMoreMenu: Bool
    let isAccountDetailHidden: Bool
    let showsAccountPrivacyToggle: Bool
    let isAPIKeyProfile: Bool
    let showsInUsageOverlay: Bool

    var headerCommandSlug: String {
        commandSlug
    }

    var accountPrivacyToggleAccessibilityLabel: String {
        isAccountDetailHidden ? "Show account detail" : "Hide account detail"
    }

    var usageOverlayButtonPresentation: UsageOverlayAccountButtonPresentation {
        UsageOverlayAccountButtonPresentation(showsInUsageOverlay: showsInUsageOverlay)
    }

    init(provider: ProviderRowState) {
        id = provider.id
        providerType = provider.providerType
        title = provider.displayTitle
        commandName = provider.functionName
        commandSlug = "$ \(provider.functionName)"
        detail = provider.connectionDetail
        if provider.isDisabled {
            status = .disabled
        } else if provider.isConnected {
            status = .connected
        } else {
            status = .disconnected
        }
        primaryActionTitle = status == .disconnected ? "Connect" : "Settings"
        showsMoreMenu = status != .disconnected
        isAccountDetailHidden = provider.accountDetailHidden
        isAPIKeyProfile = provider.id == .claudeAPI || provider.id == .codexAPI
        showsAccountPrivacyToggle = status != .disconnected && !isAPIKeyProfile
        showsInUsageOverlay = provider.showsInUsageOverlay
    }
}

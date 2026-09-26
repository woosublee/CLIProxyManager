import CLIProxyManagerCore
import Foundation

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

    let cooldownState: AccountCooldownState?

    var showsQuotaRecoveryAction: Bool {
        status == .connected && !isAPIKeyProfile
    }

    /// Active local cooldowns only; an empty, unsupported, or unavailable observation shows nothing.
    private var activeCooldownSnapshot: AccountCooldownSnapshot? {
        guard showsQuotaRecoveryAction, let snapshot = cooldownState?.snapshot, !snapshot.cooldowns.isEmpty else {
            return nil
        }
        return snapshot
    }

    var cooldownSummary: String? {
        guard let snapshot = activeCooldownSnapshot else { return nil }
        let count = snapshot.cooldowns.count
        return "Local cooldown · \(count) \(count == 1 ? "restriction" : "restrictions")"
    }

    var cooldownDetail: String? {
        guard let snapshot = activeCooldownSnapshot else { return nil }
        let restrictions = snapshot.cooldowns.map { cooldown in
            let scope = cooldown.scope == "model" ? "Model" : "Credential"
            let model = cooldown.modelKey.map { " · \($0)" } ?? ""
            let reason = cooldown.isQuota ? "Quota" : "Other restriction"
            let retry = cooldown.retryAt.formatted(date: .abbreviated, time: .shortened)
            return "\(scope)\(model) · \(reason) · Retry \(retry)"
        }
        let observed = "Observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))"
        return (restrictions + [observed]).joined(separator: "\n")
    }

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
        isAPIKeyProfile = provider.credentialKind == .apiKey
        showsAccountPrivacyToggle = status != .disconnected && !isAPIKeyProfile
        showsInUsageOverlay = provider.showsInUsageOverlay
        cooldownState = provider.cooldownState
    }
}

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

    var cooldownSummary: String? {
        guard showsQuotaRecoveryAction, let cooldownState else { return nil }
        switch cooldownState {
        case .observed(let snapshot):
            let count = snapshot.cooldowns.count
            return count == 0
                ? "No local cooldown observed"
                : "Local cooldown · \(count) \(count == 1 ? "restriction" : "restrictions")"
        case .unsupported:
            return "Cooldown status unsupported"
        case .unavailable:
            return "Cooldown status unavailable"
        }
    }

    var cooldownDetail: String? {
        guard showsQuotaRecoveryAction, let cooldownState else { return nil }
        switch cooldownState {
        case .observed(let snapshot):
            let observed = "Observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))"
            guard !snapshot.cooldowns.isEmpty else {
                return "\(observed). Other account restrictions may still apply."
            }
            let restrictions = snapshot.cooldowns.map { cooldown in
                let scope = cooldown.scope == "model" ? "Model" : "Credential"
                let model = cooldown.modelKey.map { " · \($0)" } ?? ""
                let reason = cooldown.isQuota ? "Quota" : "Other restriction"
                let retry = cooldown.retryAt.formatted(date: .abbreviated, time: .shortened)
                return "\(scope)\(model) · \(reason) · Retry \(retry)"
            }
            return (restrictions + [observed]).joined(separator: "\n")
        case .unsupported:
            return "This server does not report cooldowns. Manual recovery is still available."
        case .unavailable(let issue):
            return issue.message
        }
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

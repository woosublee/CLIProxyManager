import CLIProxyManagerCore

/// A provider row exposes exactly one kind of usage metric.
enum ProviderUsageState: Equatable {
    case subscription(AccountSubscriptionUsageState)
    case apiCost(APICostUsageState)
}

extension ProviderUsageState {
    var subscriptionCompatibilityState: AccountSubscriptionUsageState {
        guard case let .subscription(state) = self else { return .disabled }
        return state
    }

    var isSubscription: Bool {
        if case .subscription = self { return true }
        return false
    }
}

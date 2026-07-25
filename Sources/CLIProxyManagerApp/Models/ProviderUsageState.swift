import CLIProxyManagerCore

/// A provider row exposes exactly one kind of usage metric.
enum ProviderUsageState: Equatable {
    case subscription(AccountSubscriptionUsageState)
    case apiCost(APICostUsageState)
}

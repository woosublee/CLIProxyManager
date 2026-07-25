import CLIProxyManagerCore
import Foundation

struct APICostRowPresentation: Equatable, Identifiable {
    let id: String
    let label: String
    let detail: String
    let cost: String
    let tooltip: String
    let accessibilityLabel: String
}

enum ProviderUsageDisplayState: Equatable {
    case hidden
    case loading(String)
    case unavailable(String)
    case subscription(SubscriptionUsageSnapshot, SubscriptionUsageIssue?)
    case apiCost(APICostSnapshot, [APICostIssue])
}

func providerUsageDisplayState(for state: ProviderUsageState) -> ProviderUsageDisplayState {
    switch state {
    case let .subscription(subscriptionState):
        switch subscriptionState {
        case .disabled, .managementKeyNotConfigured:
            .hidden
        case .loading:
            .loading("Checking subscription usage…")
        case let .available(snapshot):
            .subscription(snapshot, nil)
        case let .stale(snapshot, issue):
            .subscription(snapshot, issue)
        case let .unavailable(issue):
            .unavailable("Usage unavailable — \(issue.message)")
        }
    case let .apiCost(apiCostState):
        switch apiCostState {
        case .disabled:
            .hidden
        case .loading:
            .loading("Calculating API cost…")
        case let .available(snapshot):
            .apiCost(snapshot, [])
        case let .partial(snapshot, issues):
            .apiCost(snapshot, issues)
        case let .unavailable(issue):
            .unavailable(apiCostIssueMessage(issue))
        }
    }
}

func apiCostIssueMessage(_ issue: APICostIssue) -> String {
    switch issue {
    case .proxyUnavailable:
        "Local proxy is unavailable."
    case .managementKeyNotConfigured:
        "Management key is not configured."
    case .managementKeyRejected:
        "Management key was rejected."
    case .managementAPINotSupported:
        "This CLIProxyAPI version does not support API usage collection."
    case .transientCollectionFailure:
        "API usage could not be collected."
    case .trackingStartedMidPeriod:
        "Earlier usage in this period is not included."
    case .collectionGap:
        "Some requests may be missing because collection was interrupted."
    case .trackingWasDisabled:
        "Requests made while usage tracking was disabled may be missing."
    case .unsupportedAccountingVersion:
        "Some requests use an unsupported accounting version."
    case .incompleteTokenAccounting:
        "Some requests did not provide complete token accounting."
    case .unknownProviderMapping:
        "Some API key requests could not be matched to a managed provider."
    case .unknownModel:
        "Some request models are not in the bundled price catalog."
    case .unsupportedServiceTier:
        "Some request service tiers are not priced."
    case .unknownPricingVariant:
        "Some request pricing variants are not priced."
    case .priceEpochUnavailable:
        "Some requests do not have a bundled price for their request date."
    case .cacheWriteTTLAssumedDefault:
        "Claude cache writes use the 5-minute cache rate because the queue does not expose TTL."
    case .inferenceGeoAssumedGlobal:
        "Claude costs use global pricing because the queue does not expose inference geography. US-only inference may cost 10% more."
    case .fastModeAssumedStandard:
        "Claude costs use standard-speed pricing because the queue does not expose request speed. Fast mode may cost more."
    case .unsupportedLedgerVersion:
        "The API usage ledger was created by a newer app version."
    case .corruptedLedger:
        "A damaged API usage ledger was recovered; this period may be incomplete."
    case .persistenceFailure:
        "API usage could not be saved completely."
    case .invalidReportingTimeZone:
        "The saved reporting time zone is unavailable; UTC is being used."
    }
}

func apiCostRows(snapshot: APICostSnapshot) -> [APICostRowPresentation] {
    [
        (id: "day", label: "Day", period: snapshot.day),
        (id: "month", label: "Mon", period: snapshot.month)
    ].map { item in
        let period = item.period
        let detail = "\(compactTokenCount(period.totalTokens)) TOK · \(period.requestCount) REQ"
        var tooltipLines = [
            apiCostPeriodRange(period, timeZoneID: snapshot.reportingTimeZoneID),
            "Estimated API cost from requests observed through CLIProxyAPI.",
            "Exact estimate: \(apiCostExactCurrency(period.estimatedUSD))."
        ]
        tooltipLines.append(contentsOf: orderedAPICostIssues(period.issues).map(apiCostIssueMessage))
        if period.unpricedRequestCount > 0 {
            tooltipLines.append(
                "\(period.unpricedRequestCount) \(requestWord(period.unpricedRequestCount)) could not be fully priced."
            )
        }

        return APICostRowPresentation(
            id: item.id,
            label: item.label,
            detail: detail,
            cost: apiCostCurrency(period.estimatedUSD),
            tooltip: tooltipLines.joined(separator: "\n"),
            accessibilityLabel: "\(item.label), estimated API cost \(apiCostExactCurrency(period.estimatedUSD)), \(period.totalTokens) tokens, \(period.requestCount) \(requestWord(period.requestCount))"
        )
    }
}

func apiCostCurrency(_ value: Decimal) -> String {
    if value == 0 { return "$0.00" }
    if value > 0, value < Decimal(string: "0.01")! { return "<$0.01" }
    let amount = currencyFormatter(minimum: 2, maximum: 2)
        .string(from: NSDecimalNumber(decimal: value)) ?? "0.00"
    return "$\(amount)"
}

func apiCostExactCurrency(_ value: Decimal) -> String {
    let amount = currencyFormatter(minimum: 4, maximum: 8)
        .string(from: NSDecimalNumber(decimal: value)) ?? "0.0000"
    return "$\(amount)"
}

func compactTokenCount(_ value: Int64) -> String {
    guard value >= 1_000 else { return String(value) }

    let divisor: Int64 = value >= 1_000_000 ? 1_000_000 : 1_000
    let suffix = value >= 1_000_000 ? "M" : "K"
    let compactValue = NSDecimalNumber(value: value).dividing(by: NSDecimalNumber(value: divisor))
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    formatter.roundingMode = .halfUp
    return "\(formatter.string(from: compactValue) ?? compactValue.stringValue)\(suffix)"
}

func orderedAPICostIssues(_ issues: [APICostIssue]) -> [APICostIssue] {
    APICostIssue.allCases.filter { issues.contains($0) }
}

private func apiCostPeriodRange(_ period: APICostPeriodSnapshot, timeZoneID: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "\(formatter.string(from: period.intervalStart))–\(formatter.string(from: period.intervalEnd)) · \(timeZoneID)"
}

private func currencyFormatter(minimum: Int, maximum: Int) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = minimum
    formatter.maximumFractionDigits = maximum
    formatter.roundingMode = .halfUp
    return formatter
}

private func requestWord(_ count: Int64) -> String {
    count == 1 ? "request" : "requests"
}

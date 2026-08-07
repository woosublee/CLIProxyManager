import CLIProxyManagerCore
import Foundation

struct CompactUsageRowPresentation: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let accessibilityLabel: String
    let tooltip: String?
    let textLayout: UsageTextLayout

    init(
        id: String,
        label: String,
        value: String,
        accessibilityLabel: String,
        tooltip: String? = nil,
        textLayout: UsageTextLayout = .adaptiveSingleLine(minimumScaleFactor: 0.6)
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.tooltip = tooltip
        self.textLayout = textLayout
    }
}

enum CompactUsageIndicator: Equatable {
    case loading(message: String)
    case disabled(message: String)
    case unavailable(message: String)
    case warning(message: String)

    var symbolName: String {
        switch self {
        case .loading:
            "clock.arrow.circlepath"
        case .disabled:
            "slash.circle"
        case .unavailable:
            "exclamationmark.circle"
        case .warning:
            "exclamationmark.triangle.fill"
        }
    }

    var message: String {
        switch self {
        case .loading(let message),
             .disabled(let message),
             .unavailable(let message),
             .warning(let message):
            message
        }
    }
}

struct CompactUsagePresentation: Equatable {
    let rows: [CompactUsageRowPresentation]
    let placeholder: String?
    let indicator: CompactUsageIndicator?
    let cardTooltip: String?

    init(
        rows: [CompactUsageRowPresentation],
        placeholder: String?,
        indicator: CompactUsageIndicator?,
        cardTooltip: String? = nil
    ) {
        self.rows = rows
        self.placeholder = placeholder
        self.indicator = indicator
        self.cardTooltip = cardTooltip
    }

    var headerIndicator: CompactUsageIndicator? {
        rows.isEmpty ? nil : indicator
    }

    var placeholderIndicator: CompactUsageIndicator? {
        rows.isEmpty ? indicator : nil
    }

    static func placeholder(
        _ value: String,
        indicator: CompactUsageIndicator
    ) -> CompactUsagePresentation {
        CompactUsagePresentation(rows: [], placeholder: value, indicator: indicator)
    }
}

func compactUsagePresentation(
    for state: ProviderUsageState,
    now: Date = .now
) -> CompactUsagePresentation {
    switch state {
    case let .subscription(subscriptionState):
        compactUsagePresentation(for: subscriptionState, now: now)
    case let .apiCost(apiCostState):
        compactAPICostPresentation(for: apiCostState)
    }
}

// Temporary compatibility overload while Task 12 migrates compact view call sites.
func compactUsagePresentation(
    for state: AccountSubscriptionUsageState,
    now: Date = .now
) -> CompactUsagePresentation {
    switch state {
    case .disabled:
        return .placeholder(
            "—",
            indicator: .disabled(message: "Subscription usage is disabled.")
        )
    case .managementKeyNotConfigured:
        return .placeholder(
            "—",
            indicator: .disabled(message: "Subscription usage is not configured.")
        )
    case .loading:
        return .placeholder(
            "—",
            indicator: .loading(message: "Checking subscription usage…")
        )
    case .available(let snapshot):
        return compactSnapshotPresentation(snapshot, warning: nil, now: now)
    case .stale(let snapshot, let issue):
        return compactSnapshotPresentation(snapshot, warning: issue, now: now)
    case .unavailable(let issue):
        return .placeholder(
            "—",
            indicator: compactUnavailableIndicator(for: issue)
        )
    }
}

private func compactAPICostPresentation(
    for state: APICostUsageState
) -> CompactUsagePresentation {
    switch state {
    case .disabled:
        return .placeholder(
            "—",
            indicator: .disabled(message: "API cost tracking is disabled.")
        )
    case .loading:
        return .placeholder(
            "—",
            indicator: .loading(message: "Calculating API cost…")
        )
    case let .available(snapshot):
        return compactAPICostSnapshotPresentation(snapshot, issues: [])
    case let .partial(snapshot, issues):
        return compactAPICostSnapshotPresentation(snapshot, issues: issues)
    case let .unavailable(issue):
        return .placeholder(
            "—",
            indicator: .unavailable(message: apiCostIssueMessage(issue))
        )
    }
}

private func compactAPICostSnapshotPresentation(
    _ snapshot: APICostSnapshot,
    issues: [APICostIssue]
) -> CompactUsagePresentation {
    let apiPresentation = apiCostUsagePresentation(snapshot: snapshot, issues: issues)
    let rows = apiPresentation.rows.map { row in
        CompactUsageRowPresentation(
            id: row.id,
            label: row.label,
            value: row.cost,
            accessibilityLabel: row.accessibilityLabel,
            tooltip: row.tooltip,
            textLayout: row.textLayout
        )
    }
    return CompactUsagePresentation(
        rows: rows,
        placeholder: nil,
        indicator: apiPresentation.warningMessage.map {
            .warning(message: $0)
        }
    )
}

private func compactUnavailableIndicator(for issue: SubscriptionUsageIssue) -> CompactUsageIndicator {
    switch issue {
    case .proxyUnavailable, .managementAPINotSupported, .providerContractUnsupported, .unknownProvider:
        .unavailable(message: issue.message)
    case .managementKeyRejected, .credentialExpired, .credentialDisabled, .authFileNotMatched,
         .schemaMismatch, .transientFailure:
        .warning(message: issue.message)
    }
}

private let compactUsageResetWaitingText = "Shown after usage starts"

private func compactUsageResetLine(for window: UsageWindow) -> String {
    let label = subscriptionUsageDisplayLabel(for: window)
    let resetStatus = subscriptionUsageResetDateText(for: window)
        ?? compactUsageResetWaitingText
    return "\(label)  \(resetStatus)"
}

private func compactUsageAccessibilityLabel(
    for window: UsageWindow,
    usedPercent: Int
) -> String {
    if subscriptionUsageResetDateText(for: window) != nil {
        return subscriptionUsageAccessibilityLabel(
            for: window,
            usedPercent: usedPercent
        )
    }
    let label = subscriptionUsageDisplayLabel(for: window)
    return "\(label), \(usedPercent) percent used, reset time shown after usage starts"
}

private func compactSnapshotPresentation(
    _ snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?,
    now: Date
) -> CompactUsagePresentation {
    guard !snapshot.windows.isEmpty else {
        let indicator = warning.map { issue in
            CompactUsageIndicator.warning(
                message: SubscriptionUsageWarningPresentation.message(
                    issue: issue,
                    lastUpdatedAt: snapshot.fetchedAt,
                    now: now
                )
            )
        } ?? .unavailable(message: "Usage details unavailable.")
        return .placeholder("—", indicator: indicator)
    }

    let rows = snapshot.windows.map { window in
        let percent = min(max(window.usedPercent, 0), 100)
        let rounded = Int(percent.rounded())
        let label = subscriptionUsageDisplayLabel(for: window)
        return CompactUsageRowPresentation(
            id: window.id,
            label: label,
            value: "\(rounded)%",
            accessibilityLabel: compactUsageAccessibilityLabel(
                for: window,
                usedPercent: rounded
            )
        )
    }
    let indicator = warning.map { issue in
        CompactUsageIndicator.warning(
            message: SubscriptionUsageWarningPresentation.message(
                issue: issue,
                lastUpdatedAt: snapshot.fetchedAt,
                now: now
            )
        )
    }
    let cardTooltip = snapshot.windows
        .map(compactUsageResetLine(for:))
        .joined(separator: "\n")
    return CompactUsagePresentation(
        rows: rows,
        placeholder: nil,
        indicator: indicator,
        cardTooltip: cardTooltip
    )
}

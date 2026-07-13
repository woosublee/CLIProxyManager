import CLIProxyManagerCore
import Foundation

struct CompactUsageRowPresentation: Equatable, Identifiable {
    let id: String
    let label: String
    let value: String
    let accessibilityLabel: String
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

    static func placeholder(
        _ value: String,
        indicator: CompactUsageIndicator
    ) -> CompactUsagePresentation {
        CompactUsagePresentation(rows: [], placeholder: value, indicator: indicator)
    }
}

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

private func compactUnavailableIndicator(for issue: SubscriptionUsageIssue) -> CompactUsageIndicator {
    switch issue {
    case .proxyUnavailable, .managementAPINotSupported, .providerContractUnsupported, .unknownProvider:
        .unavailable(message: issue.message)
    case .managementKeyRejected, .credentialExpired, .credentialDisabled, .authFileNotMatched,
         .schemaMismatch, .transientFailure:
        .warning(message: issue.message)
    }
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
            accessibilityLabel: "\(label), \(rounded) percent used"
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
    return CompactUsagePresentation(rows: rows, placeholder: nil, indicator: indicator)
}

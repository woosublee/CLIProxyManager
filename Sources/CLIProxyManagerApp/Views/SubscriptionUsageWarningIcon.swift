import CLIProxyManagerCore
import SwiftUI

enum SubscriptionUsageDisplayState: Equatable {
    case hidden
    case loading(String)
    case unavailable(String)
    case snapshot(SubscriptionUsageSnapshot, warning: SubscriptionUsageIssue?)
}

func subscriptionUsageDisplayState(
    for state: AccountSubscriptionUsageState
) -> SubscriptionUsageDisplayState {
    switch state {
    case .disabled, .managementKeyNotConfigured:
        .hidden
    case .loading:
        .loading("Checking subscription usage…")
    case .available(let snapshot):
        .snapshot(snapshot, warning: nil)
    case .stale(let snapshot, let issue):
        .snapshot(snapshot, warning: issue)
    case .unavailable(let issue):
        .unavailable("Usage unavailable — \(issue.message)")
    }
}

enum SubscriptionUsageWarningPresentation {
    static func message(
        issue: SubscriptionUsageIssue,
        lastUpdatedAt: Date,
        now: Date = .now
    ) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(lastUpdatedAt) / 60))
        let age = minutes == 0
            ? "just now"
            : "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        return "\(issue.message) Showing usage last updated \(age)."
    }
}

struct SubscriptionUsageWarningIcon: View {
    let issue: SubscriptionUsageIssue
    let lastUpdatedAt: Date

    var body: some View {
        let message = SubscriptionUsageWarningPresentation.message(
            issue: issue,
            lastUpdatedAt: lastUpdatedAt
        )
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BrandPalette.statusWarning)
            .help(message)
            .accessibilityLabel(Text(message))
    }
}

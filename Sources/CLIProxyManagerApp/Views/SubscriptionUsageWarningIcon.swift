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

func providerUsageWarningMessage(
    for state: ProviderUsageState,
    now: Date = .now
) -> String? {
    switch state {
    case let .subscription(.stale(snapshot, issue)):
        SubscriptionUsageWarningPresentation.message(
            issue: issue,
            lastUpdatedAt: snapshot.fetchedAt,
            now: now
        )
    case let .apiCost(.partial(snapshot, issues)):
        apiCostUsagePresentation(snapshot: snapshot, issues: issues).warningMessage
    case let .apiCost(.unavailable(issue)):
        apiCostIssueMessage(issue)
    case .subscription, .apiCost:
        nil
    }
}

struct SubscriptionUsageWarningRowPresentation: Equatable, Identifiable {
    let window: UsageWindow
    let warning: SubscriptionUsageIssue?
    let reservesWarningSpace: Bool

    var id: String { window.id }
}

func subscriptionUsageWarningRows(
    snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?
) -> [SubscriptionUsageWarningRowPresentation] {
    snapshot.windows.enumerated().map { index, window in
        SubscriptionUsageWarningRowPresentation(
            window: window,
            warning: index == snapshot.windows.startIndex ? warning : nil,
            reservesWarningSpace: warning != nil
        )
    }
}

enum UsageWarningLayout {
    static let iconFrameSize = CGSize(width: 12, height: 12)
    static let inlineSpacing: CGFloat = 6
    static let compactAvatarTrailingOffset: CGFloat = 10
}

struct UsageWarningAlignedRow<Content: View>: View {
    let message: String?
    let reservesWarningSpace: Bool
    let content: Content

    init(
        message: String?,
        reservesWarningSpace: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.message = message
        self.reservesWarningSpace = reservesWarningSpace
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if reservesWarningSpace {
            HStack(spacing: UsageWarningLayout.inlineSpacing) {
                content
                warningSlot
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var warningSlot: some View {
        if let message {
            UsageWarningIcon(message: message)
                .frame(
                    width: UsageWarningLayout.iconFrameSize.width,
                    height: UsageWarningLayout.iconFrameSize.height
                )
        } else {
            Color.clear
                .frame(
                    width: UsageWarningLayout.iconFrameSize.width,
                    height: UsageWarningLayout.iconFrameSize.height
                )
                .accessibilityHidden(true)
        }
    }
}

struct UsageWarningIcon: View {
    let message: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BrandPalette.statusWarning)
            .help(message)
            .accessibilityLabel(Text(message))
    }
}

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

enum SubscriptionUsageWarningLayout {
    static let iconFrameSize = CGSize(width: 12, height: 12)
    static let inlineSpacing: CGFloat = 6
    static let compactAvatarTrailingOffset: CGFloat = 10
}

struct SubscriptionUsageWarningAlignedRow<Content: View>: View {
    let warning: SubscriptionUsageIssue?
    let reservesWarningSpace: Bool
    let lastUpdatedAt: Date
    let content: Content

    init(
        warning: SubscriptionUsageIssue?,
        reservesWarningSpace: Bool,
        lastUpdatedAt: Date,
        @ViewBuilder content: () -> Content
    ) {
        self.warning = warning
        self.reservesWarningSpace = reservesWarningSpace
        self.lastUpdatedAt = lastUpdatedAt
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if reservesWarningSpace {
            HStack(spacing: SubscriptionUsageWarningLayout.inlineSpacing) {
                content
                warningSlot
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var warningSlot: some View {
        if let warning {
            SubscriptionUsageWarningIcon(
                issue: warning,
                lastUpdatedAt: lastUpdatedAt
            )
            .frame(
                width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                height: SubscriptionUsageWarningLayout.iconFrameSize.height
            )
        } else {
            Color.clear
                .frame(
                    width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                    height: SubscriptionUsageWarningLayout.iconFrameSize.height
                )
                .accessibilityHidden(true)
        }
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

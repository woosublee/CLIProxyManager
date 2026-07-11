import CLIProxyManagerCore
import SwiftUI

enum SubscriptionUsageProgressTone: Equatable {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal:
            BrandPalette.accent
        case .warning:
            BrandPalette.statusWarning
        case .critical:
            BrandPalette.statusError
        }
    }
}

func subscriptionUsageProgressTone(for usedPercent: Double) -> SubscriptionUsageProgressTone {
    switch usedPercent {
    case ..<50:
        .normal
    case ..<80:
        .warning
    default:
        .critical
    }
}

func subscriptionUsageAccessibilityLabel(for window: UsageWindow) -> String {
    let used = Int(window.usedPercent.rounded())
    guard let resetAt = window.resetAt else {
        return "\(window.label), \(used) percent used"
    }
    return "\(window.label), \(used) percent used, resets \(resetAt.formatted(date: .abbreviated, time: .shortened))"
}

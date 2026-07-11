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

func subscriptionUsageDisplayLabel(for window: UsageWindow) -> String {
    switch window.id {
    case "primary": "5h"
    case "secondary": "7d"
    default: window.label
    }
}

func subscriptionUsageAccessibilityLabel(for window: UsageWindow) -> String {
    let used = Int(window.usedPercent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    guard let resetAt = window.resetAt else {
        return "\(label), \(used) percent used"
    }
    return "\(label), \(used) percent used, resets \(resetAt.formatted(date: .abbreviated, time: .shortened))"
}

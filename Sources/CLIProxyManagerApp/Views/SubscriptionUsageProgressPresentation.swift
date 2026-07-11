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
    guard let seconds = window.limitWindowSeconds else {
        switch window.id {
        case "primary": return "5h"
        case "secondary": return "7d"
        default: return window.label
        }
    }

    if seconds >= 2_419_200 {
        return "1mo"
    }
    if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
        return "\(Int(seconds / 86_400))d"
    }
    if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
        return "\(Int(seconds / 3_600))h"
    }
    return window.label
}

func subscriptionUsageAccessibilityLabel(for window: UsageWindow) -> String {
    let used = Int(window.usedPercent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    guard let resetAt = window.resetAt else {
        return "\(label), \(used) percent used"
    }
    return "\(label), \(used) percent used, resets \(resetAt.formatted(date: .abbreviated, time: .shortened))"
}

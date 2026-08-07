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

func subscriptionUsageResetDateText(for window: UsageWindow) -> String? {
    guard let resetAt = window.resetAt else { return nil }
    return resetAt.formatted(date: .abbreviated, time: .shortened)
}

func subscriptionUsageResetTooltip(for window: UsageWindow) -> String? {
    subscriptionUsageResetDateText(for: window).map { "Next reset: \($0)" }
}

func subscriptionUsageAccessibilityLabel(
    for window: UsageWindow,
    usedPercent: Int? = nil
) -> String {
    let used = usedPercent ?? Int(window.usedPercent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    guard let resetText = subscriptionUsageResetDateText(for: window) else {
        return "\(label), \(used) percent used"
    }
    return "\(label), \(used) percent used, resets \(resetText)"
}

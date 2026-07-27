import CLIProxyManagerCore
import Foundation

struct CodexResetCreditsPresentation: Equatable {
    let badgeText: String?
    let tooltip: String?
    let accessibilityLabel: String?
    let availableCount: Int
}

func codexResetCreditsPresentation(
    snapshot: CodexResetCreditsSnapshot?,
    now: Date,
    timeZone: TimeZone = .current,
    locale: Locale = .current
) -> CodexResetCreditsPresentation {
    guard let snapshot else {
        return .init(badgeText: nil, tooltip: nil, accessibilityLabel: nil, availableCount: 0)
    }

    let available = snapshot.credits.filter { credit in
        guard credit.status?.caseInsensitiveCompare("available") == .orderedSame else { return false }
        guard let expiresAt = credit.expiresAt else { return true }
        return expiresAt > now
    }

    let count = snapshot.credits.isEmpty
        ? max(0, snapshot.reportedAvailableCount ?? 0)
        : available.count
    guard count > 0 else {
        return .init(badgeText: nil, tooltip: nil, accessibilityLabel: nil, availableCount: 0)
    }

    let countLine = "\(count) reset credit\(count == 1 ? "" : "s") available"
    let detailLines: [String]
    if available.isEmpty {
        detailLines = ["Expiration details unavailable"]
    } else {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        detailLines = available.map { credit in
            let title = normalizedResetCreditTitle(credit.title)
            let expiration = credit.expiresAt.map(formatter.string) ?? "Expiration unavailable"
            return "\(title) · \(expiration)"
        }
    }
    let tooltip = ([countLine] + detailLines).joined(separator: "\n")
    return CodexResetCreditsPresentation(
        badgeText: count > 99 ? "99+" : String(count),
        tooltip: tooltip,
        accessibilityLabel: tooltip.replacingOccurrences(of: "\n", with: ". "),
        availableCount: count
    )
}

private func normalizedResetCreditTitle(_ title: String?) -> String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "Reset credit" }
    guard let suffix = trimmed.range(of: " (") else { return trimmed }
    return String(trimmed[..<suffix.lowerBound])
}

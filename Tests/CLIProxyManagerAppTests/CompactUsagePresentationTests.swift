import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CompactUsagePresentationTests: XCTestCase {
    func testAvailableSnapshotProducesClampedRoundedRows() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                UsageWindow(id: "primary", label: "Primary", usedPercent: -2, resetAt: nil),
                UsageWindow(id: "secondary", label: "Secondary", usedPercent: 15.6, resetAt: nil),
                UsageWindow(
                    id: "monthly",
                    label: "Monthly",
                    usedPercent: 104,
                    resetAt: nil,
                    limitWindowSeconds: 2_419_200
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertEqual(
            presentation.rows,
            [
                .init(label: "5h", value: "0%", accessibilityLabel: "5h, 0 percent used"),
                .init(label: "7d", value: "16%", accessibilityLabel: "7d, 16 percent used"),
                .init(label: "1mo", value: "100%", accessibilityLabel: "1mo, 100 percent used")
            ]
        )
        XCTAssertNil(presentation.placeholder)
        XCTAssertNil(presentation.indicator)
    }

    func testEmptySnapshotUsesUnavailablePlaceholder() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertEqual(presentation.rows, [])
        XCTAssertEqual(presentation.placeholder, "—")
        XCTAssertEqual(presentation.indicator, .unavailable(message: "Usage details unavailable."))
    }

    func testLoadingDisabledAndUnavailableUseStablePlaceholder() {
        XCTAssertEqual(
            compactUsagePresentation(for: .loading),
            .placeholder("—", indicator: .loading(message: "Checking subscription usage…"))
        )
        XCTAssertEqual(
            compactUsagePresentation(for: .disabled),
            .placeholder("—", indicator: .disabled(message: "Subscription usage is disabled."))
        )
        XCTAssertEqual(
            compactUsagePresentation(for: .managementKeyNotConfigured),
            .placeholder("—", indicator: .disabled(message: "Subscription usage is not configured."))
        )
        XCTAssertEqual(
            compactUsagePresentation(for: .unavailable(.proxyUnavailable)),
            .placeholder("—", indicator: .unavailable(message: "Local proxy is unavailable."))
        )
    }

    func testStaleSnapshotKeepsRowsAndAddsDeterministicWarning() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(
            for: .stale(snapshot, .credentialExpired),
            now: Date(timeIntervalSince1970: 780)
        )

        XCTAssertEqual(presentation.rows.first?.value, "15%")
        XCTAssertEqual(
            presentation.indicator,
            .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
        )
    }

    func testIndicatorsExposeStableSymbolsAndMessages() {
        let warning = CompactUsageIndicator.warning(message: "Needs attention")
        let loading = CompactUsageIndicator.loading(message: "Loading")

        XCTAssertEqual(warning.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(warning.message, "Needs attention")
        XCTAssertEqual(loading.symbolName, "clock.arrow.circlepath")
        XCTAssertEqual(loading.message, "Loading")
    }
}

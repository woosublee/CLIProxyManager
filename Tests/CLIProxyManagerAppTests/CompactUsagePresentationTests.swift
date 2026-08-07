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
                CompactUsageRowPresentation(id: "primary", label: "5h", value: "0%", accessibilityLabel: "5h, 0 percent used"),
                CompactUsageRowPresentation(id: "secondary", label: "7d", value: "16%", accessibilityLabel: "7d, 16 percent used"),
                CompactUsageRowPresentation(id: "monthly", label: "1mo", value: "100%", accessibilityLabel: "1mo, 100 percent used")
            ]
        )
        XCTAssertNil(presentation.placeholder)
        XCTAssertNil(presentation.indicator)
    }

    func testSubscriptionRowsExposeIndependentResetTooltipsAndAccessibilityText() {
        let fiveHourReset = Date(timeIntervalSince1970: 1_786_189_800)
        let sevenDayReset = Date(timeIntervalSince1970: 1_786_449_600)
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                UsageWindow(
                    id: "primary",
                    label: "Primary",
                    usedPercent: 30,
                    resetAt: fiveHourReset
                ),
                UsageWindow(
                    id: "secondary",
                    label: "Secondary",
                    usedPercent: 12,
                    resetAt: sevenDayReset
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let rows = compactUsagePresentation(for: .available(snapshot)).rows
        let fiveHourText = fiveHourReset.formatted(date: .abbreviated, time: .shortened)
        let sevenDayText = sevenDayReset.formatted(date: .abbreviated, time: .shortened)

        XCTAssertEqual(
            rows,
            [
                CompactUsageRowPresentation(
                    id: "primary",
                    label: "5h",
                    value: "30%",
                    accessibilityLabel: "5h, 30 percent used, resets \(fiveHourText)",
                    tooltip: "Next reset: \(fiveHourText)"
                ),
                CompactUsageRowPresentation(
                    id: "secondary",
                    label: "7d",
                    value: "12%",
                    accessibilityLabel: "7d, 12 percent used, resets \(sevenDayText)",
                    tooltip: "Next reset: \(sevenDayText)"
                )
            ]
        )
    }

    func testSubscriptionRowWithoutResetKeepsExistingAccessibilityAndNoTooltip() throws {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [
                UsageWindow(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let row = try XCTUnwrap(compactUsagePresentation(for: .available(snapshot)).rows.first)

        XCTAssertEqual(row.accessibilityLabel, "5h, 25 percent used")
        XCTAssertNil(row.tooltip)
    }

    func testStaleSnapshotRetainsLastSuccessfulResetTooltip() throws {
        let resetAt = Date(timeIntervalSince1970: 1_786_189_800)
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                UsageWindow(id: "primary", label: "Primary", usedPercent: 15, resetAt: resetAt)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(
            for: .stale(snapshot, .credentialExpired),
            now: Date(timeIntervalSince1970: 780)
        )
        let row = try XCTUnwrap(presentation.rows.first)
        let resetText = resetAt.formatted(date: .abbreviated, time: .shortened)

        XCTAssertEqual(row.tooltip, "Next reset: \(resetText)")
        XCTAssertEqual(row.accessibilityLabel, "5h, 15 percent used, resets \(resetText)")
        XCTAssertEqual(
            presentation.indicator,
            .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
        )
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

    func testStaleSnapshotRoutesWarningToHeaderWithoutPlaceholderIndicator() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let presentation = compactUsagePresentation(
            for: .stale(snapshot, .credentialExpired),
            now: Date(timeIntervalSince1970: 780)
        )

        XCTAssertEqual(
            presentation.headerIndicator,
            .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
        )
        XCTAssertNil(presentation.placeholderIndicator)
    }

    func testPlaceholderRoutesIndicatorInlineWithoutHeaderOverlay() {
        let presentation = compactUsagePresentation(for: .loading)

        XCTAssertNil(presentation.headerIndicator)
        XCTAssertEqual(
            presentation.placeholderIndicator,
            .loading(message: "Checking subscription usage…")
        )
    }

    func testAvailableSnapshotHasNoHeaderOrPlaceholderIndicator() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertNil(presentation.headerIndicator)
        XCTAssertNil(presentation.placeholderIndicator)
    }

    func testStaleEmptySnapshotPreservesWarningInsteadOfGenericUnavailableState() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(
            for: .stale(snapshot, .credentialExpired),
            now: Date(timeIntervalSince1970: 780)
        )

        XCTAssertEqual(presentation.rows, [])
        XCTAssertEqual(presentation.placeholder, "—")
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

    func testUnavailableIssuesUseExplicitAvailabilityAndWarningClassification() {
        XCTAssertEqual(
            compactUsagePresentation(for: .unavailable(.proxyUnavailable)).indicator,
            .unavailable(message: "Local proxy is unavailable.")
        )
        XCTAssertEqual(
            compactUsagePresentation(for: .unavailable(.credentialExpired)).indicator,
            .warning(message: "Credential needs attention.")
        )
        XCTAssertEqual(
            compactUsagePresentation(for: .unavailable(.transientFailure)).indicator,
            .warning(message: "Usage could not be refreshed.")
        )
    }

    func testProviderUsageDispatcherPreservesSubscriptionPresentation() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 16, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .subscription(.available(snapshot)))

        XCTAssertEqual(
            presentation.rows,
            [CompactUsageRowPresentation(id: "primary", label: "5h", value: "16%", accessibilityLabel: "5h, 16 percent used")]
        )
        XCTAssertNil(presentation.indicator)
    }

    func testDuplicateDisplayLabelsPreserveDistinctWindowIDs() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                UsageWindow(
                    id: "monthly-a",
                    label: "Monthly A",
                    usedPercent: 10,
                    resetAt: nil,
                    limitWindowSeconds: 2_419_200
                ),
                UsageWindow(
                    id: "monthly-b",
                    label: "Monthly B",
                    usedPercent: 20,
                    resetAt: nil,
                    limitWindowSeconds: 2_419_200
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let rows = compactUsagePresentation(for: .available(snapshot)).rows

        XCTAssertEqual(rows.map(\.label), ["1mo", "1mo"])
        XCTAssertEqual(rows.map(\.id), ["monthly-a", "monthly-b"])
    }
}

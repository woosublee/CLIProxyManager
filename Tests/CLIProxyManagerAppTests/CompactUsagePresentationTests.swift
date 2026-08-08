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
                CompactUsageRowPresentation(
                    id: "primary",
                    label: "5h",
                    value: "0%",
                    accessibilityLabel: "5h, 0 percent used, reset time shown after usage starts"
                ),
                CompactUsageRowPresentation(
                    id: "secondary",
                    label: "7d",
                    value: "16%",
                    accessibilityLabel: "7d, 16 percent used, reset time unavailable"
                ),
                CompactUsageRowPresentation(
                    id: "monthly",
                    label: "1mo",
                    value: "100%",
                    accessibilityLabel: "1mo, 100 percent used, reset time unavailable"
                )
            ]
        )
        XCTAssertEqual(
            presentation.cardTooltip,
            "5h  Shown after usage starts\n7d  Reset time unavailable\n1mo  Reset time unavailable"
        )
        XCTAssertNil(presentation.placeholder)
        XCTAssertNil(presentation.indicator)
    }

    func testSubscriptionCardTooltipCombinesResetAndWaitingRowsInOrder() {
        let fiveHourReset = Date(timeIntervalSince1970: 1_786_189_800)
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
                    usedPercent: 0,
                    resetAt: nil
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))
        let resetText = fiveHourReset.formatted(date: .abbreviated, time: .shortened)

        XCTAssertEqual(
            presentation.cardTooltip,
            "5h  \(resetText)\n7d  Shown after usage starts"
        )
        XCTAssertEqual(presentation.rows.map(\.tooltip), [nil, nil])
        XCTAssertEqual(
            presentation.rows.map(\.accessibilityLabel),
            [
                "5h, 30 percent used, resets \(resetText)",
                "7d, 0 percent used, reset time shown after usage starts"
            ]
        )
    }

    func testMissingResetDistinguishesUnusedWindowFromUnavailableTimestamp() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [
                UsageWindow(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil),
                UsageWindow(id: "seven_day", label: "7d", usedPercent: 52, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertEqual(
            presentation.cardTooltip,
            "5h  Shown after usage starts\n7d  Reset time unavailable"
        )
        XCTAssertEqual(
            presentation.rows.map(\.accessibilityLabel),
            [
                "5h, 0 percent used, reset time shown after usage starts",
                "7d, 52 percent used, reset time unavailable"
            ]
        )
    }

    func testStaleSnapshotRetainsGroupedResetTooltip() throws {
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
        let resetText = resetAt.formatted(date: .abbreviated, time: .shortened)

        XCTAssertEqual(presentation.cardTooltip, "5h  \(resetText)")
        XCTAssertNil(try XCTUnwrap(presentation.rows.first).tooltip)
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

        let direct = compactUsagePresentation(for: AccountSubscriptionUsageState.available(snapshot))
        let dispatched = compactUsagePresentation(for: ProviderUsageState.subscription(.available(snapshot)))

        XCTAssertEqual(dispatched, direct)
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

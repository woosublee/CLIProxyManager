import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class SubscriptionUsageWarningIconTests: XCTestCase {
    func testUsageWarningIconAcceptsAPIMessageWithoutSubscriptionIssue() {
        let message = "Estimated API cost is partial. Time zone: Asia/Seoul."
        let icon = UsageWarningIcon(message: message)

        XCTAssertEqual(icon.message, message)
        XCTAssertEqual(UsageWarningLayout.iconFrameSize, CGSize(width: 12, height: 12))
    }

    func testStaleStateKeepsSnapshotAndAddsWarningPresentation() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        XCTAssertEqual(
            subscriptionUsageDisplayState(for: .stale(snapshot, .credentialExpired)),
            .snapshot(snapshot, warning: .credentialExpired)
        )
    }

    func testUnavailableWithoutSnapshotKeepsFullUnavailableMessage() {
        XCTAssertEqual(
            subscriptionUsageDisplayState(for: .unavailable(.credentialExpired)),
            .unavailable("Usage unavailable — Credential needs attention.")
        )
    }

    func testWarningMessageIncludesIssueAndDeterministicLastUpdatedAge() {
        let message = SubscriptionUsageWarningPresentation.message(
            issue: .credentialExpired,
            lastUpdatedAt: Date(timeIntervalSince1970: 60),
            now: Date(timeIntervalSince1970: 780)
        )

        XCTAssertEqual(message, "Credential needs attention. Showing usage last updated 12 minutes ago.")
    }

    func testWarningRowsShowIconOnlyOnFirstRowAndReserveEqualTrailingSpace() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
                .init(id: "secondary", label: "Secondary", usedPercent: 30, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let rows = subscriptionUsageWarningRows(snapshot: snapshot, warning: .credentialExpired)

        XCTAssertEqual(rows.map(\.window.id), ["primary", "secondary"])
        XCTAssertEqual(rows.map(\.warning), [.credentialExpired, nil])
        XCTAssertEqual(rows.map(\.reservesWarningSpace), [true, true])
    }

    func testAvailableRowsDoNotReserveWarningSpace() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
                .init(id: "secondary", label: "Secondary", usedPercent: 30, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let rows = subscriptionUsageWarningRows(snapshot: snapshot, warning: nil)

        XCTAssertEqual(rows.map(\.warning), [nil, nil])
        XCTAssertEqual(rows.map(\.reservesWarningSpace), [false, false])
    }
}

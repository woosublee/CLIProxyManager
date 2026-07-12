import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class SubscriptionUsageWarningIconTests: XCTestCase {
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
}

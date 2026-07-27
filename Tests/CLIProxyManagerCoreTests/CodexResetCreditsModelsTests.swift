import XCTest
@testable import CLIProxyManagerCore

final class CodexResetCreditsModelsTests: XCTestCase {
    func testSnapshotRoundTripsOnlyRedactedFields() throws {
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex-work.json",
            reportedAvailableCount: 2,
            reportedTotalEarnedCount: 4,
            credits: [
                CodexResetCredit(
                    title: "Full reset",
                    status: "available",
                    resetType: "full",
                    expiresAt: Date(timeIntervalSince1970: 1_785_174_400),
                    grantedAt: Date(timeIntervalSince1970: 1_784_000_000)
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_784_100_000)
        )

        let data = try JSONEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(CodexResetCreditsSnapshot.self, from: data), snapshot)
        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("account_id"))
        XCTAssertFalse(encoded.contains("credit_id"))
    }

    func testSubscriptionUsageReportDefaultsResetCreditOutcomesToEmpty() {
        let report = SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: .distantPast)
        XCTAssertEqual(report.resetCreditsOutcomesByProfileID, [:])
    }
}

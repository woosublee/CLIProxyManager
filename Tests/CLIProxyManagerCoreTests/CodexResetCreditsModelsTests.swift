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

    func testSubscriptionUsageReportDefaultsResetCreditMetadataToEmpty() {
        let report = SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: .distantPast)
        XCTAssertEqual(report.resetCreditsOutcomesByProfileID, [:])
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [])
    }

    func testLegacyQuotaFetcherPreservesUsageSubsetAndReportsUnsupportedReset() async {
        let usageProfile = AuthProfile(
            fileName: "claude-work.json",
            type: .claude,
            email: "work@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let resetProfile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "work@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let client = LegacySubscriptionQuotaClient()

        let report = await client.fetchUsage(
            port: 28_317,
            profiles: [usageProfile, resetProfile],
            usageProfileIDs: [usageProfile.id],
            resetCreditsProfileIDs: [resetProfile.id]
        )

        let requestedProfileIDs = await client.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[usageProfile.id]])
        XCTAssertEqual(report.statesByProfileID, [usageProfile.id: .loading])
        XCTAssertEqual(
            report.resetCreditsOutcomesByProfileID,
            [resetProfile.id: .unavailable(.endpointUnsupported)]
        )
        XCTAssertEqual(report.resetCreditsAttemptedProfileIDs, [])
        XCTAssertEqual(report.resetCreditsDeferredProfileIDs, [resetProfile.id])
    }
}

private actor LegacySubscriptionQuotaClient: SubscriptionQuotaFetching {
    private var requests: [[String]] = []

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        requests.append(profiles.map(\.id))
        return SubscriptionUsageReport(
            statesByProfileID: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, .loading) }),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func requestedProfileIDs() -> [[String]] { requests }
}

import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class APIUsageLedgerModelsTests: XCTestCase {
    func testMonthlyLedgerRoundTripsWithoutSensitiveIdentityFields() throws {
        let bucket = APIUsageLedgerBucket(
            key: .init(localDate: "2026-07-25", profileID: "claude-api", provider: .claude, model: "claude-opus-5", effectiveServiceTier: "standard", pricingVariant: .standard, priceEpochStart: Date(timeIntervalSince1970: 10)),
            uncachedInputTokens: 10, cacheReadTokens: 2, cacheWriteTokens: 1,
            nonReasoningOutputTokens: 20, reasoningOutputTokens: 5, totalTokens: 38,
            requestCount: 1, failedRequestCount: 0,
            firstObservedAt: Date(timeIntervalSince1970: 20), lastObservedAt: Date(timeIntervalSince1970: 20)
        )
        let ledger = APIUsageMonthlyLedger(schemaVersion: 1, month: "2026-07", reportingTimeZoneID: "Asia/Seoul", buckets: [bucket], issues: [])

        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(APIUsageMonthlyLedger.self, from: data), ledger)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["api_key", "auth_index", "request_id", "failure", "response_headers"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testPeriodBoundsUseStoredTimeZoneAcrossDSTAndSystemZoneChanges() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T10:30:00Z"))
        let result = APIUsagePeriodCalculator.bounds(at: instant, timeZoneID: "America/Los_Angeles")

        XCTAssertFalse(result.usedUTCFallback)
        XCTAssertEqual(result.localDate, "2026-03-08")
        XCTAssertEqual(result.month, "2026-03")
        XCTAssertEqual(result.dayStart, ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z"))
        XCTAssertEqual(result.dayEnd, ISO8601DateFormatter().date(from: "2026-03-09T07:00:00Z"))
    }

    func testPeriodBoundsHandleMonthAndYearRollover() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T07:30:00Z"))
        let result = APIUsagePeriodCalculator.bounds(at: instant, timeZoneID: "America/Los_Angeles")

        XCTAssertEqual(result.localDate, "2026-12-31")
        XCTAssertEqual(result.month, "2026-12")
        XCTAssertEqual(result.dayEnd, ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
        XCTAssertEqual(result.monthEnd, ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
    }

    func testInvalidTimeZoneFallsBackToUTCAndMarksResult() {
        let result = APIUsagePeriodCalculator.bounds(at: Date(timeIntervalSince1970: 0), timeZoneID: "Invalid/Zone")

        XCTAssertTrue(result.usedUTCFallback)
        XCTAssertEqual(result.resolvedTimeZoneID, "UTC")
    }
}

import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditsPresentationTests: XCTestCase {
    func testPresentationFiltersUnavailableAndExpiredCredits() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 3,
            reportedTotalEarnedCount: 4,
            credits: [
                .init(title: "Full reset (earned)", status: "available", resetType: "full", expiresAt: Date(timeIntervalSince1970: 2_000), grantedAt: nil),
                .init(title: "Expired", status: "available", resetType: "weekly", expiresAt: now, grantedAt: nil),
                .init(title: "Used", status: "used", resetType: "weekly", expiresAt: Date(timeIntervalSince1970: 3_000), grantedAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 900)
        )

        let presentation = codexResetCreditsPresentation(
            snapshot: snapshot,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.availableCount, 1)
        XCTAssertEqual(presentation.badgeText, "1")
        XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("1 reset credit available"))
        XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("Full reset"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("(earned)"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("Expired"))
        XCTAssertFalse(try XCTUnwrap(presentation.tooltip).contains("Used"))
    }

    func testPresentationUsesUnknownExpirationAndReportedCountFallback() throws {
        let unknown = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: nil,
            credits: [.init(title: nil, status: "AVAILABLE", resetType: nil, expiresAt: nil, grantedAt: nil)],
            fetchedAt: .distantPast
        )
        let fallback = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 4,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )

        let unknownPresentation = codexResetCreditsPresentation(snapshot: unknown, now: .now)
        let fallbackPresentation = codexResetCreditsPresentation(snapshot: fallback, now: .now)

        XCTAssertEqual(unknownPresentation.badgeText, "1")
        XCTAssertTrue(try XCTUnwrap(unknownPresentation.tooltip).contains("Reset credit · Expiration unavailable"))
        XCTAssertEqual(fallbackPresentation.badgeText, "4")
        XCTAssertTrue(try XCTUnwrap(fallbackPresentation.tooltip).contains("Expiration details unavailable"))
    }

    func testPresentationHidesZeroAndCapsLargeBadgeAtNinetyNinePlus() {
        let zero = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 0,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )
        let large = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 100,
            reportedTotalEarnedCount: nil,
            credits: [],
            fetchedAt: .distantPast
        )

        XCTAssertNil(codexResetCreditsPresentation(snapshot: zero, now: .now).badgeText)
        XCTAssertEqual(codexResetCreditsPresentation(snapshot: large, now: .now).badgeText, "99+")
    }

    func testPresentationFormatsLocalExpirationAndAccessibilityText() throws {
        let expiration = Date(timeIntervalSince1970: 1_785_501_600)
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex.json",
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: 1,
            credits: [.init(
                title: "Full reset",
                status: "available",
                resetType: "full",
                expiresAt: expiration,
                grantedAt: nil
            )],
            fetchedAt: .distantPast
        )
        let timeZone = TimeZone(identifier: "Asia/Seoul")!
        let locale = Locale(identifier: "en_US_POSIX")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let expectedExpiration = formatter.string(from: expiration)

        let presentation = codexResetCreditsPresentation(
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_785_000_000),
            timeZone: timeZone,
            locale: locale
        )

        XCTAssertTrue(try XCTUnwrap(presentation.tooltip).contains("Full reset · \(expectedExpiration)"))
        XCTAssertTrue(try XCTUnwrap(presentation.accessibilityLabel).contains("1 reset credit available"))
        XCTAssertTrue(try XCTUnwrap(presentation.accessibilityLabel).contains(expectedExpiration))
    }
}

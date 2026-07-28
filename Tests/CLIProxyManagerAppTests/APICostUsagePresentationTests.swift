import CLIProxyManagerCore
import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class APICostUsagePresentationTests: XCTestCase {
    func testCompactPresentationPreservesExactTooltipsForZeroTinyAndNormalCosts() {
        let cases: [(String, String, String)] = [
            ("0", "$0.00", "Exact estimate: $0.0000."),
            ("0.004", "<$0.01", "Exact estimate: $0.0040."),
            ("12.345", "$12.35", "Exact estimate: $12.3450.")
        ]

        for (cost, visible, exact) in cases {
            let presentation = compactUsagePresentation(
                for: .apiCost(.available(makeCostSnapshot(dayCost: cost)))
            )
            let day = presentation.rows[0]

            XCTAssertEqual(day.value, visible)
            XCTAssertTrue(day.tooltip?.contains(exact) == true)
            XCTAssertTrue(day.tooltip?.contains("UTC") == true)
            XCTAssertTrue(day.tooltip?.contains("Estimated API cost") == true)
        }
    }

    func testCompactPresentationShowsDayAndMonthCostWithoutQuotaSemantics() {
        let state = ProviderUsageState.apiCost(
            .available(makeCostSnapshot(dayCost: "0.004", monthCost: "8.73"))
        )

        let presentation = compactUsagePresentation(for: state)

        XCTAssertEqual(presentation.rows.map(\.label), ["Day", "Mon"])
        XCTAssertEqual(presentation.rows.map(\.value), ["<$0.01", "$8.73"])
        XCTAssertFalse(presentation.rows.flatMap { [$0.label, $0.value, $0.accessibilityLabel] }.contains {
            $0.contains("TOK") || $0.contains("REQ") || $0.contains("percent") || $0.contains("remaining")
        })
    }

    func testMonthUsesVisualAbbreviationAndFullAccessibilityPeriodName() {
        let rows = apiCostRows(snapshot: makeCostSnapshot())

        XCTAssertEqual(rows[1].label, "Mon")
        XCTAssertTrue(rows[1].accessibilityLabel.hasPrefix("Month,"))
        XCTAssertEqual(
            compactUsagePresentation(for: .apiCost(.available(makeCostSnapshot())))
                .rows[1].accessibilityLabel.hasPrefix("Month,"),
            true
        )
    }

    func testExpandedRowsIncludeCompactTokensRequestsAndExactTooltip() {
        let snapshot = makeCostSnapshot(
            dayCost: "0.42",
            monthCost: "8.73",
            dayTokens: 84_000,
            dayRequests: 14,
            timeZone: "Asia/Seoul",
            dayIssues: [.trackingStartedMidPeriod]
        )

        let rows = apiCostRows(snapshot: snapshot)

        XCTAssertEqual(rows[0].label, "Day")
        XCTAssertEqual(rows[0].detail, "84K TOK · 14 REQ")
        XCTAssertEqual(rows[0].cost, "$0.42")
        XCTAssertTrue(rows[0].tooltip.contains("Estimated API cost"))
        XCTAssertTrue(rows[0].tooltip.contains("Exact estimate: $0.4200."))
        XCTAssertTrue(rows[0].tooltip.contains("Asia/Seoul"))
        XCTAssertTrue(rows[0].tooltip.contains("Earlier usage"))
        XCTAssertEqual(
            rows[0].accessibilityLabel,
            "Day, estimated API cost $0.4200, 84000 tokens, 14 requests"
        )
    }

    func testLargeCostsAndDetailsUseAdaptiveSingleLineTextContract() {
        let costs = ["999.99", "1000.00", "12345.67", "123456789012345.67"]

        for cost in costs {
            let snapshot = makeCostSnapshot(
                dayCost: cost,
                dayTokens: 9_223_372_036_854_775_000,
                dayRequests: 9_223_372_036_854_775_000
            )
            let expanded = apiCostRows(snapshot: snapshot)[0]
            let compact = compactUsagePresentation(for: .apiCost(.available(snapshot))).rows[0]

            XCTAssertEqual(expanded.textLayout, .adaptiveSingleLine(minimumScaleFactor: 0.6))
            XCTAssertEqual(compact.textLayout, expanded.textLayout)
            XCTAssertFalse(expanded.cost.contains("\n"))
            XCTAssertFalse(expanded.detail.contains("\n"))
            XCTAssertFalse(compact.value.contains("\n"))
        }
    }

    func testAPICostRowsUseTextOnlyDecorationInsteadOfProgressOrPercentage() {
        let rows = apiCostRows(snapshot: makeCostSnapshot())

        XCTAssertTrue(rows.allSatisfy { $0.decoration == .textOnly })
    }

    func testCurrencyFormattingDistinguishesZeroTinyNormalAndExactValues() {
        XCTAssertEqual(apiCostCurrency(0), "$0.00")
        XCTAssertEqual(apiCostCurrency(Decimal(string: "0.0001")!), "<$0.01")
        XCTAssertEqual(apiCostCurrency(Decimal(string: "12.345")!), "$12.35")
        XCTAssertEqual(apiCostExactCurrency(Decimal(string: "12.345")!), "$12.3450")
    }

    func testCurrencyThresholdIsStableForCommaDecimalLocaleInput() throws {
        let frenchLocale = Locale(identifier: "fr_FR")
        let tinyCost = try XCTUnwrap(Decimal(string: "0,004", locale: frenchLocale))
        let oneCent = try XCTUnwrap(Decimal(string: "0,01", locale: frenchLocale))

        XCTAssertEqual(tinyCost, Decimal(sign: .plus, exponent: -3, significand: 4))
        XCTAssertEqual(apiCostCurrency(tinyCost), "<$0.01")
        XCTAssertEqual(apiCostCurrency(oneCent), "$0.01")
    }

    func testExactCurrencyPreservesEstimatorDecimalPrecisionWithoutScientificNotation() {
        let values: [(String, String)] = [
            ("0.000003125", "$0.000003125"),
            ("0.000000075", "$0.000000075"),
            ("12345678901234567890.123456789", "$12345678901234567890.123456789"),
            ("-0.000000075", "$-0.000000075")
        ]

        for (input, expected) in values {
            let presentation = apiCostExactCurrency(Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))!)
            XCTAssertEqual(presentation, expected)
            XCTAssertFalse(presentation.lowercased().contains("e"))
        }
    }

    func testExactCurrencyKeepsFourFractionDigitsAndNormalizesNegativeZero() {
        XCTAssertEqual(apiCostExactCurrency(0), "$0.0000")
        XCTAssertEqual(apiCostExactCurrency(Decimal(string: "12.34")!), "$12.3400")
        XCTAssertEqual(apiCostExactCurrency(Decimal(string: "-0.0000")!), "$0.0000")
    }

    func testCompactTokenCountPromotesRoundedThousandsToMillions() {
        XCTAssertEqual(compactTokenCount(84_000), "84K")
        XCTAssertEqual(compactTokenCount(999_949), "999.9K")
        XCTAssertEqual(compactTokenCount(999_950), "1M")
        XCTAssertEqual(compactTokenCount(999_999), "1M")
        XCTAssertEqual(compactTokenCount(1_000_000), "1M")
        XCTAssertEqual(compactTokenCount(1_800_000), "1.8M")
    }

    func testProviderUsageDisplayStateMapsAllAPICostStatesWithoutDroppingData() {
        let snapshot = makeCostSnapshot()
        let issues: [APICostIssue] = [.unknownModel, .persistenceFailure]

        XCTAssertEqual(providerUsageDisplayState(for: .apiCost(.disabled)), .hidden)
        XCTAssertEqual(
            providerUsageDisplayState(for: .apiCost(.loading)),
            .loading("Calculating API cost…")
        )
        XCTAssertEqual(
            providerUsageDisplayState(for: .apiCost(.available(snapshot))),
            .apiCost(snapshot, [])
        )
        XCTAssertEqual(
            providerUsageDisplayState(for: .apiCost(.partial(snapshot, issues))),
            .apiCost(snapshot, issues)
        )
        XCTAssertEqual(
            providerUsageDisplayState(for: .apiCost(.unavailable(.unknownModel))),
            .unavailable("Some request models are not in the bundled price catalog.")
        )
    }

    func testProviderUsageDisplayStatePreservesSubscriptionBehavior() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            providerUsageDisplayState(for: .subscription(.available(snapshot))),
            .subscription(snapshot, nil)
        )
        XCTAssertEqual(
            providerUsageDisplayState(for: .subscription(.stale(snapshot, .transientFailure))),
            .subscription(snapshot, .transientFailure)
        )
        XCTAssertEqual(
            providerUsageDisplayState(for: .subscription(.unavailable(.proxyUnavailable))),
            .unavailable("Usage unavailable — Local proxy is unavailable.")
        )
    }

    func testPeriodRowsKeepDayAndMonthIssuesSeparateAndStable() {
        let snapshot = makeCostSnapshot(
            dayIssues: [.persistenceFailure, .unknownModel],
            monthIssues: [.collectionGap]
        )

        let rows = apiCostRows(snapshot: snapshot)

        XCTAssertLessThan(
            try XCTUnwrap(rows[0].tooltip.range(of: "Some request models")).lowerBound,
            try XCTUnwrap(rows[0].tooltip.range(of: "could not be saved completely")).lowerBound
        )
        XCTAssertTrue(rows[0].tooltip.contains("Some request models are not in the bundled price catalog."))
        XCTAssertFalse(rows[0].tooltip.contains(apiCostIssueMessage(.collectionGap)))
        XCTAssertTrue(rows[1].tooltip.contains(apiCostIssueMessage(.collectionGap)))
        XCTAssertFalse(rows[1].tooltip.contains("Some request models"))
    }

    func testPartialWarningCombinesEstimateFreshnessTimezoneAndPeriodIssuesInStableOrder() throws {
        let snapshot = makeCostSnapshot(
            timeZone: "Asia/Seoul",
            dayIssues: [.persistenceFailure, .unknownModel],
            monthIssues: [.collectionGap]
        )
        let issues: [APICostIssue] = [.persistenceFailure, .collectionGap, .unknownModel]

        let message = apiCostWarningMessage(snapshot: snapshot, issues: issues)
        let compact = compactUsagePresentation(for: .apiCost(.partial(snapshot, issues)))

        XCTAssertTrue(message.hasPrefix("Estimated API cost may be incomplete.\n\nIssues\n"))
        XCTAssertTrue(message.contains("Day\n• Some request models are not in the bundled price catalog.\n• API usage could not be saved completely."))
        XCTAssertTrue(message.contains("Month\n• Some API requests could not be included in this estimate."))
        XCTAssertTrue(message.contains("\n\nDetails\n• Last updated:"))
        XCTAssertTrue(message.hasSuffix("• Time zone: Asia/Seoul"))
        XCTAssertLessThan(
            try XCTUnwrap(message.range(of: "Some request models")).lowerBound,
            try XCTUnwrap(message.range(of: "could not be saved completely")).lowerBound
        )
        XCTAssertEqual(compact.indicator, .warning(message: message))
    }

    func testWarningGroupsSharedAndSnapshotLevelIssuesUnderAccurateLabels() {
        let snapshot = makeCostSnapshot(
            dayIssues: [.collectionGap, .unknownModel],
            monthIssues: [.collectionGap, .persistenceFailure]
        )
        let message = apiCostWarningMessage(
            snapshot: snapshot,
            issues: [.collectionGap, .unknownModel, .persistenceFailure, .transientCollectionFailure]
        )

        XCTAssertEqual(message.components(separatedBy: apiCostIssueMessage(.collectionGap)).count - 1, 1)
        XCTAssertTrue(message.contains("Day and Month\n• \(apiCostIssueMessage(.collectionGap))"))
        XCTAssertTrue(message.contains("Day\n• \(apiCostIssueMessage(.unknownModel))"))
        XCTAssertTrue(message.contains("Month\n• \(apiCostIssueMessage(.persistenceFailure))"))
        XCTAssertTrue(message.contains("Collection status\n• \(apiCostIssueMessage(.transientCollectionFailure))"))
    }

    func testExpectedInitialAndPricingAssumptionsDoNotShowWarningIndicator() {
        let issues: [APICostIssue] = [
            .trackingStartedMidPeriod,
            .cacheWriteTTLAssumedDefault,
            .inferenceGeoAssumedGlobal,
            .fastModeAssumedStandard
        ]
        let snapshot = makeCostSnapshot(dayIssues: issues, monthIssues: issues)

        let presentation = apiCostUsagePresentation(snapshot: snapshot, issues: issues)
        let compact = compactUsagePresentation(for: .apiCost(.partial(snapshot, issues)))

        XCTAssertNil(presentation.warningMessage)
        XCTAssertNil(compact.indicator)
        XCTAssertNil(providerUsageWarningMessage(for: .apiCost(.partial(snapshot, issues))))
        for issue in issues {
            XCTAssertTrue(presentation.rows[0].tooltip.contains(apiCostIssueMessage(issue)))
            XCTAssertTrue(presentation.rows[1].tooltip.contains(apiCostIssueMessage(issue)))
        }
    }

    func testActualProblemShowsAccountWarningWithoutIncludingInformationalAssumptions() {
        let issues: [APICostIssue] = [
            .collectionGap,
            .cacheWriteTTLAssumedDefault,
            .inferenceGeoAssumedGlobal
        ]
        let snapshot = makeCostSnapshot(dayIssues: issues, monthIssues: issues)

        let presentation = apiCostUsagePresentation(snapshot: snapshot, issues: issues)
        let message = providerUsageWarningMessage(for: .apiCost(.partial(snapshot, issues)))

        XCTAssertEqual(message, presentation.warningMessage)
        XCTAssertTrue(message?.contains(apiCostIssueMessage(.collectionGap)) == true)
        XCTAssertFalse(message?.contains(apiCostIssueMessage(.cacheWriteTTLAssumedDefault)) == true)
        XCTAssertFalse(message?.contains(apiCostIssueMessage(.inferenceGeoAssumedGlobal)) == true)
        XCTAssertTrue(presentation.rows[0].tooltip.contains(apiCostIssueMessage(.cacheWriteTTLAssumedDefault)))
        XCTAssertTrue(presentation.rows[0].tooltip.contains(apiCostIssueMessage(.inferenceGeoAssumedGlobal)))
    }

    func testIssueMessagesUseUserFacingCopyForEveryIssue() {
        XCTAssertEqual(
            APICostIssue.allCases.map(apiCostIssueMessage),
            [
                "Local proxy is unavailable.",
                "Management key is not configured.",
                "Management key was rejected.",
                "This CLIProxyAPI version does not support API usage collection.",
                "API usage could not be collected.",
                "Earlier usage in this period is not included.",
                "Some API requests could not be included in this estimate.",
                "Requests made while usage tracking was disabled may be missing.",
                "Some requests use an unsupported accounting version.",
                "Some requests did not provide complete token accounting.",
                "Some API key requests could not be matched to a managed provider.",
                "Some request models are not in the bundled price catalog.",
                "Some request service tiers are not priced.",
                "Some request pricing variants are not priced.",
                "Some requests do not have a bundled price for their request date.",
                "Claude cache writes use the 5-minute cache rate because the queue does not expose TTL.",
                "Claude costs use global pricing because the queue does not expose inference geography. US-only inference may cost 10% more.",
                "Claude costs use standard-speed pricing because the queue does not expose request speed. Fast mode may cost more.",
                "The API usage ledger was created by a newer app version.",
                "A damaged API usage ledger was recovered; this period may be incomplete.",
                "API usage could not be saved completely.",
                "The saved reporting time zone is unavailable; UTC is being used."
            ]
        )
    }

    func testSingleRequestAndUnpricedRequestUseSingularAccessibleCopy() {
        let snapshot = makeCostSnapshot(dayRequests: 1, dayUnpricedRequests: 1)

        let day = apiCostRows(snapshot: snapshot)[0]

        XCTAssertEqual(day.detail, "84K TOK · 1 REQ")
        XCTAssertTrue(day.tooltip.contains("1 request could not be fully priced."))
        XCTAssertTrue(day.accessibilityLabel.hasSuffix("1 request"))
    }

    func testPresentationDoesNotExposeProfileOrRequestSensitiveData() {
        let snapshot = makeCostSnapshot(
            profileID: "raw-api-key auth_index request_id response_headers",
            dayIssues: [.priceEpochUnavailable]
        )

        let rendered = apiCostRows(snapshot: snapshot)
            .flatMap { [$0.id, $0.label, $0.detail, $0.cost, $0.tooltip, $0.accessibilityLabel] }
            .joined(separator: "\n")

        XCTAssertFalse(rendered.contains("raw-api-key"))
        XCTAssertFalse(rendered.contains("auth_index"))
        XCTAssertFalse(rendered.contains("request_id"))
        XCTAssertFalse(rendered.contains("response_headers"))
        XCTAssertFalse(rendered.contains("priceEpochUnavailable"))
        XCTAssertTrue(rendered.contains("bundled price for their request date"))
    }

    private func makeCostSnapshot(
        profileID: String = "claude-api",
        dayCost: String = "0.42",
        monthCost: String = "8.73",
        dayTokens: Int64 = 84_000,
        dayRequests: Int64 = 14,
        dayUnpricedRequests: Int64 = 0,
        timeZone: String = "UTC",
        dayIssues: [APICostIssue] = [],
        monthIssues: [APICostIssue] = []
    ) -> APICostSnapshot {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let day = APICostPeriodSnapshot(
            period: .day,
            estimatedUSD: Decimal(string: dayCost)!,
            totalTokens: dayTokens,
            requestCount: dayRequests,
            failedRequestCount: 0,
            pricedRequestCount: dayRequests - dayUnpricedRequests,
            unpricedRequestCount: dayUnpricedRequests,
            intervalStart: start,
            intervalEnd: end,
            issues: dayIssues
        )
        let month = APICostPeriodSnapshot(
            period: .month,
            estimatedUSD: Decimal(string: monthCost)!,
            totalTokens: 1_800_000,
            requestCount: 218,
            failedRequestCount: 0,
            pricedRequestCount: 218,
            unpricedRequestCount: 0,
            intervalStart: start,
            intervalEnd: end,
            issues: monthIssues
        )
        return APICostSnapshot(
            profileID: profileID,
            provider: .claude,
            day: day,
            month: month,
            reportingTimeZoneID: timeZone,
            updatedAt: end
        )
    }
}

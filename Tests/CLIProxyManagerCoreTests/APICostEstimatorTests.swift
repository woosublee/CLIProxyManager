import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class APICostEstimatorTests: XCTestCase {
    func testClaudeCostUsesDecimalAndDoesNotDoubleCountReasoning() throws {
        let ledger = readModel(bucket: makeBucket(
            provider: .claude,
            model: "claude-opus-5",
            uncached: 1_000_000,
            read: 1_000_000,
            write: 1_000_000,
            nonReasoning: 500_000,
            reasoning: 500_000,
            requests: 2
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected assumptions to be partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "36.75"))
        XCTAssertEqual(snapshot.day.totalTokens, 4_000_000)
        XCTAssertEqual(snapshot.day.requestCount, 2)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 2)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 0)
        XCTAssertTrue(issues.contains(.cacheWriteTTLAssumedDefault))
        XCTAssertTrue(issues.contains(.inferenceGeoAssumedGlobal))
        XCTAssertTrue(issues.contains(.fastModeAssumedStandard))
        XCTAssertEqual(snapshot.day.issues, issues)
        XCTAssertEqual(snapshot.month.issues, issues)
    }

    func testOpenAICacheWriteUsesItsSeparatePublishedRate() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            read: 1_000_000,
            write: 1_000_000,
            nonReasoning: 500_000,
            reasoning: 500_000,
            requests: 1
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .available(snapshot) = state else {
            return XCTFail("Expected available")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "20.875"))
    }

    func testMissingCacheRateKeepsKnownCostAndMarksRequestUnpriced() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.4",
            uncached: 1_000_000,
            write: 1_000_000,
            requests: 1
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.day.pricedRequestCount, 0)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 1)
        XCTAssertTrue(issues.contains(.unknownPricingVariant))
    }

    func testUnknownModelKeepsKnownTotalsAndMarksRequestsUnpriced() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-unknown",
            uncached: 100,
            requests: 3
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.totalTokens, 100)
        XCTAssertEqual(snapshot.day.requestCount, 3)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 0)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 3)
        XCTAssertTrue(issues.contains(.unknownModel))
    }

    func testUnavailablePriceEpochIsDistinctFromUnknownVariant() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 100,
            requests: 2,
            priceEpochStart: nil
        ))
        let futureEntry = APIPriceEntry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standard,
            effectiveFrom: iso("2026-07-26T00:00:00Z"),
            effectiveUntil: nil,
            rates: .init(
                uncachedInputUSDPerMillion: 1,
                cacheReadUSDPerMillion: nil,
                cacheWriteUSDPerMillion: nil,
                outputUSDPerMillion: 1
            )
        )

        let state = APICostEstimator(catalog: .init(version: 1, entries: [futureEntry]))
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
        XCTAssertTrue(issues.contains(.priceEpochUnavailable))
        XCTAssertFalse(issues.contains(.unknownPricingVariant))
    }

    func testExactZeroIsAvailableWhenTrackingCoversWholePeriodAndNoRequestsExist() {
        let ledger = completeEmptyReadModel()

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .available(snapshot) = state else {
            return XCTFail("Expected available zero")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.requestCount, 0)
        XCTAssertEqual(snapshot.month.estimatedUSD, 0)
        XCTAssertEqual(snapshot.month.requestCount, 0)
    }

    func testInvalidStoredTimeZoneUsesUTCAndMarksBothPeriodsPartial() {
        let base = completeEmptyReadModel()
        var metadata = base.metadata
        metadata.reportingTimeZoneID = "Invalid/Zone"
        let bounds = APIUsagePeriodCalculator.bounds(
            at: base.bounds.intervalReference,
            timeZoneID: metadata.reportingTimeZoneID
        )
        let ledger = APIUsageLedgerReadModel(
            metadata: metadata,
            bounds: bounds,
            currentMonth: base.currentMonth
        )

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertEqual(snapshot.reportingTimeZoneID, "UTC")
        XCTAssertEqual(snapshot.day.intervalStart, bounds.dayStart)
        XCTAssertEqual(snapshot.month.intervalStart, bounds.monthStart)
        XCTAssertEqual(snapshot.day.issues, [.invalidReportingTimeZone])
        XCTAssertEqual(snapshot.month.issues, [.invalidReportingTimeZone])
        XCTAssertEqual(issues, [.invalidReportingTimeZone])
    }

    func testPartialIntervalsAndIssueBucketsApplyOnlyWhenTheyOverlapPeriod() {
        let ledger = readModelWithCurrentCollectionGapAndIncompleteIssue()

        let state = APICostEstimator(catalog: .current)
            .states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertTrue(issues.contains(.collectionGap))
        XCTAssertTrue(issues.contains(.incompleteTokenAccounting))
        XCTAssertEqual(snapshot.day.requestCount, 3)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 1)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
    }

    func testMonthOnlyPartialIntervalDoesNotLeakIntoDayIssues() {
        let ledger = readModelWithMonthOnlyTrackingGap()

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected partial")
        }
        XCTAssertEqual(snapshot.day.issues, [])
        XCTAssertEqual(snapshot.month.issues, [.trackingStartedMidPeriod])
        XCTAssertEqual(issues, [.trackingStartedMidPeriod])
    }

    func testExactPriceEpochUsesMatchingEffectiveFromInsteadOfFirstObservedEpoch() {
        let oldEpoch = iso("2026-07-25T00:00:00Z")
        let newEpoch = iso("2026-07-25T12:00:00Z")
        let catalog = APIPriceCatalog(version: 1, entries: [
            priceEntry(from: oldEpoch, until: newEpoch, input: "1"),
            priceEntry(from: newEpoch, input: "10")
        ])
        let bucket = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 1,
            priceEpochStart: oldEpoch,
            firstObservedAt: iso("2026-07-25T13:00:00Z"),
            lastObservedAt: iso("2026-07-25T13:00:00Z")
        )
        let ledger = readModel(bucket: bucket, at: iso("2026-07-25T14:00:00Z"))

        let state = APICostEstimator(catalog: catalog)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .available(snapshot) = state else {
            return XCTFail("Expected exact epoch to be priced")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, 1)
    }

    func testNilPriceEpochCrossingCatalogBoundaryRemainsUnpriced() {
        let boundary = iso("2026-07-25T12:00:00Z")
        let catalog = APIPriceCatalog(version: 1, entries: [
            priceEntry(from: iso("2026-07-25T00:00:00Z"), until: boundary, input: "1"),
            priceEntry(from: boundary, input: "10")
        ])
        let bucket = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 2,
            priceEpochStart: nil,
            firstObservedAt: iso("2026-07-25T10:00:00Z"),
            lastObservedAt: iso("2026-07-25T13:00:00Z")
        )
        let ledger = readModel(bucket: bucket, at: iso("2026-07-25T14:00:00Z"))

        let state = APICostEstimator(catalog: catalog)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected crossed epoch to remain partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
        XCTAssertEqual(issues, [.priceEpochUnavailable])
    }

    func testFailedCompleteRequestsRemainPricedAndIncludedInTotals() {
        let ledger = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 2,
            failedRequests: 1
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .available(snapshot) = state else {
            return XCTFail("Expected failed complete request to remain priced")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.day.totalTokens, 1_000_000)
        XCTAssertEqual(snapshot.day.requestCount, 2)
        XCTAssertEqual(snapshot.day.failedRequestCount, 1)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 2)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 0)
    }

    func testUnknownProviderMappingAppliesToEveryEnabledProviderState() {
        let base = completeEmptyReadModel()
        var month = base.currentMonth
        month.issues = [
            .init(
                localDate: base.bounds.localDate,
                profileID: nil,
                provider: nil,
                reason: .unknownProviderMapping,
                count: 2
            )
        ]
        let ledger = APIUsageLedgerReadModel(
            metadata: base.metadata,
            bounds: base.bounds,
            currentMonth: month
        )

        let states = APICostEstimator(catalog: .current).states(
            for: [.claude: "claude-api", .openAI: "codex-api"],
            ledger: ledger,
            now: ledger.bounds.intervalReference
        )

        for profileID in ["claude-api", "codex-api"] {
            guard case let .partial(snapshot, issues) = states[profileID] else {
                return XCTFail("Expected unknown provider mapping on \(profileID)")
            }
            XCTAssertEqual(snapshot.day.requestCount, 2)
            XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
            XCTAssertEqual(snapshot.month.requestCount, 2)
            XCTAssertEqual(snapshot.month.unpricedRequestCount, 2)
            XCTAssertEqual(issues, [.unknownProviderMapping])
        }
    }

    func testClaudeAssumptionsUseExplicitCanonicalModelSets() {
        let cases: [(String, [APICostIssue])] = [
            ("claude-fable-5", [.inferenceGeoAssumedGlobal]),
            ("claude-opus-5", [.inferenceGeoAssumedGlobal, .fastModeAssumedStandard]),
            ("claude-opus-4-8", [.inferenceGeoAssumedGlobal, .fastModeAssumedStandard]),
            ("claude-opus-4-7", [.inferenceGeoAssumedGlobal, .fastModeAssumedStandard]),
            ("claude-opus-4-6", [.inferenceGeoAssumedGlobal]),
            ("claude-sonnet-5", [.inferenceGeoAssumedGlobal]),
            ("claude-sonnet-4-6", [.inferenceGeoAssumedGlobal]),
            ("claude-opus-4-5", []),
            ("claude-sonnet-4-5", []),
            ("claude-haiku-4-5", [])
        ]

        for (model, expectedIssues) in cases {
            let ledger = readModel(bucket: makeBucket(
                provider: .claude,
                model: model,
                uncached: 1,
                requests: 1
            ))
            let state = APICostEstimator(catalog: .current)
                .states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"]

            if expectedIssues.isEmpty {
                guard case .available = state else {
                    XCTFail("Expected no assumptions for \(model), got \(String(describing: state))")
                    continue
                }
            } else {
                guard case let .partial(_, issues) = state else {
                    XCTFail("Expected assumptions for \(model)")
                    continue
                }
                XCTAssertEqual(issues, expectedIssues, model)
            }
        }
    }

    func testClaudeCacheWriteTTLAssumptionDoesNotGuessGeoOrSpeedForOlderModel() {
        let ledger = readModel(bucket: makeBucket(
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            uncached: 1,
            write: 1,
            requests: 1
        ))

        let state = APICostEstimator(catalog: .current)
            .states(for: [.claude: "claude-api"], ledger: ledger, now: ledger.bounds.intervalReference)["claude-api"]

        guard case let .partial(_, issues) = state else {
            return XCTFail("Expected cache TTL assumption")
        }
        XCTAssertEqual(issues, [.cacheWriteTTLAssumedDefault])
    }

    func testNilPriceEpochEndingWithoutSuccessorRemainsUnpriced() {
        let catalog = APIPriceCatalog(version: 1, entries: [
            priceEntry(
                from: iso("2026-07-25T00:00:00Z"),
                until: iso("2026-07-25T12:00:00Z"),
                input: "1"
            )
        ])
        let bucket = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 2,
            priceEpochStart: nil,
            firstObservedAt: iso("2026-07-25T10:00:00Z"),
            lastObservedAt: iso("2026-07-25T13:00:00Z")
        )
        let ledger = readModel(bucket: bucket, at: iso("2026-07-25T14:00:00Z"))

        let state = APICostEstimator(catalog: catalog)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected ending-only price epoch to remain partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, 0)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 0)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 2)
        XCTAssertEqual(issues, [.priceEpochUnavailable])
    }

    func testInvalidPersistedCountersAreExcludedAndMarkCorruptedLedger() {
        let valid = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 1
        )
        var negative = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 0,
            requests: 0
        )
        negative.uncachedInputTokens = -10
        negative.totalTokens = -10
        negative.requestCount = -2
        var inconsistent = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 100,
            requests: 1
        )
        inconsistent.totalTokens = 99
        let ledger = readModel(
            buckets: [valid, negative, inconsistent],
            issues: [
                .init(
                    localDate: "2026-07-25",
                    profileID: "codex-api",
                    provider: .openAI,
                    reason: .incompleteTokenAccounting,
                    count: -3
                )
            ]
        )

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected invalid persisted counters to be partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.day.totalTokens, 1_000_000)
        XCTAssertEqual(snapshot.day.requestCount, 1)
        XCTAssertEqual(snapshot.day.failedRequestCount, 0)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 1)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 0)
        XCTAssertEqual(snapshot.month.totalTokens, 1_000_000)
        XCTAssertEqual(snapshot.month.requestCount, 1)
        XCTAssertEqual(issues, [.corruptedLedger])
    }

    func testPeriodAggregationOverflowExcludesOverflowingBucketAndMarksCorruptedLedger() {
        let large = Int64.max / 2 + 1
        let first = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: large,
            requests: 1
        )
        let second = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: large,
            requests: 1
        )
        let ledger = readModel(buckets: [first, second])

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected overflow to produce a corrupted partial snapshot")
        }
        XCTAssertEqual(snapshot.day.totalTokens, large)
        XCTAssertEqual(snapshot.day.requestCount, 1)
        XCTAssertEqual(snapshot.day.pricedRequestCount, 1)
        XCTAssertEqual(snapshot.day.unpricedRequestCount, 0)
        XCTAssertEqual(snapshot.month.totalTokens, large)
        XCTAssertEqual(snapshot.month.requestCount, 1)
        XCTAssertEqual(issues, [.corruptedLedger])
    }

    func testForeignMonthItemsAreExcludedFromJulyMonthAndMarkOnlyMonthCorrupted() {
        let july = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 1_000_000,
            requests: 1,
            localDate: "2026-07-25"
        )
        let august = makeBucket(
            provider: .openAI,
            model: "gpt-5.6-terra",
            uncached: 2_000_000,
            requests: 2,
            localDate: "2026-08-01",
            firstObservedAt: iso("2026-08-01T01:00:00Z"),
            lastObservedAt: iso("2026-08-01T01:00:00Z")
        )
        let ledger = readModel(
            buckets: [july, august],
            issues: [
                .init(
                    localDate: "2026-08-01",
                    profileID: "codex-api",
                    provider: .openAI,
                    reason: .incompleteTokenAccounting,
                    count: 3
                )
            ]
        )

        let state = APICostEstimator(catalog: .current)
            .states(for: [.openAI: "codex-api"], ledger: ledger, now: ledger.bounds.intervalReference)["codex-api"]

        guard case let .partial(snapshot, issues) = state else {
            return XCTFail("Expected foreign month entries to mark the month partial")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.day.requestCount, 1)
        XCTAssertEqual(snapshot.day.issues, [])
        XCTAssertEqual(snapshot.month.estimatedUSD, Decimal(string: "2.5"))
        XCTAssertEqual(snapshot.month.requestCount, 1)
        XCTAssertEqual(snapshot.month.issues, [.corruptedLedger])
        XCTAssertEqual(issues, [.corruptedLedger])
    }

    private func makeBucket(
        provider: APIUsageProvider,
        model: String,
        uncached: Int64,
        read: Int64 = 0,
        write: Int64 = 0,
        nonReasoning: Int64 = 0,
        reasoning: Int64 = 0,
        requests: Int64,
        failedRequests: Int64 = 0,
        localDate: String = "2026-07-25",
        priceEpochStart: Date? = ISO8601DateFormatter().date(from: "2026-07-25T00:00:00Z"),
        firstObservedAt: Date = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!,
        lastObservedAt: Date = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
    ) -> APIUsageLedgerBucket {
        APIUsageLedgerBucket(
            key: .init(
                localDate: localDate,
                profileID: provider.profileID,
                provider: provider,
                model: model,
                effectiveServiceTier: provider == .claude ? "standard" : "default",
                pricingVariant: .standard,
                priceEpochStart: priceEpochStart
            ),
            uncachedInputTokens: uncached,
            cacheReadTokens: read,
            cacheWriteTokens: write,
            nonReasoningOutputTokens: nonReasoning,
            reasoningOutputTokens: reasoning,
            totalTokens: uncached + read + write + nonReasoning + reasoning,
            requestCount: requests,
            failedRequestCount: failedRequests,
            firstObservedAt: firstObservedAt,
            lastObservedAt: lastObservedAt
        )
    }

    private func readModel(
        bucket: APIUsageLedgerBucket,
        at: Date = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
    ) -> APIUsageLedgerReadModel {
        readModel(buckets: [bucket], at: at)
    }

    private func readModel(
        buckets: [APIUsageLedgerBucket],
        issues: [APIUsageLedgerIssueBucket] = [],
        at: Date = ISO8601DateFormatter().date(from: "2026-07-25T12:00:00Z")!
    ) -> APIUsageLedgerReadModel {
        let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: "UTC")
        let metadata = APIUsageTrackingMetadata(
            schemaVersion: 1,
            reportingTimeZoneID: "UTC",
            trackingStartedAt: bounds.monthStart,
            lastSuccessfulDrainAt: at,
            lastObservedRequestAt: at,
            collectorPausedAt: nil,
            partialIntervals: []
        )
        let month = APIUsageMonthlyLedger(
            schemaVersion: 1,
            month: bounds.month,
            reportingTimeZoneID: "UTC",
            buckets: buckets,
            issues: issues
        )
        return .init(metadata: metadata, bounds: bounds, currentMonth: month)
    }

    private func completeEmptyReadModel() -> APIUsageLedgerReadModel {
        let base = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.4",
            uncached: 0,
            requests: 0
        ))
        return .init(
            metadata: base.metadata,
            bounds: base.bounds,
            currentMonth: .init(
                schemaVersion: 1,
                month: base.bounds.month,
                reportingTimeZoneID: "UTC",
                buckets: [],
                issues: []
            )
        )
    }

    private func readModelWithCurrentCollectionGapAndIncompleteIssue() -> APIUsageLedgerReadModel {
        let base = readModel(bucket: makeBucket(
            provider: .claude,
            model: "claude-opus-5",
            uncached: 10,
            requests: 1
        ))
        var metadata = base.metadata
        metadata.partialIntervals = [
            .init(start: base.bounds.dayStart, end: base.bounds.intervalReference, reason: .collectionGap)
        ]
        var month = base.currentMonth
        month.issues = [
            .init(
                localDate: base.bounds.localDate,
                profileID: "claude-api",
                provider: .claude,
                reason: .incompleteTokenAccounting,
                count: 2
            )
        ]
        return .init(metadata: metadata, bounds: base.bounds, currentMonth: month)
    }

    private func readModelWithMonthOnlyTrackingGap() -> APIUsageLedgerReadModel {
        let base = readModel(bucket: makeBucket(
            provider: .openAI,
            model: "gpt-5.4",
            uncached: 10,
            requests: 1
        ))
        var metadata = base.metadata
        metadata.partialIntervals = [
            .init(start: base.bounds.monthStart, end: base.bounds.dayStart, reason: .trackingStartedMidPeriod)
        ]
        return .init(metadata: metadata, bounds: base.bounds, currentMonth: base.currentMonth)
    }

    private func priceEntry(from: Date, until: Date? = nil, input: String) -> APIPriceEntry {
        APIPriceEntry(
            provider: .openAI,
            model: "gpt-5.6-terra",
            serviceTier: "default",
            variant: .standard,
            effectiveFrom: from,
            effectiveUntil: until,
            rates: .init(
                uncachedInputUSDPerMillion: Decimal(string: input)!,
                cacheReadUSDPerMillion: nil,
                cacheWriteUSDPerMillion: nil,
                outputUSDPerMillion: 1
            )
        )
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

import Foundation

public enum APICostPeriod: String, Equatable, Sendable {
    case day
    case month
}

public struct APICostPeriodSnapshot: Equatable, Sendable {
    public let period: APICostPeriod
    public let estimatedUSD: Decimal
    public let totalTokens: Int64
    public let requestCount: Int64
    public let failedRequestCount: Int64
    public let pricedRequestCount: Int64
    public let unpricedRequestCount: Int64
    public let intervalStart: Date
    public let intervalEnd: Date
    public let issues: [APICostIssue]

    public init(
        period: APICostPeriod,
        estimatedUSD: Decimal,
        totalTokens: Int64,
        requestCount: Int64,
        failedRequestCount: Int64,
        pricedRequestCount: Int64,
        unpricedRequestCount: Int64,
        intervalStart: Date,
        intervalEnd: Date,
        issues: [APICostIssue]
    ) {
        self.period = period
        self.estimatedUSD = estimatedUSD
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.failedRequestCount = failedRequestCount
        self.pricedRequestCount = pricedRequestCount
        self.unpricedRequestCount = unpricedRequestCount
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.issues = issues
    }
}

public struct APICostSnapshot: Equatable, Sendable {
    public let profileID: String
    public let provider: APIUsageProvider
    public let day: APICostPeriodSnapshot
    public let month: APICostPeriodSnapshot
    public let reportingTimeZoneID: String
    public let updatedAt: Date

    public init(
        profileID: String,
        provider: APIUsageProvider,
        day: APICostPeriodSnapshot,
        month: APICostPeriodSnapshot,
        reportingTimeZoneID: String,
        updatedAt: Date
    ) {
        self.profileID = profileID
        self.provider = provider
        self.day = day
        self.month = month
        self.reportingTimeZoneID = reportingTimeZoneID
        self.updatedAt = updatedAt
    }
}

public enum APICostIssue: String, Codable, CaseIterable, Equatable, Sendable {
    case proxyUnavailable
    case managementKeyNotConfigured
    case managementKeyRejected
    case managementAPINotSupported
    case transientCollectionFailure
    case trackingStartedMidPeriod
    case collectionGap
    case trackingWasDisabled
    case unsupportedAccountingVersion
    case incompleteTokenAccounting
    case unknownProviderMapping
    case unknownModel
    case unsupportedServiceTier
    case unknownPricingVariant
    case priceEpochUnavailable
    case cacheWriteTTLAssumedDefault
    case inferenceGeoAssumedGlobal
    case fastModeAssumedStandard
    case unsupportedLedgerVersion
    case corruptedLedger
    case persistenceFailure
    case invalidReportingTimeZone
}

public enum APICostUsageState: Equatable, Sendable {
    case disabled
    case loading
    case available(APICostSnapshot)
    case partial(APICostSnapshot, [APICostIssue])
    case unavailable(APICostIssue)

    public var snapshot: APICostSnapshot? {
        switch self {
        case let .available(snapshot), let .partial(snapshot, _):
            return snapshot
        case .disabled, .loading, .unavailable:
            return nil
        }
    }

    public var issues: [APICostIssue] {
        switch self {
        case let .partial(_, issues):
            return issues
        case let .unavailable(issue):
            return [issue]
        case .disabled, .loading, .available:
            return []
        }
    }
}

public struct APICostEstimator: Sendable {
    private let catalog: APIPriceCatalog

    private static let globalInferenceGeoModels: Set<String> = [
        "claude-fable-5",
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-sonnet-5",
        "claude-sonnet-4-6"
    ]

    private static let standardSpeedModels: Set<String> = [
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7"
    ]

    public init(catalog: APIPriceCatalog = .current) {
        self.catalog = catalog
    }

    public func states(
        for profiles: [APIUsageProvider: String],
        ledger: APIUsageLedgerReadModel,
        now: Date
    ) -> [String: APICostUsageState] {
        let invalidTimeZone = TimeZone(identifier: ledger.metadata.reportingTimeZoneID) == nil
        let bounds = invalidTimeZone
            ? APIUsagePeriodCalculator.bounds(at: ledger.bounds.intervalReference, timeZoneID: "UTC")
            : ledger.bounds
        let dayEnd = min(now, bounds.dayEnd)
        let monthEnd = min(now, bounds.monthEnd)
        let reportingTimeZoneID = invalidTimeZone ? "UTC" : bounds.resolvedTimeZoneID
        let updatedAt = ledger.metadata.lastSuccessfulDrainAt ?? ledger.metadata.trackingStartedAt

        return Dictionary(uniqueKeysWithValues: profiles.map { provider, profileID in
            var day = PeriodAccumulator()
            var month = PeriodAccumulator()

            if invalidTimeZone {
                day.add(issue: .invalidReportingTimeZone)
                month.add(issue: .invalidReportingTimeZone)
            }

            applyPartialIntervals(
                ledger.metadata.partialIntervals,
                to: &day,
                intervalStart: bounds.dayStart,
                intervalEnd: dayEnd
            )
            applyPartialIntervals(
                ledger.metadata.partialIntervals,
                to: &month,
                intervalStart: bounds.monthStart,
                intervalEnd: monthEnd
            )

            for bucket in ledger.currentMonth.buckets where bucket.key.provider == provider && bucket.key.profileID == profileID {
                add(bucket, to: &month)
                if bucket.key.localDate == bounds.localDate {
                    add(bucket, to: &day)
                }
            }

            for issueBucket in ledger.currentMonth.issues where applies(issueBucket, to: provider, profileID: profileID) {
                add(issueBucket, to: &month)
                if issueBucket.localDate == bounds.localDate {
                    add(issueBucket, to: &day)
                }
            }

            let daySnapshot = day.snapshot(
                period: .day,
                intervalStart: bounds.dayStart,
                intervalEnd: dayEnd
            )
            let monthSnapshot = month.snapshot(
                period: .month,
                intervalStart: bounds.monthStart,
                intervalEnd: monthEnd
            )
            let snapshot = APICostSnapshot(
                profileID: profileID,
                provider: provider,
                day: daySnapshot,
                month: monthSnapshot,
                reportingTimeZoneID: reportingTimeZoneID,
                updatedAt: updatedAt
            )
            let issues = ordered(daySnapshot.issues + monthSnapshot.issues)
            let state: APICostUsageState = issues.isEmpty
                ? .available(snapshot)
                : .partial(snapshot, issues)
            return (profileID, state)
        })
    }

    private func add(_ bucket: APIUsageLedgerBucket, to accumulator: inout PeriodAccumulator) {
        accumulator.totalTokens += bucket.totalTokens
        accumulator.requestCount += bucket.requestCount
        accumulator.failedRequestCount += bucket.failedRequestCount

        switch classification(for: bucket) {
        case let .priced(entry):
            accumulator.estimatedUSD += cost(
                tokens: bucket.uncachedInputTokens,
                rate: entry.rates.uncachedInputUSDPerMillion
            )
            accumulator.estimatedUSD += cost(
                tokens: bucket.nonReasoningOutputTokens + bucket.reasoningOutputTokens,
                rate: entry.rates.outputUSDPerMillion
            )

            var fullyPriced = true
            if bucket.cacheReadTokens != 0 {
                if let rate = entry.rates.cacheReadUSDPerMillion {
                    accumulator.estimatedUSD += cost(tokens: bucket.cacheReadTokens, rate: rate)
                } else {
                    fullyPriced = false
                }
            }
            if bucket.cacheWriteTokens != 0 {
                if let rate = entry.rates.cacheWriteUSDPerMillion {
                    accumulator.estimatedUSD += cost(tokens: bucket.cacheWriteTokens, rate: rate)
                    if bucket.key.provider == .claude {
                        accumulator.add(issue: .cacheWriteTTLAssumedDefault)
                    }
                } else {
                    fullyPriced = false
                }
            }

            if fullyPriced {
                accumulator.pricedRequestCount += bucket.requestCount
            } else {
                accumulator.unpricedRequestCount += bucket.requestCount
                accumulator.add(issue: .unknownPricingVariant)
            }

            if bucket.requestCount != 0,
               bucket.key.provider == .claude,
               Self.globalInferenceGeoModels.contains(entry.model) {
                accumulator.add(issue: .inferenceGeoAssumedGlobal)
            }
            if bucket.requestCount != 0,
               bucket.key.provider == .claude,
               Self.standardSpeedModels.contains(entry.model) {
                accumulator.add(issue: .fastModeAssumedStandard)
            }

        case .unknownModel:
            markUnpriced(bucket, issue: .unknownModel, in: &accumulator)
        case .unsupportedServiceTier:
            markUnpriced(bucket, issue: .unsupportedServiceTier, in: &accumulator)
        case .unknownPricingVariant:
            markUnpriced(bucket, issue: .unknownPricingVariant, in: &accumulator)
        case .priceEpochUnavailable:
            markUnpriced(bucket, issue: .priceEpochUnavailable, in: &accumulator)
        }
    }

    private func classification(for bucket: APIUsageLedgerBucket) -> APIPriceClassification {
        let key = bucket.key
        if let priceEpochStart = key.priceEpochStart {
            let classification = catalog.classification(
                provider: key.provider,
                model: key.model,
                serviceTier: key.effectiveServiceTier,
                variant: key.pricingVariant,
                at: priceEpochStart
            )
            if case let .priced(entry) = classification,
               entry.effectiveFrom != priceEpochStart {
                return .priceEpochUnavailable
            }
            return classification
        }

        let classification = catalog.classification(
            provider: key.provider,
            model: key.model,
            serviceTier: key.effectiveServiceTier,
            variant: key.pricingVariant,
            at: bucket.firstObservedAt
        )
        guard case let .priced(entry) = classification else {
            return classification
        }

        let crossedPriceBoundary = catalog.entries.contains {
            $0.provider == entry.provider
                && $0.model == entry.model
                && $0.serviceTier == entry.serviceTier
                && $0.variant == entry.variant
                && bucket.firstObservedAt < $0.effectiveFrom
                && $0.effectiveFrom <= bucket.lastObservedAt
        }
        return crossedPriceBoundary ? .priceEpochUnavailable : classification
    }

    private func markUnpriced(
        _ bucket: APIUsageLedgerBucket,
        issue: APICostIssue,
        in accumulator: inout PeriodAccumulator
    ) {
        accumulator.unpricedRequestCount += bucket.requestCount
        accumulator.add(issue: issue)
    }

    private func add(_ bucket: APIUsageLedgerIssueBucket, to accumulator: inout PeriodAccumulator) {
        accumulator.requestCount += bucket.count
        accumulator.unpricedRequestCount += bucket.count
        accumulator.add(issue: costIssue(for: bucket.reason))
    }

    private func applies(
        _ issue: APIUsageLedgerIssueBucket,
        to provider: APIUsageProvider,
        profileID: String
    ) -> Bool {
        if issue.reason == .unknownProviderMapping, issue.profileID == nil {
            return true
        }
        if let issueProfileID = issue.profileID, issueProfileID != profileID {
            return false
        }
        if let issueProvider = issue.provider, issueProvider != provider {
            return false
        }
        return issue.profileID != nil || issue.provider != nil
    }

    private func applyPartialIntervals(
        _ intervals: [APIUsagePartialInterval],
        to accumulator: inout PeriodAccumulator,
        intervalStart: Date,
        intervalEnd: Date
    ) {
        guard intervalStart < intervalEnd else { return }
        for interval in intervals {
            let partialEnd = interval.end ?? intervalEnd
            if interval.start < intervalEnd, intervalStart < partialEnd {
                accumulator.add(issue: costIssue(for: interval.reason))
            }
        }
    }

    private func costIssue(for reason: APIUsagePartialIntervalReason) -> APICostIssue {
        switch reason {
        case .trackingStartedMidPeriod:
            return .trackingStartedMidPeriod
        case .trackingWasDisabled:
            return .trackingWasDisabled
        case .collectionGap:
            return .collectionGap
        case .persistenceFailure:
            return .persistenceFailure
        case .corruptedLedger:
            return .corruptedLedger
        }
    }

    private func costIssue(for reason: APIUsageLedgerIssueReason) -> APICostIssue {
        switch reason {
        case .unsupportedAccountingVersion:
            return .unsupportedAccountingVersion
        case .incompleteTokenAccounting:
            return .incompleteTokenAccounting
        case .unknownProviderMapping:
            return .unknownProviderMapping
        }
    }

    private func cost(tokens: Int64, rate: Decimal) -> Decimal {
        Decimal(tokens) * rate / Decimal(1_000_000)
    }

    private func ordered(_ issues: [APICostIssue]) -> [APICostIssue] {
        APICostIssue.allCases.filter { issues.contains($0) }
    }
}

private struct PeriodAccumulator {
    var estimatedUSD: Decimal = 0
    var totalTokens: Int64 = 0
    var requestCount: Int64 = 0
    var failedRequestCount: Int64 = 0
    var pricedRequestCount: Int64 = 0
    var unpricedRequestCount: Int64 = 0
    var issues: [APICostIssue] = []

    mutating func add(issue: APICostIssue) {
        if !issues.contains(issue) {
            issues.append(issue)
        }
    }

    func snapshot(
        period: APICostPeriod,
        intervalStart: Date,
        intervalEnd: Date
    ) -> APICostPeriodSnapshot {
        APICostPeriodSnapshot(
            period: period,
            estimatedUSD: estimatedUSD,
            totalTokens: totalTokens,
            requestCount: requestCount,
            failedRequestCount: failedRequestCount,
            pricedRequestCount: pricedRequestCount,
            unpricedRequestCount: unpricedRequestCount,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            issues: APICostIssue.allCases.filter { issues.contains($0) }
        )
    }
}

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
                let dateDisposition = nestedDateDisposition(
                    localDate: bucket.key.localDate,
                    ledgerMonth: ledger.currentMonth.month,
                    bounds: bounds
                )
                guard case let .included(isCurrentDay) = dateDisposition,
                      isValid(bucket) else {
                    markCorrupted(dateDisposition, day: &day, month: &month)
                    continue
                }

                let contribution = contribution(for: bucket)
                month.merge(contribution)
                if isCurrentDay {
                    day.merge(contribution)
                }
            }

            for issueBucket in ledger.currentMonth.issues where applies(issueBucket, to: provider, profileID: profileID) {
                let dateDisposition = nestedDateDisposition(
                    localDate: issueBucket.localDate,
                    ledgerMonth: ledger.currentMonth.month,
                    bounds: bounds
                )
                guard case let .included(isCurrentDay) = dateDisposition,
                      issueBucket.count >= 0 else {
                    markCorrupted(dateDisposition, day: &day, month: &month)
                    continue
                }

                let contribution = BucketContribution(
                    requestCount: issueBucket.count,
                    unpricedRequestCount: issueBucket.count,
                    issues: [costIssue(for: issueBucket.reason)]
                )
                month.merge(contribution)
                if isCurrentDay {
                    day.merge(contribution)
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

    private func contribution(for bucket: APIUsageLedgerBucket) -> BucketContribution {
        var result = BucketContribution(
            totalTokens: bucket.totalTokens,
            requestCount: bucket.requestCount,
            failedRequestCount: bucket.failedRequestCount
        )

        switch classification(for: bucket) {
        case let .priced(entry):
            result.estimatedUSD += cost(
                tokens: bucket.uncachedInputTokens,
                rate: entry.rates.uncachedInputUSDPerMillion
            )
            result.estimatedUSD += cost(
                tokens: bucket.nonReasoningOutputTokens,
                rate: entry.rates.outputUSDPerMillion
            )
            result.estimatedUSD += cost(
                tokens: bucket.reasoningOutputTokens,
                rate: entry.rates.outputUSDPerMillion
            )

            var fullyPriced = true
            if bucket.cacheReadTokens != 0 {
                if let rate = entry.rates.cacheReadUSDPerMillion {
                    result.estimatedUSD += cost(tokens: bucket.cacheReadTokens, rate: rate)
                } else {
                    fullyPriced = false
                }
            }
            if bucket.cacheWriteTokens != 0 {
                if let rate = entry.rates.cacheWriteUSDPerMillion {
                    result.estimatedUSD += cost(tokens: bucket.cacheWriteTokens, rate: rate)
                    if bucket.key.provider == .claude {
                        result.add(issue: .cacheWriteTTLAssumedDefault)
                    }
                } else {
                    fullyPriced = false
                }
            }

            if fullyPriced {
                result.pricedRequestCount = bucket.requestCount
            } else {
                result.unpricedRequestCount = bucket.requestCount
                result.add(issue: .unknownPricingVariant)
            }

            if bucket.requestCount != 0,
               bucket.key.provider == .claude,
               Self.globalInferenceGeoModels.contains(entry.model) {
                result.add(issue: .inferenceGeoAssumedGlobal)
            }
            if bucket.requestCount != 0,
               bucket.key.provider == .claude,
               Self.standardSpeedModels.contains(entry.model) {
                result.add(issue: .fastModeAssumedStandard)
            }

        case .unknownModel:
            result.markUnpriced(issue: .unknownModel)
        case .unsupportedServiceTier:
            result.markUnpriced(issue: .unsupportedServiceTier)
        case .unknownPricingVariant:
            result.markUnpriced(issue: .unknownPricingVariant)
        case .priceEpochUnavailable:
            result.markUnpriced(issue: .priceEpochUnavailable)
        }

        return result
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
        guard entry.effectiveUntil.map({ bucket.lastObservedAt < $0 }) ?? true else {
            return .priceEpochUnavailable
        }

        let anotherEntryStartsDuringObservation = catalog.entries.contains {
            $0.provider == entry.provider
                && $0.model == entry.model
                && $0.serviceTier == entry.serviceTier
                && $0.variant == entry.variant
                && bucket.firstObservedAt < $0.effectiveFrom
                && $0.effectiveFrom <= bucket.lastObservedAt
        }
        return anotherEntryStartsDuringObservation ? .priceEpochUnavailable : classification
    }

    private func isValid(_ bucket: APIUsageLedgerBucket) -> Bool {
        let counters = [
            bucket.uncachedInputTokens,
            bucket.cacheReadTokens,
            bucket.cacheWriteTokens,
            bucket.nonReasoningOutputTokens,
            bucket.reasoningOutputTokens,
            bucket.totalTokens,
            bucket.requestCount,
            bucket.failedRequestCount
        ]
        guard counters.allSatisfy({ $0 >= 0 }),
              bucket.failedRequestCount <= bucket.requestCount,
              bucket.firstObservedAt <= bucket.lastObservedAt,
              checkedSum([
                  bucket.uncachedInputTokens,
                  bucket.cacheReadTokens,
                  bucket.cacheWriteTokens,
                  bucket.nonReasoningOutputTokens,
                  bucket.reasoningOutputTokens
              ]) == bucket.totalTokens else {
            return false
        }
        return true
    }

    private func checkedSum(_ values: [Int64]) -> Int64? {
        values.reduce(Optional(0)) { partial, value in
            guard let partial else { return nil }
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? nil : result
        }
    }

    private func nestedDateDisposition(
        localDate: String,
        ledgerMonth: String,
        bounds: APIUsagePeriodBounds
    ) -> NestedDateDisposition {
        guard let itemMonth = strictGregorianMonth(for: localDate) else {
            return .malformed
        }
        let isCurrentDay = localDate == bounds.localDate
        guard itemMonth == ledgerMonth, itemMonth == bounds.month else {
            return .foreignMonth(isCurrentDay: isCurrentDay)
        }
        return .included(isCurrentDay: isCurrentDay)
    }

    private func strictGregorianMonth(for localDate: String) -> String? {
        let bytes = Array(localDate.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }),
              let year = Int(String(bytes: bytes[0..<4], encoding: .utf8)!),
              let month = Int(String(bytes: bytes[5..<7], encoding: .utf8)!),
              let day = Int(String(bytes: bytes[8..<10], encoding: .utf8)!) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year,
              components.month == month,
              components.day == day else {
            return nil
        }
        return String(localDate.prefix(7))
    }

    private func markCorrupted(
        _ disposition: NestedDateDisposition,
        day: inout PeriodAccumulator,
        month: inout PeriodAccumulator
    ) {
        month.add(issue: .corruptedLedger)
        switch disposition {
        case let .included(isCurrentDay), let .foreignMonth(isCurrentDay):
            if isCurrentDay {
                day.add(issue: .corruptedLedger)
            }
        case .malformed:
            day.add(issue: .corruptedLedger)
        }
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

private enum NestedDateDisposition {
    case included(isCurrentDay: Bool)
    case foreignMonth(isCurrentDay: Bool)
    case malformed
}

private struct BucketContribution {
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

    mutating func markUnpriced(issue: APICostIssue) {
        unpricedRequestCount = requestCount
        add(issue: issue)
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

    mutating func merge(_ contribution: BucketContribution) {
        guard let totalTokens = checkedAdd(totalTokens, contribution.totalTokens),
              let requestCount = checkedAdd(requestCount, contribution.requestCount),
              let failedRequestCount = checkedAdd(failedRequestCount, contribution.failedRequestCount),
              let pricedRequestCount = checkedAdd(pricedRequestCount, contribution.pricedRequestCount),
              let unpricedRequestCount = checkedAdd(unpricedRequestCount, contribution.unpricedRequestCount) else {
            add(issue: .corruptedLedger)
            return
        }

        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.failedRequestCount = failedRequestCount
        self.pricedRequestCount = pricedRequestCount
        self.unpricedRequestCount = unpricedRequestCount
        estimatedUSD += contribution.estimatedUSD
        for issue in contribution.issues {
            add(issue: issue)
        }
    }

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

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }
}

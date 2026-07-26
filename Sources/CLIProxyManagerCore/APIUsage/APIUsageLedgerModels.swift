import Foundation

public enum APIUsageLedgerSchema {
    public static let currentVersion = 1
}

public struct APIUsageTrackingMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var reportingTimeZoneID: String
    public var trackingStartedAt: Date
    public var lastSuccessfulDrainAt: Date?
    public var lastObservedRequestAt: Date?
    public var collectorPausedAt: Date?
    public var partialIntervals: [APIUsagePartialInterval]

    public init(
        schemaVersion: Int,
        reportingTimeZoneID: String,
        trackingStartedAt: Date,
        lastSuccessfulDrainAt: Date? = nil,
        lastObservedRequestAt: Date? = nil,
        collectorPausedAt: Date? = nil,
        partialIntervals: [APIUsagePartialInterval] = []
    ) {
        self.schemaVersion = schemaVersion
        self.reportingTimeZoneID = reportingTimeZoneID
        self.trackingStartedAt = trackingStartedAt
        self.lastSuccessfulDrainAt = lastSuccessfulDrainAt
        self.lastObservedRequestAt = lastObservedRequestAt
        self.collectorPausedAt = collectorPausedAt
        self.partialIntervals = partialIntervals
    }
}

public enum APIUsagePartialIntervalReason: String, Codable, Equatable, Sendable {
    case trackingStartedMidPeriod
    case trackingWasDisabled
    case collectionGap
    case persistenceFailure
    case corruptedLedger
}

public struct APIUsagePartialInterval: Codable, Equatable, Sendable {
    public let start: Date
    public var end: Date?
    public let reason: APIUsagePartialIntervalReason

    public init(start: Date, end: Date?, reason: APIUsagePartialIntervalReason) {
        self.start = start
        self.end = end
        self.reason = reason
    }
}

public struct APIUsageLedgerBucketKey: Codable, Hashable, Sendable {
    public let localDate: String
    public let profileID: String
    public let provider: APIUsageProvider
    public let model: String
    public let effectiveServiceTier: String
    public let pricingVariant: APIUsagePricingVariant
    public let priceEpochStart: Date?

    public init(
        localDate: String,
        profileID: String,
        provider: APIUsageProvider,
        model: String,
        effectiveServiceTier: String,
        pricingVariant: APIUsagePricingVariant,
        priceEpochStart: Date?
    ) {
        self.localDate = localDate
        self.profileID = profileID
        self.provider = provider
        self.model = model
        self.effectiveServiceTier = effectiveServiceTier
        self.pricingVariant = pricingVariant
        self.priceEpochStart = priceEpochStart
    }
}

public struct APIUsageLedgerBucket: Codable, Equatable, Sendable {
    public let key: APIUsageLedgerBucketKey
    public var uncachedInputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var nonReasoningOutputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64
    public var requestCount: Int64
    public var failedRequestCount: Int64
    public var firstObservedAt: Date
    public var lastObservedAt: Date

    public init(
        key: APIUsageLedgerBucketKey,
        uncachedInputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64,
        nonReasoningOutputTokens: Int64,
        reasoningOutputTokens: Int64,
        totalTokens: Int64,
        requestCount: Int64,
        failedRequestCount: Int64,
        firstObservedAt: Date,
        lastObservedAt: Date
    ) {
        self.key = key
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.nonReasoningOutputTokens = nonReasoningOutputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.failedRequestCount = failedRequestCount
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

public struct APIUsageLedgerIssueBucket: Codable, Equatable, Sendable {
    public let localDate: String
    public let profileID: String?
    public let provider: APIUsageProvider?
    public let reason: APIUsageLedgerIssueReason
    public var count: Int64

    public init(
        localDate: String,
        profileID: String?,
        provider: APIUsageProvider?,
        reason: APIUsageLedgerIssueReason,
        count: Int64
    ) {
        self.localDate = localDate
        self.profileID = profileID
        self.provider = provider
        self.reason = reason
        self.count = count
    }
}

public struct APIUsageMonthlyLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let month: String
    public let reportingTimeZoneID: String
    public var buckets: [APIUsageLedgerBucket]
    public var issues: [APIUsageLedgerIssueBucket]

    public init(
        schemaVersion: Int,
        month: String,
        reportingTimeZoneID: String,
        buckets: [APIUsageLedgerBucket] = [],
        issues: [APIUsageLedgerIssueBucket] = []
    ) {
        self.schemaVersion = schemaVersion
        self.month = month
        self.reportingTimeZoneID = reportingTimeZoneID
        self.buckets = buckets
        self.issues = issues
    }
}

public struct APIUsagePeriodBounds: Equatable, Sendable {
    public let intervalReference: Date
    public let localDate: String
    public let month: String
    public let dayStart: Date
    public let dayEnd: Date
    public let monthStart: Date
    public let monthEnd: Date
    public let resolvedTimeZoneID: String
    public let usedUTCFallback: Bool

    public init(
        intervalReference: Date,
        localDate: String,
        month: String,
        dayStart: Date,
        dayEnd: Date,
        monthStart: Date,
        monthEnd: Date,
        resolvedTimeZoneID: String,
        usedUTCFallback: Bool
    ) {
        self.intervalReference = intervalReference
        self.localDate = localDate
        self.month = month
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.monthStart = monthStart
        self.monthEnd = monthEnd
        self.resolvedTimeZoneID = resolvedTimeZoneID
        self.usedUTCFallback = usedUTCFallback
    }
}

public struct APIUsageLedgerReadModel: Equatable, Sendable {
    public let metadata: APIUsageTrackingMetadata
    public let bounds: APIUsagePeriodBounds
    public let currentMonth: APIUsageMonthlyLedger

    public init(metadata: APIUsageTrackingMetadata, bounds: APIUsagePeriodBounds, currentMonth: APIUsageMonthlyLedger) {
        self.metadata = metadata
        self.bounds = bounds
        self.currentMonth = currentMonth
    }
}

public enum APIUsagePeriodCalculator {
    public static func bounds(at intervalReference: Date, timeZoneID: String) -> APIUsagePeriodBounds {
        let requestedTimeZone = TimeZone(identifier: timeZoneID)
        let usedUTCFallback = requestedTimeZone == nil
        let timeZone = requestedTimeZone ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let dayStart = calendar.startOfDay(for: intervalReference)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let monthComponents = calendar.dateComponents([.year, .month], from: intervalReference)
        let monthStart = calendar.date(from: monthComponents)!
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!

        return APIUsagePeriodBounds(
            intervalReference: intervalReference,
            localDate: formatted(intervalReference, format: "yyyy-MM-dd", calendar: calendar, timeZone: timeZone),
            month: formatted(intervalReference, format: "yyyy-MM", calendar: calendar, timeZone: timeZone),
            dayStart: dayStart,
            dayEnd: dayEnd,
            monthStart: monthStart,
            monthEnd: monthEnd,
            resolvedTimeZoneID: usedUTCFallback ? "UTC" : timeZone.identifier,
            usedUTCFallback: usedUTCFallback
        )
    }

    private static func formatted(_ date: Date, format: String, calendar: Calendar, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

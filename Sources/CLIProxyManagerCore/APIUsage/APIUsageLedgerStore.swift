import Darwin
import Foundation

public enum APIUsageLedgerMutation: Equatable, Sendable {
    case aggregate(APIUsageAggregateInput, priceEpochStart: Date?)
    case issue(APIUsageIssueInput)
}

public enum APIUsageLedgerStoreError: Error, Equatable, Sendable {
    case notInitialized
    case unsupportedSchemaVersion(Int)
    case invalidFile
    case persistenceFailure
}

public protocol APIUsageLedgerStoring: Sendable {
    func prepareTracking(at: Date, reportingTimeZoneID: String) async throws
    func merge(_ mutations: [APIUsageLedgerMutation]) async throws
    func markPaused(at: Date, proxyCouldServeRequests: Bool) async throws
    func markResumed(at: Date) async throws
    func markCollectionGap(from: Date, to: Date) async throws
    func markSuccessfulDrain(at: Date, lastObservedRequestAt: Date?) async throws
    func readCurrentPeriods(at: Date) async throws -> APIUsageLedgerReadModel
    func flush() async throws
}

public actor APIUsageLedgerStore: APIUsageLedgerStoring {
    private struct SchemaVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct CounterOverflow: Error {}

    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let writeDelayNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let beforeCorruptBackupMove: @Sendable (URL) throws -> Void

    private var metadata: APIUsageTrackingMetadata?
    private var ledgers: [String: APIUsageMonthlyLedger] = [:]
    private var dirtyMetadata = false
    private var dirtyMonths: Set<String> = []
    private var pendingWriteTask: Task<Void, Never>?
    private var debounceGeneration: UInt64 = 0

    public init(
        paths: ManagedPaths = ManagedPaths(),
        fileManager: FileManager = .default,
        writeDelayNanoseconds: UInt64 = 1_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.writeDelayNanoseconds = writeDelayNanoseconds
        self.sleep = sleep
        self.beforeCorruptBackupMove = { _ in }
    }

    init(
        paths: ManagedPaths = ManagedPaths(),
        fileManager: FileManager = .default,
        writeDelayNanoseconds: UInt64 = 1_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        beforeCorruptBackupMove: @escaping @Sendable (URL) throws -> Void
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.writeDelayNanoseconds = writeDelayNanoseconds
        self.sleep = sleep
        self.beforeCorruptBackupMove = beforeCorruptBackupMove
    }

    public func prepareTracking(at: Date, reportingTimeZoneID: String) async throws {
        if metadata != nil {
            return
        }

        _ = try ensureUsageDirectory(createIfMissing: true, repairPermissions: true)
        if let data = try readSecureFile(at: paths.apiUsageMetadataFile) {
            metadata = try decodeMetadata(data)
            return
        }

        let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: reportingTimeZoneID)
        let storedTimeZoneID = TimeZone(identifier: reportingTimeZoneID) == nil
            ? "UTC"
            : reportingTimeZoneID
        var newMetadata = APIUsageTrackingMetadata(
            schemaVersion: APIUsageLedgerSchema.currentVersion,
            reportingTimeZoneID: storedTimeZoneID,
            trackingStartedAt: at
        )
        if at > bounds.monthStart {
            addPartialInterval(
                start: bounds.monthStart,
                end: at,
                reason: .trackingStartedMidPeriod,
                to: &newMetadata
            )
        }
        metadata = newMetadata
        dirtyMetadata = true
        scheduleWrite()
    }

    public func merge(_ mutations: [APIUsageLedgerMutation]) async throws {
        try ensureMetadataLoaded()
        guard !mutations.isEmpty else { return }

        let storedTimeZoneID = metadata!.reportingTimeZoneID
        let mutationBounds = mutations.map { mutation in
            let timestamp: Date
            switch mutation {
            case let .aggregate(input, _):
                timestamp = input.timestamp
            case let .issue(input):
                timestamp = input.timestamp
            }
            return APIUsagePeriodCalculator.bounds(at: timestamp, timeZoneID: storedTimeZoneID)
        }
        var candidateLedgers: [String: APIUsageMonthlyLedger] = [:]
        var touchedMonths: Set<String> = []

        for (mutation, bounds) in zip(mutations, mutationBounds) {
            var ledger = try candidateLedgers[bounds.month]
                ?? loadLedger(month: bounds.month, at: bounds.intervalReference)

            do {
                switch mutation {
                case let .aggregate(input, priceEpochStart):
                    try mergeAggregate(
                        input,
                        priceEpochStart: priceEpochStart,
                        localDate: bounds.localDate,
                        into: &ledger
                    )
                case let .issue(input):
                    try mergeIssue(input, localDate: bounds.localDate, into: &ledger)
                }
            } catch is CounterOverflow {
                markPersistenceFailure(for: mutationBounds)
                throw APIUsageLedgerStoreError.persistenceFailure
            }

            candidateLedgers[bounds.month] = ledger
            touchedMonths.insert(bounds.month)
        }

        for month in touchedMonths {
            ledgers[month] = candidateLedgers[month]
        }
        dirtyMonths.formUnion(touchedMonths)
        scheduleWrite()
    }

    public func markPaused(at: Date, proxyCouldServeRequests: Bool) async throws {
        try ensureMetadataLoaded()
        guard proxyCouldServeRequests, metadata!.collectorPausedAt == nil else { return }

        metadata!.collectorPausedAt = at
        dirtyMetadata = true
        scheduleWrite()
    }

    public func markResumed(at: Date) async throws {
        try ensureMetadataLoaded()
        guard let pausedAt = metadata!.collectorPausedAt else { return }

        var updatedMetadata = metadata!
        updatedMetadata.collectorPausedAt = nil
        addPartialInterval(
            start: min(pausedAt, at),
            end: max(pausedAt, at),
            reason: .trackingWasDisabled,
            to: &updatedMetadata
        )
        metadata = updatedMetadata
        dirtyMetadata = true
        scheduleWrite()
    }

    public func markCollectionGap(from: Date, to: Date) async throws {
        try ensureMetadataLoaded()
        guard to > from else { return }

        var updatedMetadata = metadata!
        addPartialInterval(start: from, end: to, reason: .collectionGap, to: &updatedMetadata)
        metadata = updatedMetadata
        dirtyMetadata = true
        scheduleWrite()
    }

    public func markSuccessfulDrain(at: Date, lastObservedRequestAt: Date?) async throws {
        try ensureMetadataLoaded()

        var updatedMetadata = metadata!
        updatedMetadata.lastSuccessfulDrainAt = maxDate(updatedMetadata.lastSuccessfulDrainAt, at)
        if let lastObservedRequestAt {
            updatedMetadata.lastObservedRequestAt = maxDate(
                updatedMetadata.lastObservedRequestAt,
                lastObservedRequestAt
            )
        }
        metadata = updatedMetadata
        dirtyMetadata = true
        scheduleWrite()
    }

    public func readCurrentPeriods(at: Date) async throws -> APIUsageLedgerReadModel {
        try ensureMetadataLoaded()
        let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: metadata!.reportingTimeZoneID)
        let currentMonth = try loadLedger(month: bounds.month, at: at)
        return APIUsageLedgerReadModel(metadata: metadata!, bounds: bounds, currentMonth: currentMonth)
    }

    public func flush() async throws {
        debounceGeneration &+= 1
        let task = pendingWriteTask
        pendingWriteTask = nil
        task?.cancel()
        if let task {
            await task.value
        }
        try persistDirtyFiles()
    }

    private func ensureMetadataLoaded() throws {
        guard metadata == nil else { return }
        guard try ensureUsageDirectory(createIfMissing: false, repairPermissions: false) else {
            throw APIUsageLedgerStoreError.notInitialized
        }
        guard let data = try readSecureFile(at: paths.apiUsageMetadataFile) else {
            throw APIUsageLedgerStoreError.notInitialized
        }
        metadata = try decodeMetadata(data)
    }

    private func decodeMetadata(_ data: Data) throws -> APIUsageTrackingMetadata {
        let version: Int
        do {
            version = try decoder().decode(SchemaVersionEnvelope.self, from: data).schemaVersion
        } catch {
            throw APIUsageLedgerStoreError.invalidFile
        }
        if version > APIUsageLedgerSchema.currentVersion {
            throw APIUsageLedgerStoreError.unsupportedSchemaVersion(version)
        }
        guard version == APIUsageLedgerSchema.currentVersion else {
            throw APIUsageLedgerStoreError.invalidFile
        }

        let decoded: APIUsageTrackingMetadata
        do {
            decoded = try decoder().decode(APIUsageTrackingMetadata.self, from: data)
        } catch {
            throw APIUsageLedgerStoreError.invalidFile
        }
        guard TimeZone(identifier: decoded.reportingTimeZoneID) != nil else {
            throw APIUsageLedgerStoreError.invalidFile
        }
        return decoded
    }

    private func loadLedger(month: String, at: Date) throws -> APIUsageMonthlyLedger {
        if let cached = ledgers[month] {
            return cached
        }

        let file = paths.apiUsageMonthlyLedgerFile(month: month)
        guard let data = try readSecureFile(at: file) else {
            let ledger = emptyLedger(month: month)
            ledgers[month] = ledger
            return ledger
        }

        let version: Int
        do {
            version = try decoder().decode(SchemaVersionEnvelope.self, from: data).schemaVersion
        } catch {
            return try recoverCorruptedLedger(month: month, at: at)
        }
        if version > APIUsageLedgerSchema.currentVersion {
            throw APIUsageLedgerStoreError.unsupportedSchemaVersion(version)
        }
        guard version == APIUsageLedgerSchema.currentVersion else {
            return try recoverCorruptedLedger(month: month, at: at)
        }

        let decoded: APIUsageMonthlyLedger
        do {
            decoded = try decoder().decode(APIUsageMonthlyLedger.self, from: data)
        } catch {
            return try recoverCorruptedLedger(month: month, at: at)
        }
        guard decoded.month == month,
              decoded.reportingTimeZoneID == metadata!.reportingTimeZoneID else {
            return try recoverCorruptedLedger(month: month, at: at)
        }

        ledgers[month] = decoded
        return decoded
    }

    private func recoverCorruptedLedger(month: String, at: Date) throws -> APIUsageMonthlyLedger {
        let source = paths.apiUsageMonthlyLedgerFile(month: month)
        let backup = try withStoreLock {
            _ = try validateExistingFile(at: source)
            return try moveCorruptedLedgerExclusively(source: source, month: month, at: at)
        }

        let backupDescriptor = open(backup.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard backupDescriptor >= 0 else {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
        defer { close(backupDescriptor) }
        guard fchmod(backupDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
        try validateFileDescriptor(backupDescriptor)

        let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: metadata!.reportingTimeZoneID)
        var updatedMetadata = metadata!
        addPartialInterval(
            start: bounds.monthStart,
            end: max(bounds.monthStart, at),
            reason: .corruptedLedger,
            to: &updatedMetadata
        )
        metadata = updatedMetadata
        dirtyMetadata = true

        let ledger = emptyLedger(month: month)
        ledgers[month] = ledger
        dirtyMonths.insert(month)
        scheduleWrite()
        return ledger
    }

    private func moveCorruptedLedgerExclusively(
        source: URL,
        month: String,
        at: Date
    ) throws -> URL {
        let unixTime = Int64(at.timeIntervalSince1970.rounded(.down))
        for suffix in 0 ..< 10_000 {
            let suffixText = suffix == 0 ? "" : "-\(suffix)"
            let candidate = paths.apiUsageDirectory
                .appendingPathComponent("\(month).corrupt-\(unixTime)\(suffixText).json")
            try beforeCorruptBackupMove(candidate)

            while true {
                if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                    return candidate
                }
                if errno == EINTR {
                    continue
                }
                if errno == EEXIST {
                    break
                }
                throw APIUsageLedgerStoreError.persistenceFailure
            }
        }
        throw APIUsageLedgerStoreError.persistenceFailure
    }

    private func emptyLedger(month: String) -> APIUsageMonthlyLedger {
        APIUsageMonthlyLedger(
            schemaVersion: APIUsageLedgerSchema.currentVersion,
            month: month,
            reportingTimeZoneID: metadata!.reportingTimeZoneID
        )
    }

    private func mergeAggregate(
        _ input: APIUsageAggregateInput,
        priceEpochStart: Date?,
        localDate: String,
        into ledger: inout APIUsageMonthlyLedger
    ) throws {
        let key = APIUsageLedgerBucketKey(
            localDate: localDate,
            profileID: input.profileID,
            provider: input.provider,
            model: input.model,
            effectiveServiceTier: input.effectiveServiceTier,
            pricingVariant: input.pricingVariant,
            priceEpochStart: priceEpochStart
        )

        guard let index = ledger.buckets.firstIndex(where: { $0.key == key }) else {
            ledger.buckets.append(APIUsageLedgerBucket(
                key: key,
                uncachedInputTokens: input.tokenBreakdown.input.uncachedTokens,
                cacheReadTokens: input.tokenBreakdown.input.cacheReadTokens,
                cacheWriteTokens: input.tokenBreakdown.input.cacheWriteTokens,
                nonReasoningOutputTokens: input.tokenBreakdown.output.nonReasoningTokens,
                reasoningOutputTokens: input.tokenBreakdown.output.reasoningTokens,
                totalTokens: input.tokenBreakdown.totalTokens,
                requestCount: 1,
                failedRequestCount: input.failed ? 1 : 0,
                firstObservedAt: input.timestamp,
                lastObservedAt: input.timestamp
            ))
            return
        }

        var bucket = ledger.buckets[index]
        let uncachedInputTokens = try checkedAdd(
            bucket.uncachedInputTokens,
            input.tokenBreakdown.input.uncachedTokens
        )
        let cacheReadTokens = try checkedAdd(
            bucket.cacheReadTokens,
            input.tokenBreakdown.input.cacheReadTokens
        )
        let cacheWriteTokens = try checkedAdd(
            bucket.cacheWriteTokens,
            input.tokenBreakdown.input.cacheWriteTokens
        )
        let nonReasoningOutputTokens = try checkedAdd(
            bucket.nonReasoningOutputTokens,
            input.tokenBreakdown.output.nonReasoningTokens
        )
        let reasoningOutputTokens = try checkedAdd(
            bucket.reasoningOutputTokens,
            input.tokenBreakdown.output.reasoningTokens
        )
        let totalTokens = try checkedAdd(bucket.totalTokens, input.tokenBreakdown.totalTokens)
        let requestCount = try checkedAdd(bucket.requestCount, 1)
        let failedRequestCount = try checkedAdd(bucket.failedRequestCount, input.failed ? 1 : 0)

        bucket.uncachedInputTokens = uncachedInputTokens
        bucket.cacheReadTokens = cacheReadTokens
        bucket.cacheWriteTokens = cacheWriteTokens
        bucket.nonReasoningOutputTokens = nonReasoningOutputTokens
        bucket.reasoningOutputTokens = reasoningOutputTokens
        bucket.totalTokens = totalTokens
        bucket.requestCount = requestCount
        bucket.failedRequestCount = failedRequestCount
        bucket.firstObservedAt = min(bucket.firstObservedAt, input.timestamp)
        bucket.lastObservedAt = max(bucket.lastObservedAt, input.timestamp)
        ledger.buckets[index] = bucket
    }

    private func mergeIssue(
        _ input: APIUsageIssueInput,
        localDate: String,
        into ledger: inout APIUsageMonthlyLedger
    ) throws {
        guard let index = ledger.issues.firstIndex(where: {
            $0.localDate == localDate
                && $0.profileID == input.profileID
                && $0.provider == input.provider
                && $0.reason == input.reason
        }) else {
            ledger.issues.append(APIUsageLedgerIssueBucket(
                localDate: localDate,
                profileID: input.profileID,
                provider: input.provider,
                reason: input.reason,
                count: 1
            ))
            return
        }

        var issue = ledger.issues[index]
        issue.count = try checkedAdd(issue.count, 1)
        ledger.issues[index] = issue
    }

    private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CounterOverflow() }
        return result
    }

    private func markPersistenceFailure(for bounds: [APIUsagePeriodBounds]) {
        var updatedMetadata = metadata!
        for bound in bounds {
            addPartialInterval(
                start: bound.dayStart,
                end: bound.dayEnd,
                reason: .persistenceFailure,
                to: &updatedMetadata
            )
        }
        metadata = updatedMetadata
        dirtyMetadata = true
        scheduleWrite()
    }

    private func addPartialInterval(
        start: Date,
        end: Date?,
        reason: APIUsagePartialIntervalReason,
        to metadata: inout APIUsageTrackingMetadata
    ) {
        var sameReason = metadata.partialIntervals.filter { $0.reason == reason }
        sameReason.append(APIUsagePartialInterval(start: start, end: end, reason: reason))
        sameReason.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return intervalEnd(lhs.end) < intervalEnd(rhs.end)
        }

        var union: [APIUsagePartialInterval] = []
        for interval in sameReason {
            guard var last = union.last else {
                union.append(interval)
                continue
            }
            if interval.start <= intervalEnd(last.end) {
                last = APIUsagePartialInterval(
                    start: last.start,
                    end: mergedEnd(last.end, interval.end),
                    reason: reason
                )
                union[union.count - 1] = last
            } else {
                union.append(interval)
            }
        }

        metadata.partialIntervals.removeAll { $0.reason == reason }
        metadata.partialIntervals.append(contentsOf: union)
        metadata.partialIntervals.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.reason.rawValue != rhs.reason.rawValue {
                return lhs.reason.rawValue < rhs.reason.rawValue
            }
            return intervalEnd(lhs.end) < intervalEnd(rhs.end)
        }
    }

    private func intervalEnd(_ date: Date?) -> Date {
        date ?? .distantFuture
    }

    private func mergedEnd(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs, let rhs else { return nil }
        return max(lhs, rhs)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private func scheduleWrite() {
        guard pendingWriteTask == nil else { return }
        let generation = debounceGeneration
        let delay = writeDelayNanoseconds
        let sleep = sleep
        pendingWriteTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performDebouncedWrite(generation: generation)
        }
    }

    private func performDebouncedWrite(generation: UInt64) {
        guard generation == debounceGeneration else { return }
        pendingWriteTask = nil
        do {
            try persistDirtyFiles()
        } catch {
            // Dirty state stays in memory. An explicit flush or later mutation retries it.
        }
    }

    private func persistDirtyFiles() throws {
        guard dirtyMetadata || !dirtyMonths.isEmpty else { return }

        try withStoreLock {
            for month in dirtyMonths.sorted() {
                guard let ledger = ledgers[month] else {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                let data: Data
                do {
                    data = try encoder().encode(ledger)
                } catch {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                try writeSecurely(data, to: paths.apiUsageMonthlyLedgerFile(month: month))
                dirtyMonths.remove(month)
            }

            if dirtyMetadata {
                guard let metadata else {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                let data: Data
                do {
                    data = try encoder().encode(metadata)
                } catch {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                try writeSecurely(data, to: paths.apiUsageMetadataFile)
                dirtyMetadata = false
            }
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        _ = try ensureUsageDirectory(createIfMissing: true, repairPermissions: true)
        let descriptor = try openStoreLockFile()
        defer { close(descriptor) }

        try acquireExclusiveLock(descriptor)
        defer { releaseExclusiveLock(descriptor) }
        return try body()
    }

    private func openStoreLockFile() throws -> Int32 {
        let file = paths.apiUsageDirectory.appendingPathComponent(".store.lock")
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW

        while true {
            let createdDescriptor = open(
                file.path,
                flags | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
            if createdDescriptor >= 0 {
                guard fchmod(createdDescriptor, S_IRUSR | S_IWUSR) == 0 else {
                    close(createdDescriptor)
                    _ = unlink(file.path)
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                do {
                    try validateFileDescriptor(createdDescriptor)
                    return createdDescriptor
                } catch {
                    close(createdDescriptor)
                    _ = unlink(file.path)
                    throw error
                }
            }
            guard errno == EEXIST else {
                throw APIUsageLedgerStoreError.persistenceFailure
            }

            let existingDescriptor = open(file.path, flags)
            if existingDescriptor >= 0 {
                do {
                    try validateFileDescriptor(existingDescriptor)
                    return existingDescriptor
                } catch {
                    close(existingDescriptor)
                    throw error
                }
            }
            if errno == ENOENT {
                continue
            }
            throw APIUsageLedgerStoreError.invalidFile
        }
    }

    private func acquireExclusiveLock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                throw APIUsageLedgerStoreError.persistenceFailure
            }
        }
    }

    private func releaseExclusiveLock(_ descriptor: Int32) {
        while flock(descriptor, LOCK_UN) != 0 {
            if errno != EINTR {
                return
            }
        }
    }

    private func validateTargetSchemaBeforeWrite(at file: URL) throws {
        guard let data = try readSecureFile(at: file) else { return }

        let version: Int
        do {
            version = try decoder().decode(SchemaVersionEnvelope.self, from: data).schemaVersion
        } catch {
            throw APIUsageLedgerStoreError.invalidFile
        }
        if version > APIUsageLedgerSchema.currentVersion {
            throw APIUsageLedgerStoreError.unsupportedSchemaVersion(version)
        }
        guard version == APIUsageLedgerSchema.currentVersion else {
            throw APIUsageLedgerStoreError.invalidFile
        }
    }

    private func ensureUsageDirectory(
        createIfMissing: Bool,
        repairPermissions: Bool
    ) throws -> Bool {
        let directory = paths.apiUsageDirectory
        var status = stat()
        if lstat(directory.path, &status) != 0 {
            if errno == ENOENT, createIfMissing {
                do {
                    try fileManager.createDirectory(
                        at: directory.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
                guard mkdir(directory.path, S_IRWXU) == 0 || errno == EEXIST else {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
            } else if errno == ENOENT {
                return false
            } else {
                throw APIUsageLedgerStoreError.invalidFile
            }
        }

        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw APIUsageLedgerStoreError.invalidFile
        }
        defer { close(descriptor) }

        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid() else {
            throw APIUsageLedgerStoreError.invalidFile
        }
        if repairPermissions, Int(status.st_mode) & 0o777 != 0o700 {
            guard fchmod(descriptor, S_IRWXU) == 0,
                  fstat(descriptor, &status) == 0 else {
                throw APIUsageLedgerStoreError.persistenceFailure
            }
        }
        guard Int(status.st_mode) & 0o777 == 0o700 else {
            throw APIUsageLedgerStoreError.invalidFile
        }
        return true
    }

    private func readSecureFile(at file: URL) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw APIUsageLedgerStoreError.invalidFile
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw APIUsageLedgerStoreError.invalidFile
            }
        }
    }

    @discardableResult
    private func validateExistingFile(at file: URL) throws -> Bool {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw APIUsageLedgerStoreError.invalidFile
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor)
        return true
    }

    private func validateFileDescriptor(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              Int(status.st_mode) & 0o777 == 0o600 else {
            throw APIUsageLedgerStoreError.invalidFile
        }
    }

    private func writeSecurely(_ data: Data, to file: URL) throws {
        _ = try ensureUsageDirectory(createIfMissing: true, repairPermissions: true)
        try validateTargetSchemaBeforeWrite(at: file)

        let temporaryFile = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).tmp-\(UUID().uuidString)")
        var temporaryFileExists = false
        defer {
            if temporaryFileExists {
                _ = unlink(temporaryFile.path)
            }
        }

        let descriptor = open(
            temporaryFile.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
        temporaryFileExists = true
        defer { close(descriptor) }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
        try writeAll(data, to: descriptor)
        try syncFile(descriptor)
        guard rename(temporaryFile.path, file.path) == 0 else {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
        temporaryFileExists = false
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard bytes.count == 0 || bytes.baseAddress != nil else {
                throw APIUsageLedgerStoreError.persistenceFailure
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw APIUsageLedgerStoreError.persistenceFailure
                }
            }
        }
    }

    private func syncFile(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno != EINTR {
                throw APIUsageLedgerStoreError.persistenceFailure
            }
        }
    }
}

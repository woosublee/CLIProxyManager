import Darwin
import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class APIUsageLedgerStoreTests: XCTestCase {
    func testReadBeforePrepareThrowsNotInitialized() async throws {
        let store = APIUsageLedgerStore(paths: try makePaths(), writeDelayNanoseconds: 0)

        do {
            _ = try await store.readCurrentPeriods(at: iso("2026-07-25T12:00:00Z"))
            XCTFail("Expected not initialized")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .notInitialized)
        }
    }

    func testMergePersistsMonthlyAggregateAndRestoresAfterRestart() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "Asia/Seoul")
        let input = makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        let epoch = try XCTUnwrap(APIPriceCatalog.current.entry(provider: .claude, model: "claude-opus-5", serviceTier: "standard", variant: .standard, at: now)?.effectiveFrom)

        try await store.merge([.aggregate(input, priceEpochStart: epoch)])
        try await store.flush()

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let read = try await restored.readCurrentPeriods(at: now)
        XCTAssertEqual(read.currentMonth.buckets.first?.requestCount, 1)
        XCTAssertEqual(read.currentMonth.buckets.first?.totalTokens, input.tokenBreakdown.totalTokens)
        XCTAssertEqual(read.currentMonth.buckets.first?.key.priceEpochStart, epoch)
        XCTAssertEqual(fileMode(paths.apiUsageDirectory), 0o700)
        XCTAssertEqual(fileMode(paths.apiUsageMetadataFile), 0o600)
        XCTAssertEqual(fileMode(paths.apiUsageMonthlyLedgerFile(month: "2026-07")), 0o600)
    }

    func testAggregateCheckedAddsAllCountersAndObservedBounds() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let first = iso("2026-07-25T05:00:00Z")
        let last = iso("2026-07-25T07:00:00Z")
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")

        try await store.merge([
            .aggregate(makeAggregate(timestamp: last, profileID: "claude-api", provider: .claude, model: "claude-opus-5", failed: true), priceEpochStart: iso("2026-07-25T00:00:00Z")),
            .aggregate(makeAggregate(timestamp: first, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: iso("2026-07-25T00:00:00Z"))
        ])

        let read = try await store.readCurrentPeriods(at: last)
        let bucket = try XCTUnwrap(read.currentMonth.buckets.first)
        XCTAssertEqual(bucket.uncachedInputTokens, 14)
        XCTAssertEqual(bucket.cacheReadTokens, 4)
        XCTAssertEqual(bucket.cacheWriteTokens, 2)
        XCTAssertEqual(bucket.nonReasoningOutputTokens, 30)
        XCTAssertEqual(bucket.reasoningOutputTokens, 10)
        XCTAssertEqual(bucket.totalTokens, 60)
        XCTAssertEqual(bucket.requestCount, 2)
        XCTAssertEqual(bucket.failedRequestCount, 1)
        XCTAssertEqual(bucket.firstObservedAt, first)
        XCTAssertEqual(bucket.lastObservedAt, last)
    }

    func testAggregateBucketsKeepExactPriceEpochsSeparate() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let at = iso("2026-07-25T05:00:00Z")
        let input = makeAggregate(timestamp: at, profileID: "claude-api", provider: .claude, model: "claude-sonnet-5")
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")

        try await store.merge([
            .aggregate(input, priceEpochStart: iso("2026-07-25T00:00:00Z")),
            .aggregate(input, priceEpochStart: iso("2026-09-01T00:00:00Z"))
        ])

        let read = try await store.readCurrentPeriods(at: at)
        XCTAssertEqual(read.currentMonth.buckets.count, 2)
        XCTAssertEqual(Set(read.currentMonth.buckets.compactMap(\.key.priceEpochStart)), Set([
            iso("2026-07-25T00:00:00Z"),
            iso("2026-09-01T00:00:00Z")
        ]))
    }

    func testPrepareTrackingKeepsTheFirstReportingTimeZone() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "Asia/Seoul")
        try await store.flush()

        try await store.prepareTracking(at: iso("2026-07-25T16:00:00Z"), reportingTimeZoneID: "UTC")
        let read = try await store.readCurrentPeriods(at: iso("2026-07-25T16:00:00Z"))

        XCTAssertEqual(read.metadata.reportingTimeZoneID, "Asia/Seoul")
        XCTAssertEqual(read.bounds.localDate, "2026-07-26")
    }

    func testInvalidInitialReportingTimeZoneIsPersistedAsUTCFallback() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let at = iso("2026-07-25T01:00:00Z")

        try await store.prepareTracking(at: at, reportingTimeZoneID: "Invalid/Zone")
        try await store.flush()

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let read = try await restored.readCurrentPeriods(at: at)
        XCTAssertEqual(read.metadata.reportingTimeZoneID, "UTC")
        XCTAssertEqual(read.bounds.localDate, "2026-07-25")
    }

    func testTrackingStartedMidMonthCreatesBoundedPartialInterval() async throws {
        let store = APIUsageLedgerStore(paths: try makePaths(), writeDelayNanoseconds: 0)
        let at = iso("2026-07-25T01:00:00Z")

        try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")

        let read = try await store.readCurrentPeriods(at: at)
        let interval = try XCTUnwrap(read.metadata.partialIntervals.first)
        XCTAssertEqual(interval.reason, .trackingStartedMidPeriod)
        XCTAssertEqual(interval.start, iso("2026-07-01T00:00:00Z"))
        XCTAssertEqual(interval.end, at)
    }

    func testPersistedLedgerSchemaContainsNoRawQueueSecretFields() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "UTC")
        try await store.merge([.aggregate(makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: now)])
        try await store.flush()

        let persisted = try [paths.apiUsageMetadataFile, paths.apiUsageMonthlyLedgerFile(month: "2026-07")]
            .map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            .joined(separator: "\n")
        for forbiddenKey in ["\"api_key\"", "\"request_id\"", "\"auth_index\"", "\"fail\"", "\"response_headers\""] {
            XCTAssertFalse(persisted.contains(forbiddenKey), "Persisted forbidden queue field: \(forbiddenKey)")
        }
    }

    func testUsageDisablePauseDoesNotDeleteLedgerAndCreatesPartialInterval() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")
        try await store.markPaused(at: iso("2026-07-25T02:00:00Z"), proxyCouldServeRequests: true)
        try await store.markResumed(at: iso("2026-07-25T03:00:00Z"))
        try await store.flush()

        let read = try await store.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.apiUsageMetadataFile.path))
        XCTAssertEqual(read.metadata.partialIntervals.last?.reason, .trackingWasDisabled)
        XCTAssertEqual(read.metadata.partialIntervals.last?.end, iso("2026-07-25T03:00:00Z"))
    }

    func testPauseWithoutRequestServingRiskDoesNotOpenPartialInterval() async throws {
        let store = APIUsageLedgerStore(paths: try makePaths(), writeDelayNanoseconds: 0)
        let start = iso("2026-07-01T00:00:00Z")
        try await store.prepareTracking(at: start, reportingTimeZoneID: "UTC")

        try await store.markPaused(at: iso("2026-07-25T02:00:00Z"), proxyCouldServeRequests: false)
        try await store.markResumed(at: iso("2026-07-25T03:00:00Z"))

        let metadata = try await store.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z")).metadata
        XCTAssertNil(metadata.collectorPausedAt)
        XCTAssertFalse(metadata.partialIntervals.contains { $0.reason == .trackingWasDisabled })
    }

    func testTouchingAndOverlappingIntervalsUnionByReason() async throws {
        let store = APIUsageLedgerStore(paths: try makePaths(), writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")

        try await store.markCollectionGap(from: iso("2026-07-25T01:00:00Z"), to: iso("2026-07-25T02:00:00Z"))
        try await store.markCollectionGap(from: iso("2026-07-25T02:00:00Z"), to: iso("2026-07-25T03:00:00Z"))
        try await store.markCollectionGap(from: iso("2026-07-25T01:30:00Z"), to: iso("2026-07-25T04:00:00Z"))
        try await store.markPaused(at: iso("2026-07-25T04:00:00Z"), proxyCouldServeRequests: true)
        try await store.markResumed(at: iso("2026-07-25T05:00:00Z"))
        try await store.markPaused(at: iso("2026-07-25T05:00:00Z"), proxyCouldServeRequests: true)
        try await store.markResumed(at: iso("2026-07-25T06:00:00Z"))

        let intervals = try await store.readCurrentPeriods(at: iso("2026-07-25T07:00:00Z")).metadata.partialIntervals
        let gap = try XCTUnwrap(intervals.first { $0.reason == .collectionGap })
        let pause = try XCTUnwrap(intervals.first { $0.reason == .trackingWasDisabled })
        XCTAssertEqual(intervals.filter { $0.reason == .collectionGap }.count, 1)
        XCTAssertEqual(gap.start, iso("2026-07-25T01:00:00Z"))
        XCTAssertEqual(gap.end, iso("2026-07-25T04:00:00Z"))
        XCTAssertEqual(intervals.filter { $0.reason == .trackingWasDisabled }.count, 1)
        XCTAssertEqual(pause.start, iso("2026-07-25T04:00:00Z"))
        XCTAssertEqual(pause.end, iso("2026-07-25T06:00:00Z"))
    }

    func testMarkPersistenceFailurePersistsEveryImpactedLocalDayAfterRestart() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let day24 = iso("2026-07-24T04:00:00Z")
        let day25 = iso("2026-07-25T04:00:00Z")
        try await store.prepareTracking(
            at: iso("2026-07-01T00:00:00Z"),
            reportingTimeZoneID: "UTC"
        )

        try await store.markPersistenceFailure(for: [day24, day25])
        try await store.flush()

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let metadata = try await restored.readCurrentPeriods(at: day25).metadata
        let failures = metadata.partialIntervals.filter { $0.reason == .persistenceFailure }
        for timestamp in [day24, day25] {
            let bounds = APIUsagePeriodCalculator.bounds(at: timestamp, timeZoneID: "UTC")
            XCTAssertTrue(failures.contains {
                $0.start <= bounds.dayStart && ($0.end ?? .distantFuture) >= bounds.dayEnd
            })
        }
    }

    func testSuccessfulDrainPersistsLatestObservedRequestWithoutErasingIt() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let firstRequest = iso("2026-07-25T02:00:00Z")
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")

        try await store.markSuccessfulDrain(at: iso("2026-07-25T03:00:00Z"), lastObservedRequestAt: firstRequest)
        try await store.markSuccessfulDrain(at: iso("2026-07-25T04:00:00Z"), lastObservedRequestAt: nil)
        try await store.flush()

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let metadata = try await restored.readCurrentPeriods(at: iso("2026-07-25T05:00:00Z")).metadata
        XCTAssertEqual(metadata.lastSuccessfulDrainAt, iso("2026-07-25T04:00:00Z"))
        XCTAssertEqual(metadata.lastObservedRequestAt, firstRequest)
    }

    func testIssueInputsAggregateByDateProfileAndReason() async throws {
        let paths = try makePaths()
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let at = iso("2026-07-25T05:00:00Z")
        try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        let issue = APIUsageIssueInput(timestamp: at, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting)
        try await store.merge([.issue(issue), .issue(issue)])
        try await store.flush()
        let read = try await store.readCurrentPeriods(at: at)
        XCTAssertEqual(read.currentMonth.issues.first?.count, 2)
    }

    func testWritesAreDebouncedOnceAndExplicitFlushPersistsImmediately() async throws {
        let paths = try makePaths()
        let sleepRecorder = DebounceSleepRecorder()
        let store = APIUsageLedgerStore(
            paths: paths,
            writeDelayNanoseconds: 1_000_000_000,
            sleep: { delay in try await sleepRecorder.sleep(delay) }
        )
        let at = iso("2026-07-25T05:00:00Z")

        try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await waitUntil { await sleepRecorder.callCount == 1 }
        try await store.merge([.issue(.init(timestamp: at, profileID: nil, provider: nil, reason: .unknownProviderMapping))])
        try await store.markSuccessfulDrain(at: at, lastObservedRequestAt: nil)
        await Task.yield()

        let recordedDelays = await sleepRecorder.delays
        XCTAssertEqual(recordedDelays, [1_000_000_000])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.apiUsageMetadataFile.path))

        try await store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.apiUsageMetadataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.apiUsageMonthlyLedgerFile(month: "2026-07").path))
        let finalSleepCallCount = await sleepRecorder.callCount
        XCTAssertEqual(finalSleepCallCount, 1)
    }

    func testCorruptedLedgerIsMovedWithoutPrintingPayloadAndPeriodBecomesPartial() async throws {
        let paths = try makePaths()
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")
        try await initial.flush()
        let file = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try Data("not-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        _ = try await restored.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
        try await restored.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: paths.apiUsageDirectory.path)
        let backupName = try XCTUnwrap(names.first { $0.hasPrefix("2026-07.corrupt-") })
        XCTAssertEqual(fileMode(paths.apiUsageDirectory.appendingPathComponent(backupName)), 0o600)
        let metadata = try JSONDecoder.apiUsage.decode(APIUsageTrackingMetadata.self, from: Data(contentsOf: paths.apiUsageMetadataFile))
        XCTAssertTrue(metadata.partialIntervals.contains { $0.reason == .corruptedLedger })
    }

    func testCorruptBackupExclusiveMoveDoesNotReplaceRacingDestination() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await initial.flush()
        let source = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try Data("not-json".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        let collision = BackupCollisionHook()
        let restored = APIUsageLedgerStore(
            paths: paths,
            writeDelayNanoseconds: 0,
            beforeCorruptBackupMove: { try collision.install(at: $0) }
        )
        _ = try await restored.readCurrentPeriods(at: at)
        try await restored.flush()

        let occupied = try XCTUnwrap(collision.installedURL())
        XCTAssertEqual(try Data(contentsOf: occupied), BackupCollisionHook.sentinel)
        XCTAssertEqual(fileMode(occupied), 0o600)
        let backups = try FileManager.default.contentsOfDirectory(at: paths.apiUsageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("2026-07.corrupt-") }
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { fileMode($0) == 0o600 })
    }

    func testSymlinkLedgerPathIsRejectedWithoutTouchingTarget() async throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.apiUsageDirectory, withIntermediateDirectories: true)
        let target = paths.rootDirectory.appendingPathComponent("target.json")
        try Data("sentinel".utf8).write(to: target)
        let ledger = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try FileManager.default.createSymbolicLink(at: ledger, withDestinationURL: target)
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: iso("2026-07-25T01:00:00Z"), reportingTimeZoneID: "UTC")

        do {
            try await store.merge([.aggregate(makeAggregate(timestamp: iso("2026-07-25T02:00:00Z"), profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: iso("2026-07-25T00:00:00Z"))])
            try await store.flush()
            XCTFail("Expected invalid file")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .invalidFile)
            XCTAssertEqual(try Data(contentsOf: target), Data("sentinel".utf8))
        }
    }

    func testInsecureLedgerPermissionsAreRejected() async throws {
        let paths = try makePaths()
        let now = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: now, reportingTimeZoneID: "UTC")
        try await store.merge([.aggregate(makeAggregate(timestamp: now, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: now)])
        try await store.flush()
        let ledger = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledger.path)

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        do {
            _ = try await restored.readCurrentPeriods(at: now)
            XCTFail("Expected invalid file")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .invalidFile)
        }
    }

    func testInsecureMetadataPermissionsAreRejected() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T12:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.apiUsageMetadataFile.path)

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        do {
            _ = try await restored.readCurrentPeriods(at: at)
            XCTFail("Expected invalid file")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .invalidFile)
        }
    }

    func testFutureMetadataSchemaIsRejectedWithoutDowngradeOrOverwrite() async throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.apiUsageDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.apiUsageDirectory.path)
        let data = Data(#"{"schemaVersion":99,"reportingTimeZoneID":"UTC","trackingStartedAt":"2026-07-25T00:00:00Z","partialIntervals":[]}"#.utf8)
        try data.write(to: paths.apiUsageMetadataFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiUsageMetadataFile.path)
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        do {
            _ = try await store.readCurrentPeriods(at: iso("2026-07-25T04:00:00Z"))
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(try Data(contentsOf: paths.apiUsageMetadataFile), data)
        }
    }

    func testFutureMonthlySchemaIsRejectedWithoutBackupOrOverwrite() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await initial.flush()
        let ledger = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        let data = Data(#"{"schemaVersion":99,"month":"2026-07","reportingTimeZoneID":"UTC","buckets":[],"issues":[]}"#.utf8)
        try data.write(to: ledger)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        do {
            _ = try await restored.readCurrentPeriods(at: at)
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(try Data(contentsOf: ledger), data)
            let names = try FileManager.default.contentsOfDirectory(atPath: paths.apiUsageDirectory.path)
            XCTAssertFalse(names.contains { $0.hasPrefix("2026-07.corrupt-") })
        }
    }

    func testFlushDoesNotOverwriteFutureSchemaInstalledAfterCacheLoad() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: .max)
        try await store.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")
        try await store.flush()
        XCTAssertEqual(fileMode(paths.apiUsageDirectory.appendingPathComponent(".store.lock")), 0o600)
        try await store.merge([.aggregate(makeAggregate(timestamp: at, profileID: "claude-api", provider: .claude, model: "claude-opus-5"), priceEpochStart: at)])
        try await store.flush()
        try await store.merge([.issue(.init(timestamp: at, profileID: "claude-api", provider: .claude, reason: .incompleteTokenAccounting))])

        let file = paths.apiUsageMonthlyLedgerFile(month: "2026-07")
        let future = Data(#"{"schemaVersion":99,"month":"2026-07","reportingTimeZoneID":"UTC","buckets":[],"issues":[]}"#.utf8)
        try future.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        do {
            try await store.flush()
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .unsupportedSchemaVersion(99))
            XCTAssertEqual(try Data(contentsOf: file), future)
        }
    }

    func testOverflowMarksEveryDiscardedMutationDayPartial() async throws {
        let paths = try makePaths()
        let day24 = iso("2026-07-24T04:00:00Z")
        let day25 = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")
        try await initial.flush()

        let overflowInput = makeAggregate(timestamp: day25, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        let key = APIUsageLedgerBucketKey(localDate: "2026-07-25", profileID: overflowInput.profileID, provider: overflowInput.provider, model: overflowInput.model, effectiveServiceTier: overflowInput.effectiveServiceTier, pricingVariant: overflowInput.pricingVariant, priceEpochStart: day25)
        let maxBucket = APIUsageLedgerBucket(key: key, uncachedInputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, nonReasoningOutputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0, requestCount: .max, failedRequestCount: 0, firstObservedAt: day25, lastObservedAt: day25)
        let seeded = APIUsageMonthlyLedger(schemaVersion: 1, month: "2026-07", reportingTimeZoneID: "UTC", buckets: [maxBucket])
        try JSONEncoder.apiUsage.encode(seeded).write(to: paths.apiUsageMonthlyLedgerFile(month: "2026-07"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiUsageMonthlyLedgerFile(month: "2026-07").path)

        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        let normalInput = makeAggregate(timestamp: day24, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        do {
            try await restored.merge([
                .aggregate(normalInput, priceEpochStart: day24),
                .aggregate(overflowInput, priceEpochStart: day25)
            ])
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .persistenceFailure)
        }
        try await restored.flush()

        let read = try await restored.readCurrentPeriods(at: day25)
        XCTAssertFalse(read.currentMonth.buckets.contains { $0.key.localDate == "2026-07-24" })
        let failures = read.metadata.partialIntervals.filter { $0.reason == .persistenceFailure }
        for timestamp in [day24, day25] {
            let bounds = APIUsagePeriodCalculator.bounds(at: timestamp, timeZoneID: "UTC")
            XCTAssertTrue(failures.contains {
                $0.start < bounds.dayEnd && ($0.end ?? .distantFuture) > bounds.dayStart
            })
        }
    }

    func testIntegerOverflowThrowsPersistenceFailureAndMarksPeriodPartial() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let initial = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await initial.prepareTracking(at: iso("2026-07-01T00:00:00Z"), reportingTimeZoneID: "UTC")
        try await initial.flush()
        let input = makeAggregate(timestamp: at, profileID: "claude-api", provider: .claude, model: "claude-opus-5")
        let key = APIUsageLedgerBucketKey(localDate: "2026-07-25", profileID: input.profileID, provider: input.provider, model: input.model, effectiveServiceTier: input.effectiveServiceTier, pricingVariant: input.pricingVariant, priceEpochStart: at)
        let bucket = APIUsageLedgerBucket(
            key: key,
            uncachedInputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            nonReasoningOutputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 0,
            requestCount: .max,
            failedRequestCount: 0,
            firstObservedAt: at,
            lastObservedAt: at
        )
        let ledger = APIUsageMonthlyLedger(schemaVersion: 1, month: "2026-07", reportingTimeZoneID: "UTC", buckets: [bucket])
        try JSONEncoder.apiUsage.encode(ledger).write(to: paths.apiUsageMonthlyLedgerFile(month: "2026-07"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.apiUsageMonthlyLedgerFile(month: "2026-07").path)
        let restored = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)

        do {
            try await restored.merge([.aggregate(input, priceEpochStart: at)])
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .persistenceFailure)
        }
        try await restored.flush()

        let read = try await restored.readCurrentPeriods(at: at)
        XCTAssertEqual(read.currentMonth.buckets.first?.requestCount, .max)
        XCTAssertTrue(read.metadata.partialIntervals.contains { $0.reason == .persistenceFailure })
    }

    func testAtomicWritesLeaveNoTemporaryFiles() async throws {
        let paths = try makePaths()
        let at = iso("2026-07-25T04:00:00Z")
        let store = APIUsageLedgerStore(paths: paths, writeDelayNanoseconds: 0)
        try await store.prepareTracking(at: at, reportingTimeZoneID: "UTC")
        try await store.merge([.issue(.init(timestamp: at, profileID: nil, provider: nil, reason: .unknownProviderMapping))])
        try await store.flush()
        try await store.markSuccessfulDrain(at: at, lastObservedRequestAt: nil)
        try await store.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: paths.apiUsageDirectory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".") && $0.contains(".tmp-") })
    }

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("APIUsageLedgerStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ManagedPaths(rootDirectory: root)
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func fileMode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            .map { $0 & 0o777 }
    }

    private func makeAggregate(
        timestamp: Date,
        profileID: String,
        provider: APIUsageProvider,
        model: String,
        failed: Bool = false
    ) -> APIUsageAggregateInput {
        let input = APIUsageTokenInputBreakdown(totalTokens: 10, uncachedTokens: 7, cacheReadTokens: 2, cacheWriteTokens: 1)
        let output = APIUsageTokenOutputBreakdown(totalTokens: 20, nonReasoningTokens: 15, reasoningTokens: 5)
        let breakdown = APIUsageTokenBreakdown(schemaVersion: 2, quality: .complete, totalTokens: 30, input: input, output: output, unclassifiedTokens: 0)
        return APIUsageAggregateInput(timestamp: timestamp, profileID: profileID, provider: provider, model: model, effectiveServiceTier: "standard", pricingVariant: .standard, tokenBreakdown: breakdown, failed: failed)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            guard DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class BackupCollisionHook: @unchecked Sendable {
    static let sentinel = Data("existing-backup".utf8)

    private let lock = NSLock()
    private var installed: URL?

    func install(at url: URL) throws {
        try lock.withLock {
            guard installed == nil else { return }
            try Self.sentinel.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            installed = url
        }
    }

    func installedURL() -> URL? {
        lock.withLock { installed }
    }
}

private actor DebounceSleepRecorder {
    private(set) var delays: [UInt64] = []
    var callCount: Int { delays.count }

    func sleep(_ delay: UInt64) async throws {
        delays.append(delay)
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

private extension JSONEncoder {
    static var apiUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var apiUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

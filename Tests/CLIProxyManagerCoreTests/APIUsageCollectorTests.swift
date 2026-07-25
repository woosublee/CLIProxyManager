import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class APIUsageCollectorTests: XCTestCase {
    func testReloadDrainsFullBatchesUntilShortBatchAndMergesEachRecordOnce() async {
        let queue = RecordingQueueClient(results: [
            .success(Array(repeating: makeQueueRecord(), count: 200)),
            .success([makeQueueRecord()])
        ])
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            now: { iso("2026-07-25T12:00:00Z") }
        )

        _ = await collector.reload(configuration: enabledConfiguration())

        let requestedCounts = await queue.requestedCounts()
        let aggregateCount = await ledger.aggregateMutationCount()
        let flushCount = await ledger.flushCount()
        let priceEpochs = Set(await ledger.aggregatePriceEpochs().compactMap { $0 })
        XCTAssertEqual(requestedCounts, [200, 200])
        XCTAssertEqual(aggregateCount, 201)
        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(priceEpochs, [iso("2026-07-25T00:00:00Z")])
    }

    func testReloadContinuesImmediatelyAfterTwoThousandRecordPass() async {
        let fullBatches = Array(
            repeating: QueueResult.success(Array(repeating: makeQueueRecord(), count: 200)),
            count: 10
        )
        let queue = RecordingQueueClient(results: fullBatches + [.success([makeQueueRecord()])])
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            now: { iso("2026-07-25T12:00:00Z") },
            sleep: { try await sleep.sleep($0) }
        )

        _ = await collector.reload(configuration: enabledConfiguration())

        let requestedCounts = await queue.requestedCounts()
        let aggregateCount = await ledger.aggregateMutationCount()
        let delays = await sleep.recordedDelays()
        XCTAssertEqual(requestedCounts, Array(repeating: 200, count: 11))
        XCTAssertEqual(aggregateCount, 2_001)
        XCTAssertEqual(delays, [])
    }

    func testConcurrentReloadsShareOneDrainWithoutDoubleMerge() async throws {
        let queue = SuspendedQueueClient(record: makeQueueRecord())
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)
        let configuration = enabledConfiguration()

        async let first = collector.reload(configuration: configuration)
        async let second = collector.reload(configuration: configuration)
        try await waitUntil { await queue.isSuspended() }
        await queue.resume()
        _ = await (first, second)

        let queueCalls = await queue.callCount()
        let aggregateCount = await ledger.aggregateMutationCount()
        let flushCount = await ledger.flushCount()
        XCTAssertEqual(queueCalls, 1)
        XCTAssertEqual(aggregateCount, 1)
        XCTAssertEqual(flushCount, 1)
    }

    func testCancelledDrainStillMergesAlreadyPoppedBatch() async {
        let queue = CancellingQueueClient(record: makeQueueRecord())
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)

        _ = await collector.reload(configuration: enabledConfiguration())

        let aggregateCount = await ledger.aggregateMutationCount()
        XCTAssertEqual(aggregateCount, 1)
    }

    func testCollectorMarksGapBeforePopWhenLastDrainExceedsRetention() async {
        let ledger = RecordingLedgerStore(
            readModel: emptyReadModel(lastSuccessfulDrainAt: iso("2026-07-25T10:00:00Z"))
        )
        let queue = RecordingQueueClient(results: [.success([])])
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            now: { iso("2026-07-25T12:00:01Z") }
        )

        _ = await collector.reload(configuration: enabledConfiguration())

        let gaps = await ledger.collectionGaps()
        let events = await ledger.eventsPrefix(2)
        XCTAssertEqual(gaps, [
            .init(
                start: iso("2026-07-25T10:00:00Z"),
                end: iso("2026-07-25T12:00:01Z")
            )
        ])
        XCTAssertEqual(events, ["read", "gap"])
    }

    func testQueueFailuresKeepStoredSnapshotAndMapTypedIssuesInAllCasesOrder() async {
        let cases: [(APIUsageQueueClientError, APICostIssue)] = [
            (.managementKeyNotConfigured, .managementKeyNotConfigured),
            (.managementKeyRejected, .managementKeyRejected),
            (.managementAPINotSupported, .managementAPINotSupported),
            (.schemaMismatch, .managementAPINotSupported),
            (.invalidCount, .managementAPINotSupported),
            (.invalidPort, .proxyUnavailable),
            (.proxyUnavailable, .proxyUnavailable),
            (.transientFailure, .transientCollectionFailure)
        ]

        for (queueError, expectedIssue) in cases {
            let ledger = RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage())
            let queue = RecordingQueueClient(results: [.failure(queueError)])
            let report = await APIUsageCollector(queueClient: queue, ledgerStore: ledger)
                .reload(configuration: enabledConfiguration())

            guard case let .partial(snapshot, issues) = report.statesByProfileID["claude-api"] else {
                XCTFail("Expected partial for \(queueError)")
                continue
            }
            XCTAssertGreaterThan(snapshot.day.estimatedUSD, 0)
            XCTAssertTrue(snapshot.day.issues.contains(expectedIssue))
            XCTAssertTrue(snapshot.month.issues.contains(expectedIssue))
            XCTAssertTrue(issues.contains(expectedIssue))
            XCTAssertEqual(issues, APICostIssue.allCases.filter(issues.contains))
        }
    }

    func testQueueFailureWithoutStoredSnapshotIsUnavailable() async {
        let ledger = RecordingLedgerStore(readError: .notInitialized)
        let queue = RecordingQueueClient(results: [.failure(.managementKeyRejected)])

        let report = await APIUsageCollector(queueClient: queue, ledgerStore: ledger)
            .reload(configuration: enabledConfiguration())

        XCTAssertEqual(report.statesByProfileID["claude-api"], .unavailable(.managementKeyRejected))
    }

    func testPoppedBatchMergeFailureKeepsStoredSnapshotAndMarksPersistenceFailure() async {
        let ledger = RecordingLedgerStore(
            readModel: readModelWithPricedClaudeUsage(),
            mergeError: .persistenceFailure
        )
        let queue = RecordingQueueClient(results: [.success([makeQueueRecord()])])

        let report = await APIUsageCollector(queueClient: queue, ledgerStore: ledger)
            .reload(configuration: enabledConfiguration())

        guard case let .partial(snapshot, issues) = report.statesByProfileID["claude-api"] else {
            return XCTFail("Expected partial")
        }
        XCTAssertGreaterThan(snapshot.day.estimatedUSD, 0)
        XCTAssertTrue(snapshot.day.issues.contains(.persistenceFailure))
        XCTAssertTrue(snapshot.month.issues.contains(.persistenceFailure))
        XCTAssertTrue(issues.contains(.persistenceFailure))
        let successfulDrainCount = await ledger.successfulDrainCount()
        XCTAssertEqual(successfulDrainCount, 0)
    }

    func testPoppedBatchMergeFailurePersistsLossSignalAcrossLaterSuccessfulDrain() async {
        let timestamp = iso("2026-07-25T12:00:00Z")
        let ledger = RecordingLedgerStore(
            readModel: readModelWithPricedClaudeUsage(),
            mergeError: .persistenceFailure
        )
        let queue = RecordingQueueClient(results: [
            .success([makeQueueRecord()]),
            .success([])
        ])
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            now: { timestamp }
        )

        let failed = await collector.reload(configuration: enabledConfiguration())
        let recovered = await collector.reload(configuration: enabledConfiguration())

        XCTAssertTrue(failed.statesByProfileID["claude-api"]?.issues.contains(.persistenceFailure) == true)
        XCTAssertTrue(recovered.statesByProfileID["claude-api"]?.issues.contains(.persistenceFailure) == true)
        let markedTimestamps = await ledger.persistenceFailureTimestamps()
        XCTAssertEqual(markedTimestamps, [timestamp])
    }

    func testRestoreNeverCallsNetworkAndReturnsDisabledLoadingStoredAndUnsupportedStates() async {
        let queue = RecordingQueueClient(results: [.success([makeQueueRecord()])])

        let disabled = await APIUsageCollector(queueClient: queue, ledgerStore: RecordingLedgerStore())
            .restore(configuration: .init(
                usageEnabled: false,
                proxyReady: true,
                port: 18_317,
                enabledProviders: [.claude],
                reportingTimeZoneID: "UTC"
            ))
        XCTAssertEqual(disabled.statesByProfileID["claude-api"], .disabled)

        let loading = await APIUsageCollector(
            queueClient: queue,
            ledgerStore: RecordingLedgerStore(readError: .notInitialized)
        ).restore(configuration: enabledConfiguration())
        XCTAssertEqual(loading.statesByProfileID["claude-api"], .loading)

        let stored = await APIUsageCollector(
            queueClient: queue,
            ledgerStore: RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage())
        ).restore(configuration: enabledConfiguration())
        XCTAssertNotNil(stored.statesByProfileID["claude-api"]?.snapshot)

        let unsupported = await APIUsageCollector(
            queueClient: queue,
            ledgerStore: RecordingLedgerStore(readError: .unsupportedSchemaVersion(99))
        ).restore(configuration: enabledConfiguration())
        XCTAssertEqual(unsupported.statesByProfileID["claude-api"], .unavailable(.unsupportedLedgerVersion))

        let queueCalls = await queue.callCount()
        XCTAssertEqual(queueCalls, 0)
    }

    func testStartPreparesFlushesResumesDrainsThenStartsNormalPoll() async throws {
        let queue = RecordingQueueClient(results: [.success([])])
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            now: { iso("2026-07-25T12:00:00Z") },
            sleep: { try await sleep.sleep($0) }
        )

        await collector.start(configuration: enabledConfiguration())
        try await waitUntil { await sleep.recordedDelays().count == 1 }

        let events = await ledger.allEvents()
        let flushCount = await ledger.flushCount()
        let delays = await sleep.recordedDelays()
        XCTAssertEqual(Array(events.prefix(5)), ["prepare", "flush", "resume", "read", "merge"])
        XCTAssertEqual(flushCount, 1)
        XCTAssertEqual(delays, [30_000_000_000])

        await collector.stop(reason: .applicationTermination, at: iso("2026-07-25T12:01:00Z"))
    }

    func testPollingRetriesTransientAndProxyFailuresWithBackoffThenStopsOnTerminalError() async throws {
        let queue = RecordingQueueClient(results: [
            .failure(.transientFailure),
            .failure(.proxyUnavailable),
            .failure(.managementKeyRejected)
        ])
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage()),
            sleep: { try await sleep.sleep($0) }
        )

        await collector.start(configuration: enabledConfiguration())
        try await waitUntil { await sleep.recordedDelays().count == 1 }
        await sleep.resumeNext()
        try await waitUntil { await sleep.recordedDelays().count == 2 }
        await sleep.resumeNext()
        try await waitUntil { await queue.callCount() == 3 }
        for _ in 0..<20 { await Task.yield() }

        let delays = await sleep.recordedDelays()
        let queueCalls = await queue.callCount()
        XCTAssertEqual(delays, [60_000_000_000, 120_000_000_000])
        XCTAssertEqual(queueCalls, 3)

        await collector.stop(reason: .applicationTermination, at: Date())
    }

    func testStopTrackingDisabledCancelsPollingMarksPauseAndFlushesWithoutDeletion() async throws {
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: [.success([])]),
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )
        await collector.start(configuration: enabledConfiguration())
        try await waitUntil { await sleep.recordedDelays().count == 1 }

        await collector.stop(
            reason: .trackingDisabled(proxyCouldServeRequests: true),
            at: iso("2026-07-25T13:00:00Z")
        )

        let pauseArguments = await ledger.pauseArguments()
        let flushCount = await ledger.flushCount()
        let deleteCount = await ledger.deleteCount()
        let pendingSleeps = await sleep.pendingCount()
        XCTAssertEqual(pauseArguments, [true])
        XCTAssertEqual(flushCount, 2)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(pendingSleeps, 0)
    }

    func testStopCancelsInFlightPollingPopBeforeFlushing() async throws {
        let queue = CancellablePollingQueueClient()
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )

        await collector.start(configuration: enabledConfiguration())
        try await waitUntil { await sleep.recordedDelays().count == 1 }
        await sleep.resumeNext()
        try await waitUntil { await queue.isPollingPopSuspended() }

        let stopTask = Task {
            await collector.stop(reason: .applicationTermination, at: Date())
        }
        let stoppedWithoutManualResume = await eventually {
            await ledger.flushCount() == 2
        }
        if !stoppedWithoutManualResume {
            await queue.forceCancellation()
        }
        await stopTask.value

        XCTAssertTrue(stoppedWithoutManualResume)
        let queueCalls = await queue.callCount()
        XCTAssertEqual(queueCalls, 2)
    }

    func testStopWaitsForLifecycleDrainThenFlushesAndPreventsPollingRestart() async throws {
        let queue = FirstCallSuspendingQueueClient()
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let stopped = CompletionFlag()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )

        async let started: Void = collector.start(configuration: enabledConfiguration())
        try await waitUntil { await queue.isFirstCallSuspended() }
        let stopTask = Task {
            await collector.stop(reason: .applicationTermination, at: Date())
            await stopped.markCompleted()
        }

        let returnedBeforePopCompleted = await eventually {
            await stopped.isCompleted()
        }
        XCTAssertFalse(returnedBeforePopCompleted)

        await queue.resumeFirstCall()
        await started
        await stopTask.value
        for _ in 0..<20 { await Task.yield() }

        let events = await ledger.allEvents()
        let successfulDrainIndex = try XCTUnwrap(events.lastIndex(of: "successfulDrain"))
        let finalFlushIndex = try XCTUnwrap(events.lastIndex(of: "flush"))
        let delays = await sleep.recordedDelays()
        XCTAssertGreaterThan(finalFlushIndex, successfulDrainIndex)
        XCTAssertEqual(delays, [])
    }

    func testApplicationTerminationFlushesWithoutCreatingPartialInterval() async {
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: []),
            ledgerStore: ledger
        )

        await collector.stop(reason: .applicationTermination, at: iso("2026-07-25T13:00:00Z"))

        let pauseArguments = await ledger.pauseArguments()
        let flushCount = await ledger.flushCount()
        XCTAssertEqual(pauseArguments, [])
        XCTAssertEqual(flushCount, 1)
    }

    func testDisabledUsageBecomingProxyReadyStartsPartialPauseAtReadyTime() async {
        let ledger = RecordingLedgerStore()
        let now = iso("2026-07-25T12:00:00Z")
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: []),
            ledgerStore: ledger,
            now: { now }
        )

        await collector.update(configuration: .init(
            usageEnabled: false,
            proxyReady: true,
            port: 18_317,
            enabledProviders: [.claude],
            reportingTimeZoneID: "UTC"
        ))

        let pauseArguments = await ledger.pauseArguments()
        let pauseDates = await ledger.pauseDates()
        let flushCount = await ledger.flushCount()
        XCTAssertEqual(pauseArguments, [true])
        XCTAssertEqual(pauseDates, [now])
        XCTAssertEqual(flushCount, 1)
    }

    func testEnabledUsageWithoutProviderStopsPollingWithoutOpeningPartialInterval() async {
        let queue = RecordingQueueClient(results: [.success([makeQueueRecord()])])
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )
        let configuration = APIUsageCollectorConfiguration(
            usageEnabled: true,
            proxyReady: true,
            port: 18_317,
            enabledProviders: [],
            reportingTimeZoneID: "UTC"
        )

        await collector.start(configuration: configuration)
        for _ in 0..<20 { await Task.yield() }

        let queueCalls = await queue.callCount()
        let pauseArguments = await ledger.pauseArguments()
        let delays = await sleep.recordedDelays()
        XCTAssertEqual(queueCalls, 0)
        XCTAssertEqual(pauseArguments, [])
        XCTAssertEqual(delays, [])
    }

    func testNotReadySkipsNetworkAndReadyUpdateDrainsImmediately() async {
        let queue = RecordingQueueClient(results: [.success([])])
        let ledger = RecordingLedgerStore(readModel: readModelWithPricedClaudeUsage())
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)
        let notReady = APIUsageCollectorConfiguration(
            usageEnabled: true,
            proxyReady: false,
            port: 18_317,
            enabledProviders: [.claude],
            reportingTimeZoneID: "UTC"
        )

        let restored = await collector.restore(configuration: notReady)
        guard case let .partial(snapshot, issues) = restored.statesByProfileID["claude-api"] else {
            return XCTFail("Expected stored partial state")
        }
        XCTAssertTrue(snapshot.day.issues.contains(.proxyUnavailable))
        XCTAssertTrue(snapshot.month.issues.contains(.proxyUnavailable))
        XCTAssertTrue(issues.contains(.proxyUnavailable))
        let callsBeforeReady = await queue.callCount()
        XCTAssertEqual(callsBeforeReady, 0)

        await collector.update(configuration: notReady)
        await collector.update(configuration: enabledConfiguration())

        let callsAfterReady = await queue.callCount()
        XCTAssertEqual(callsAfterReady, 1)
        await collector.stop(reason: .applicationTermination, at: Date())
    }

    func testConfigurationChangeWaitsForActiveDrainThenUsesNewPort() async throws {
        let queue = FirstCallSuspendingQueueClient()
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)
        let firstConfiguration = enabledConfiguration()
        let secondConfiguration = APIUsageCollectorConfiguration(
            usageEnabled: true,
            proxyReady: true,
            port: 19_001,
            enabledProviders: [.claude, .openAI],
            reportingTimeZoneID: "UTC"
        )

        async let first = collector.reload(configuration: firstConfiguration)
        try await waitUntil { await queue.isFirstCallSuspended() }
        async let updated: Void = collector.update(configuration: secondConfiguration)
        for _ in 0..<20 { await Task.yield() }
        await queue.resumeFirstCall()
        _ = await first
        await updated

        let ports = await queue.requestedPorts()
        XCTAssertEqual(ports, [18_317, 19_001])
        await collector.stop(reason: .applicationTermination, at: Date())
    }

    func testDisabledUpdateDuringActiveStartWaitsThenKeepsDisabledLatestReport() async throws {
        let queue = FirstCallSuspendingQueueClient()
        let ledger = RecordingLedgerStore()
        let updated = CompletionFlag()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger
        )
        let disabledConfiguration = APIUsageCollectorConfiguration(
            usageEnabled: false,
            proxyReady: true,
            port: 18_317,
            enabledProviders: [.claude],
            reportingTimeZoneID: "UTC"
        )

        async let started: Void = collector.start(configuration: enabledConfiguration())
        try await waitUntil { await queue.isFirstCallSuspended() }
        let updateTask = Task {
            await collector.update(configuration: disabledConfiguration)
            await updated.markCompleted()
        }
        let returnedBeforePopCompleted = await eventually {
            await updated.isCompleted()
        }
        XCTAssertFalse(returnedBeforePopCompleted)

        await queue.resumeFirstCall()
        await started
        await updateTask.value

        let stream = await collector.reports()
        var iterator = stream.makeAsyncIterator()
        let latest = await iterator.next()
        XCTAssertEqual(latest?.statesByProfileID["claude-api"], .disabled)
        let events = await ledger.allEvents()
        let successfulDrainIndex = try XCTUnwrap(events.lastIndex(of: "successfulDrain"))
        let finalFlushIndex = try XCTUnwrap(events.lastIndex(of: "flush"))
        XCTAssertGreaterThan(finalFlushIndex, successfulDrainIndex)
    }

    func testStopInvalidatesConfigurationChangeWaitingBehindLifecycleDrain() async throws {
        let queue = FirstCallSuspendingQueueClient()
        let ledger = RecordingLedgerStore()
        let collector = APIUsageCollector(queueClient: queue, ledgerStore: ledger)
        let secondConfiguration = APIUsageCollectorConfiguration(
            usageEnabled: true,
            proxyReady: true,
            port: 19_001,
            enabledProviders: [.claude, .openAI],
            reportingTimeZoneID: "UTC"
        )

        async let started: Void = collector.start(configuration: enabledConfiguration())
        try await waitUntil { await queue.isFirstCallSuspended() }
        let updateTask = Task {
            await collector.update(configuration: secondConfiguration)
        }
        for _ in 0..<20 { await Task.yield() }
        let stopTask = Task {
            await collector.stop(reason: .applicationTermination, at: Date())
        }
        for _ in 0..<20 { await Task.yield() }

        await queue.resumeFirstCall()
        await started
        await updateTask.value
        await stopTask.value

        let ports = await queue.requestedPorts()
        XCTAssertEqual(ports, [18_317])
        let events = await ledger.allEvents()
        let successfulDrainIndex = try XCTUnwrap(events.lastIndex(of: "successfulDrain"))
        let finalFlushIndex = try XCTUnwrap(events.lastIndex(of: "flush"))
        XCTAssertGreaterThan(finalFlushIndex, successfulDrainIndex)
    }

    func testConfigurationChangeDuringStartCreatesOnlyNewPollingDeadline() async throws {
        let queue = FirstCallSuspendingQueueClient()
        let ledger = RecordingLedgerStore()
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: queue,
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )
        let firstConfiguration = enabledConfiguration()
        let secondConfiguration = APIUsageCollectorConfiguration(
            usageEnabled: true,
            proxyReady: true,
            port: 19_001,
            enabledProviders: [.claude, .openAI],
            reportingTimeZoneID: "UTC"
        )

        async let started: Void = collector.start(configuration: firstConfiguration)
        try await waitUntil { await queue.isFirstCallSuspended() }
        async let updated: Void = collector.update(configuration: secondConfiguration)
        for _ in 0..<20 { await Task.yield() }
        await queue.resumeFirstCall()
        await started
        await updated
        try await waitUntil { await sleep.recordedDelays().count >= 1 }

        let delays = await sleep.recordedDelays()
        XCTAssertEqual(delays, [30_000_000_000])
        await collector.stop(reason: .applicationTermination, at: Date())
    }

    func testStartFlushFailureKeepsStoredSnapshotAndMarksPersistenceFailure() async {
        let ledger = RecordingLedgerStore(
            readModel: readModelWithPricedClaudeUsage(),
            flushError: .persistenceFailure
        )
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: []),
            ledgerStore: ledger
        )

        await collector.start(configuration: enabledConfiguration())
        let stream = await collector.reports()
        var iterator = stream.makeAsyncIterator()
        let report = await iterator.next()

        guard case let .partial(snapshot, issues) = report?.statesByProfileID["claude-api"] else {
            return XCTFail("Expected stored partial state")
        }
        XCTAssertGreaterThan(snapshot.day.estimatedUSD, 0)
        XCTAssertTrue(snapshot.day.issues.contains(.persistenceFailure))
        XCTAssertTrue(snapshot.month.issues.contains(.persistenceFailure))
        XCTAssertTrue(issues.contains(.persistenceFailure))
    }

    func testPublicReloadJoiningStartupDrainStillFlushesImmediately() async throws {
        let ledger = RecordingLedgerStore(suspendReadCall: 2)
        let sleep = StepSleepRecorder()
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: [.success([])]),
            ledgerStore: ledger,
            sleep: { try await sleep.sleep($0) }
        )
        let configuration = enabledConfiguration()

        async let started: Void = collector.start(configuration: configuration)
        try await waitUntil { await ledger.isReadSuspended() }
        async let reloaded = collector.reload(configuration: configuration)
        for _ in 0..<20 { await Task.yield() }
        await ledger.resumeRead()
        await started
        _ = await reloaded

        let flushCount = await ledger.flushCount()
        XCTAssertEqual(flushCount, 2)
        await collector.stop(reason: .applicationTermination, at: Date())
    }

    func testReportsFinishReplacedSubscriberAndYieldLatestReportToNewSubscriber() async {
        let collector = APIUsageCollector(
            queueClient: RecordingQueueClient(results: []),
            ledgerStore: RecordingLedgerStore()
        )
        let firstStream = await collector.reports()
        let firstNext = Task { () -> APIUsageCollectionReport? in
            var iterator = firstStream.makeAsyncIterator()
            return await iterator.next()
        }

        let secondStream = await collector.reports()
        let firstValue = await firstNext.value
        XCTAssertNil(firstValue)

        let expected = await collector.restore(configuration: .init(
            usageEnabled: false,
            proxyReady: false,
            port: 18_317,
            enabledProviders: [.claude],
            reportingTimeZoneID: "UTC"
        ))
        var secondIterator = secondStream.makeAsyncIterator()
        let streamed = await secondIterator.next()
        XCTAssertEqual(streamed, expected)
    }
}

private typealias QueueResult = Result<[APIUsageQueueRecord], APIUsageQueueClientError>

private actor RecordingQueueClient: APIUsageQueueFetching {
    private var results: [QueueResult]
    private var counts: [Int] = []

    init(results: [QueueResult]) {
        self.results = results
    }

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        counts.append(count)
        guard !results.isEmpty else { return [] }
        return try results.removeFirst().get()
    }

    func requestedCounts() -> [Int] { counts }
    func callCount() -> Int { counts.count }
}

private actor SuspendedQueueClient: APIUsageQueueFetching {
    private let record: APIUsageQueueRecord
    private var continuation: CheckedContinuation<[APIUsageQueueRecord], Error>?
    private var calls = 0

    init(record: APIUsageQueueRecord) {
        self.record = record
    }

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func isSuspended() -> Bool { continuation != nil }
    func callCount() -> Int { calls }

    func resume() {
        continuation?.resume(returning: [record])
        continuation = nil
    }
}

private actor FirstCallSuspendingQueueClient: APIUsageQueueFetching {
    private var ports: [Int] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        ports.append(port)
        if ports.count == 1 {
            await withCheckedContinuation { firstContinuation = $0 }
        }
        return []
    }

    func isFirstCallSuspended() -> Bool { firstContinuation != nil }
    func requestedPorts() -> [Int] { ports }

    func resumeFirstCall() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor CancellablePollingQueueClient: APIUsageQueueFetching {
    private var calls = 0
    private var pollingContinuation: CheckedContinuation<[APIUsageQueueRecord], Error>?

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        calls += 1
        guard calls > 1 else { return [] }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pollingContinuation = $0 }
        } onCancel: {
            Task { await self.forceCancellation() }
        }
    }

    func isPollingPopSuspended() -> Bool { pollingContinuation != nil }
    func callCount() -> Int { calls }

    func forceCancellation() {
        pollingContinuation?.resume(throwing: CancellationError())
        pollingContinuation = nil
    }
}

private actor CancellingQueueClient: APIUsageQueueFetching {
    private let record: APIUsageQueueRecord

    init(record: APIUsageQueueRecord) {
        self.record = record
    }

    func popUsage(port: Int, count: Int) async throws -> [APIUsageQueueRecord] {
        withUnsafeCurrentTask { $0?.cancel() }
        return [record]
    }
}

private struct RecordedGap: Equatable {
    let start: Date
    let end: Date
}

private actor RecordingLedgerStore: APIUsageLedgerStoring {
    private var readModel: APIUsageLedgerReadModel
    private let prepareError: APIUsageLedgerStoreError?
    private var mergeError: APIUsageLedgerStoreError?
    private let readError: APIUsageLedgerStoreError?
    private let flushError: APIUsageLedgerStoreError?
    private let suspendReadCall: Int?
    private var readCalls = 0
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var mutations: [APIUsageLedgerMutation] = []
    private var flushes = 0
    private var pauseValues: [(Date, Bool)] = []
    private var gaps: [RecordedGap] = []
    private var persistenceFailures: [Date] = []
    private var successfulDrains = 0
    private var events: [String] = []

    init(
        readModel: APIUsageLedgerReadModel = emptyReadModel(lastSuccessfulDrainAt: nil),
        prepareError: APIUsageLedgerStoreError? = nil,
        mergeError: APIUsageLedgerStoreError? = nil,
        readError: APIUsageLedgerStoreError? = nil,
        flushError: APIUsageLedgerStoreError? = nil,
        suspendReadCall: Int? = nil
    ) {
        self.readModel = readModel
        self.prepareError = prepareError
        self.mergeError = mergeError
        self.readError = readError
        self.flushError = flushError
        self.suspendReadCall = suspendReadCall
    }

    func prepareTracking(at: Date, reportingTimeZoneID: String) async throws {
        events.append("prepare")
        if let prepareError { throw prepareError }
    }

    func merge(_ values: [APIUsageLedgerMutation]) async throws {
        events.append("merge")
        if let mergeError {
            self.mergeError = nil
            throw mergeError
        }
        mutations.append(contentsOf: values)
    }

    func markPersistenceFailure(for timestamps: [Date]) async throws {
        events.append("persistenceFailure")
        persistenceFailures.append(contentsOf: timestamps)
        var metadata = readModel.metadata
        for timestamp in timestamps {
            let bounds = APIUsagePeriodCalculator.bounds(
                at: timestamp,
                timeZoneID: metadata.reportingTimeZoneID
            )
            metadata.partialIntervals.append(.init(
                start: bounds.dayStart,
                end: bounds.dayEnd,
                reason: .persistenceFailure
            ))
        }
        readModel = .init(
            metadata: metadata,
            bounds: readModel.bounds,
            currentMonth: readModel.currentMonth
        )
    }

    func markPaused(at: Date, proxyCouldServeRequests: Bool) async throws {
        events.append("pause")
        pauseValues.append((at, proxyCouldServeRequests))
    }

    func markResumed(at: Date) async throws {
        events.append("resume")
    }

    func markCollectionGap(from: Date, to: Date) async throws {
        events.append("gap")
        gaps.append(.init(start: from, end: to))
    }

    func markSuccessfulDrain(at: Date, lastObservedRequestAt: Date?) async throws {
        events.append("successfulDrain")
        successfulDrains += 1
        var metadata = readModel.metadata
        metadata.lastSuccessfulDrainAt = at
        if let lastObservedRequestAt {
            metadata.lastObservedRequestAt = max(metadata.lastObservedRequestAt ?? lastObservedRequestAt, lastObservedRequestAt)
        }
        readModel = .init(
            metadata: metadata,
            bounds: readModel.bounds,
            currentMonth: readModel.currentMonth
        )
    }

    func readCurrentPeriods(at: Date) async throws -> APIUsageLedgerReadModel {
        events.append("read")
        readCalls += 1
        if readCalls == suspendReadCall {
            await withCheckedContinuation { readContinuation = $0 }
        }
        if let readError { throw readError }
        return readModel
    }

    func flush() async throws {
        events.append("flush")
        flushes += 1
        if let flushError { throw flushError }
    }

    func aggregateMutationCount() -> Int {
        mutations.reduce(0) { count, mutation in
            if case .aggregate = mutation { return count + 1 }
            return count
        }
    }

    func aggregatePriceEpochs() -> [Date?] {
        mutations.compactMap { mutation -> Date?? in
            guard case let .aggregate(_, epoch) = mutation else { return nil }
            return epoch
        }
    }

    func flushCount() -> Int { flushes }
    func pauseArguments() -> [Bool] { pauseValues.map(\.1) }
    func pauseDates() -> [Date] { pauseValues.map(\.0) }
    func deleteCount() -> Int { 0 }
    func collectionGaps() -> [RecordedGap] { gaps }
    func persistenceFailureTimestamps() -> [Date] { persistenceFailures }
    func successfulDrainCount() -> Int { successfulDrains }
    func allEvents() -> [String] { events }
    func eventsPrefix(_ count: Int) -> [String] { Array(events.prefix(count)) }
    func isReadSuspended() -> Bool { readContinuation != nil }

    func resumeRead() {
        readContinuation?.resume()
        readContinuation = nil
    }
}

private actor CompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor StepSleepRecorder {
    private var delays: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: UInt64) async throws {
        delays.append(delay)
        if Task.isCancelled { throw CancellationError() }
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.resumeAll() }
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func recordedDelays() -> [UInt64] { delays }
    func pendingCount() -> Int { continuations.count }
}

private func enabledConfiguration() -> APIUsageCollectorConfiguration {
    .init(
        usageEnabled: true,
        proxyReady: true,
        port: 18_317,
        enabledProviders: [.claude],
        reportingTimeZoneID: "UTC"
    )
}

private func iso(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func makeQueueRecord(
    timestamp: String = "2026-07-25T12:00:00Z",
    authType: String = "apikey"
) -> APIUsageQueueRecord {
    let data = Data(#"{"timestamp":"TIMESTAMP","provider":"claude","executor_type":"ClaudeExecutor","model":"claude-opus-5","alias":"cpm-claude-api/claude-opus-5","auth_type":"AUTH_TYPE","auth_index":"auth-1","failed":false,"accounting_version":2,"token_breakdown":{"schema_version":2,"quality":"complete","total_tokens":30,"input":{"total_tokens":10,"uncached_tokens":10,"cache_read_tokens":0,"cache_write_tokens":0},"output":{"total_tokens":20,"non_reasoning_tokens":20,"reasoning_tokens":0},"unclassified_tokens":0},"service_tier":"standard"}"#
        .replacingOccurrences(of: "TIMESTAMP", with: timestamp)
        .replacingOccurrences(of: "AUTH_TYPE", with: authType)
        .utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(APIUsageQueueRecord.self, from: data)
}

private func emptyReadModel(lastSuccessfulDrainAt: Date?) -> APIUsageLedgerReadModel {
    let at = iso("2026-07-25T12:00:00Z")
    let bounds = APIUsagePeriodCalculator.bounds(at: at, timeZoneID: "UTC")
    let metadata = APIUsageTrackingMetadata(
        schemaVersion: 1,
        reportingTimeZoneID: "UTC",
        trackingStartedAt: bounds.monthStart,
        lastSuccessfulDrainAt: lastSuccessfulDrainAt,
        lastObservedRequestAt: nil,
        collectorPausedAt: nil,
        partialIntervals: []
    )
    return .init(
        metadata: metadata,
        bounds: bounds,
        currentMonth: .init(
            schemaVersion: 1,
            month: bounds.month,
            reportingTimeZoneID: "UTC",
            buckets: [],
            issues: []
        )
    )
}

private func readModelWithPricedClaudeUsage() -> APIUsageLedgerReadModel {
    let base = emptyReadModel(lastSuccessfulDrainAt: iso("2026-07-25T11:59:00Z"))
    let bucket = APIUsageLedgerBucket(
        key: .init(
            localDate: base.bounds.localDate,
            profileID: "claude-api",
            provider: .claude,
            model: "claude-opus-5",
            effectiveServiceTier: "standard",
            pricingVariant: .standard,
            priceEpochStart: iso("2026-07-25T00:00:00Z")
        ),
        uncachedInputTokens: 1_000_000,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        nonReasoningOutputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 1_000_000,
        requestCount: 1,
        failedRequestCount: 0,
        firstObservedAt: base.bounds.intervalReference,
        lastObservedAt: base.bounds.intervalReference
    )
    return .init(
        metadata: base.metadata,
        bounds: base.bounds,
        currentMonth: .init(
            schemaVersion: 1,
            month: base.bounds.month,
            reportingTimeZoneID: "UTC",
            buckets: [bucket],
            issues: []
        )
    )
}

private func eventually(
    timeoutNanoseconds: UInt64 = 100_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        guard DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds else {
            return false
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
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

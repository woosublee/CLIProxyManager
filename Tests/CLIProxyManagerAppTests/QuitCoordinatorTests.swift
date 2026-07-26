import AppKit
import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testRequestQuitAsksForConfirmation() {
        let presenter = StubQuitConfirmationPresenter(shouldConfirm: false)
        let coordinator = QuitCoordinator(quitConfirmationPresenter: presenter)

        coordinator.requestQuit()

        XCTAssertEqual(presenter.confirmationCount, 1)
    }

    func testRequestQuitDoesNotTerminateWhenConfirmationIsCancelled() async {
        let proxyService = StubProxyService()
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: StubQuitConfirmationPresenter(shouldConfirm: false)
        )

        coordinator.requestQuit()

        XCTAssertEqual(proxyService.stopCount, 0)
        XCTAssertEqual(terminator.terminateCount, 0)
    }

    func testRequestQuitTerminatesImmediatelyWhenServerIsStopped() async {
        let proxyService = StubProxyService()
        let terminator = StubAppTerminator()
        let presenter = StubQuitConfirmationPresenter(shouldConfirm: true)
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: presenter,
            shouldStopServerBeforeQuit: { false }
        )

        coordinator.requestQuit()
        for _ in 0..<100 {
            if terminator.terminateCount > 0 { break }
            await Task.yield()
        }

        XCTAssertEqual(presenter.confirmationCount, 0)
        XCTAssertEqual(proxyService.stopCount, 0)
        XCTAssertEqual(terminator.terminateCount, 1)
    }

    func testQuitFlushesUsageBeforeTerminatingWhenServerIsAlreadyStopped() async {
        let events = QuitEventLog()
        let terminator = StubAppTerminator(events: events)
        let coordinator = QuitCoordinator(
            appTerminator: terminator,
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                events.append("flush")
            }
        )

        coordinator.requestQuit()
        for _ in 0..<100 {
            if terminator.terminateCount > 0 { break }
            await Task.yield()
        }

        XCTAssertEqual(events.values, ["flush", "terminate"])
    }

    func testApplicationShouldTerminateWaitsForAsyncPreparationAndRepliesOnce() async {
        let preparation = SuspendedTerminationPreparation()
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            appTerminator: terminator,
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                await preparation.run()
            }
        )
        let delegate = ApplicationTerminationDelegate()
        delegate.quitCoordinator = coordinator
        var replies: [Bool] = []
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
        }

        let firstReply = delegate.applicationShouldTerminate(NSApplication.shared)
        await preparation.waitUntilStarted()
        coordinator.cancelQuit()
        let duplicateReply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(firstReply, .terminateLater)
        XCTAssertEqual(duplicateReply, .terminateLater)
        XCTAssertEqual(preparation.callCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)
        XCTAssertEqual(replies, [])

        preparation.resume()
        for _ in 0..<100 {
            if !replies.isEmpty { break }
            await Task.yield()
        }

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(preparation.callCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)
    }

    func testApplicationDelegateFailsClosedUntilQuitCoordinatorIsInstalled() {
        let delegate = ApplicationTerminationDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateCancel
        )
    }

    func testApplicationTerminationTimesOutAndCancelsQuitWhenPreparationIgnoresCancellation() async {
        let preparation = CancellationIgnoringTerminationPreparation()
        let timeout = SuspendedTerminationTimeout()
        let coordinator = QuitCoordinator(
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                await preparation.run()
            },
            terminationPreparationTimeoutNanoseconds: 20_000_000_000,
            terminationSleep: { delay in
                await timeout.sleep(delay)
            }
        )
        let delegate = ApplicationTerminationDelegate()
        delegate.quitCoordinator = coordinator
        var replies: [Bool] = []
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
        }

        let initialReply = delegate.applicationShouldTerminate(NSApplication.shared)
        await preparation.waitUntilStarted()
        await timeout.waitUntilStarted()
        timeout.resume()
        for _ in 0..<100 where replies.isEmpty { await Task.yield() }

        XCTAssertEqual(initialReply, .terminateLater)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(
            coordinator.quitErrorMessage,
            "Usage data could not be safely flushed before the timeout. Quit was cancelled."
        )

        preparation.resume()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(replies, [false])
    }

    func testApplicationTerminationFlushFailureRepliesFalseAndRetrySuccessRepliesTrue() async {
        let preparation = FailingOnceTerminationPreparation()
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            appTerminator: terminator,
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                try await preparation.run()
            },
            cancelTerminationPreparation: {
                preparation.cancelRequest()
            }
        )
        let delegate = ApplicationTerminationDelegate()
        delegate.quitCoordinator = coordinator
        var replies: [Bool] = []
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        for _ in 0..<100 where replies.isEmpty { await Task.yield() }

        XCTAssertEqual(replies, [false])
        XCTAssertEqual(terminator.terminateCount, 0)
        XCTAssertEqual(
            coordinator.quitErrorMessage,
            "Usage data could not be safely flushed. Quit was cancelled."
        )

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        for _ in 0..<100 where replies.count < 2 { await Task.yield() }

        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(preparation.callCount, 2)
        XCTAssertEqual(terminator.terminateCount, 0)
    }

    func testSecondQuitBeforeTimedOutPreparationCompletesWaitsForSameOperation() async {
        let preparation = SharedRecoverableTerminationPreparation()
        let timeout = SuspendedTerminationTimeout()
        let coordinator = QuitCoordinator(
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                try await preparation.run()
            },
            cancelTerminationPreparation: {
                preparation.cancelRequest()
            },
            terminationPreparationTimeoutNanoseconds: 20_000_000_000,
            terminationSleep: { delay in
                await timeout.sleep(delay)
            }
        )
        let delegate = ApplicationTerminationDelegate()
        delegate.quitCoordinator = coordinator
        var replies: [Bool] = []
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await preparation.waitUntilOperationCount(1)
        await timeout.waitUntilStarted()
        timeout.resume()
        for _ in 0..<100 where replies.isEmpty { await Task.yield() }
        XCTAssertEqual(replies, [false])

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(preparation.operationCount, 1)
        XCTAssertEqual(replies, [false])

        preparation.resumeCurrentOperation()
        for _ in 0..<100 where replies.count < 2 { await Task.yield() }
        XCTAssertEqual(replies, [false, true])
    }

    func testTimedOutPreparationCompletionRecoversAndRetryStartsFreshOperation() async {
        let preparation = SharedRecoverableTerminationPreparation()
        let timeout = SuspendedTerminationTimeout()
        let coordinator = QuitCoordinator(
            shouldStopServerBeforeQuit: { false },
            beforeTerminate: {
                try await preparation.run()
            },
            cancelTerminationPreparation: {
                preparation.cancelRequest()
            },
            terminationPreparationTimeoutNanoseconds: 20_000_000_000,
            terminationSleep: { delay in
                await timeout.sleep(delay)
            }
        )
        let delegate = ApplicationTerminationDelegate()
        delegate.quitCoordinator = coordinator
        var replies: [Bool] = []
        delegate.replyToApplicationShouldTerminate = { _, shouldTerminate in
            replies.append(shouldTerminate)
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await preparation.waitUntilOperationCount(1)
        await timeout.waitUntilStarted()
        timeout.resume()
        for _ in 0..<100 where replies.isEmpty { await Task.yield() }
        preparation.resumeCurrentOperation()
        await preparation.waitUntilRecovered()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await preparation.waitUntilOperationCount(2)
        XCTAssertEqual(replies, [false])

        preparation.resumeCurrentOperation()
        for _ in 0..<100 where replies.count < 2 { await Task.yield() }
        XCTAssertEqual(replies, [false, true])
    }

    func testRequestQuitAsksForConfirmationWhenServerIsStarting() {
        let presenter = StubQuitConfirmationPresenter(shouldConfirm: false)
        let coordinator = QuitCoordinator(
            quitConfirmationPresenter: presenter,
            shouldStopServerBeforeQuit: { true }
        )

        coordinator.requestQuit()

        XCTAssertEqual(presenter.confirmationCount, 1)
    }

    func testServerControlStateRequiresStopBeforeQuitWhileStopping() {
        XCTAssertTrue(ServerControlState.stopping.shouldStopServerBeforeQuit)
    }

    func testConfirmQuitStopsServerBeforeTerminating() async {
        let events = QuitEventLog()
        let proxyService = StubProxyService(events: events)
        let terminator = StubAppTerminator(events: events)
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: StubQuitConfirmationPresenter(shouldConfirm: true)
        )

        await coordinator.confirmQuit()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(terminator.terminateCount, 1)
        XCTAssertEqual(events.values, ["stop", "terminate"])
        XCTAssertFalse(coordinator.isQuitConfirmationPresented)
        XCTAssertNil(coordinator.quitErrorMessage)
    }

    func testConfirmQuitIgnoresDuplicateWhileTerminationIsInProgress() async {
        let preparation = SuspendedTerminationPreparation()
        let proxyService = StubProxyService()
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            beforeTerminate: {
                await preparation.run()
            }
        )

        let first = Task { await coordinator.confirmQuit() }
        await preparation.waitUntilStarted()
        await coordinator.confirmQuit()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(preparation.callCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)

        preparation.resume()
        await first.value
        XCTAssertEqual(terminator.terminateCount, 1)
    }

    func testConfirmQuitDoesNotTerminateWhenServerStopFails() async {
        let proxyService = StubProxyService(stopError: NSError(domain: "test", code: 1))
        let terminator = StubAppTerminator()
        var cancellationCount = 0
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: StubQuitConfirmationPresenter(shouldConfirm: true),
            cancelTerminationPreparation: {
                cancellationCount += 1
            }
        )

        await coordinator.confirmQuit()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(coordinator.quitErrorMessage, "Failed to stop the CLIProxyAPI server. Quit was cancelled.")
    }
}

private final class StubProxyService: ProxyServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let stopError: Error?
    private let events: QuitEventLog?
    private var _stopCount = 0

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    init(stopError: Error? = nil, events: QuitEventLog? = nil) {
        self.stopError = stopError
        self.events = events
    }

    func start(port: Int) async throws {}

    func stop() async throws {
        lock.withLock { _stopCount += 1 }
        events?.append("stop")
        if let stopError {
            throw stopError
        }
    }

    func restart(port: Int) async throws {}
}

@MainActor
private final class StubQuitConfirmationPresenter: QuitConfirmationPresenting, @unchecked Sendable {
    let shouldConfirm: Bool
    private(set) var confirmationCount = 0

    init(shouldConfirm: Bool) {
        self.shouldConfirm = shouldConfirm
    }

    func confirmQuit() -> Bool {
        confirmationCount += 1
        return shouldConfirm
    }
}

private final class StubAppTerminator: AppTerminating, @unchecked Sendable {
    private let lock = NSLock()
    private let events: QuitEventLog?
    private var _terminateCount = 0

    var terminateCount: Int {
        lock.withLock { _terminateCount }
    }

    init(events: QuitEventLog? = nil) {
        self.events = events
    }

    func terminate() {
        lock.withLock { _terminateCount += 1 }
        events?.append("terminate")
    }
}

@MainActor
private final class FailingOnceTerminationPreparation {
    private(set) var callCount = 0

    func run() async throws {
        callCount += 1
        if callCount == 1 {
            throw APIUsageLedgerStoreError.persistenceFailure
        }
    }

    func cancelRequest() {}
}

@MainActor
private final class SharedRecoverableTerminationPreparation {
    private var operationTask: Task<Void, Never>?
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var recoverAfterCompletion = false
    private(set) var operationCount = 0

    func run() async throws {
        recoverAfterCompletion = false
        if let operationTask {
            await operationTask.value
            return
        }

        operationCount += 1
        let task = Task {
            await withCheckedContinuation { continuation in
                operationContinuation = continuation
            }
        }
        operationTask = task
        await task.value
        if recoverAfterCompletion {
            operationTask = nil
            recoverAfterCompletion = false
        }
    }

    func cancelRequest() {
        recoverAfterCompletion = true
    }

    func resumeCurrentOperation() {
        operationContinuation?.resume()
        operationContinuation = nil
    }

    func waitUntilOperationCount(_ expected: Int) async {
        for _ in 0..<100 {
            if operationCount >= expected, operationContinuation != nil { return }
            await Task.yield()
        }
        XCTFail("Expected termination operation count \(expected).")
    }

    func waitUntilRecovered() async {
        for _ in 0..<100 {
            if operationTask == nil { return }
            await Task.yield()
        }
        XCTFail("Expected termination preparation recovery.")
    }
}

@MainActor
private final class SuspendedTerminationPreparation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func run() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        for _ in 0..<100 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Expected termination preparation to start.")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CancellationIgnoringTerminationPreparation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func run() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        for _ in 0..<100 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Expected termination preparation to start.")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendedTerminationTimeout {
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(_ delay: UInt64) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        for _ in 0..<100 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Expected termination timeout to start.")
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class QuitEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.withLock { _values }
    }

    func append(_ value: String) {
        lock.withLock { _values.append(value) }
    }
}

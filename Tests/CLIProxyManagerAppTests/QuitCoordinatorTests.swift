import XCTest
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

    func testRequestQuitTerminatesImmediatelyWhenServerIsStopped() {
        let proxyService = StubProxyService()
        let terminator = StubAppTerminator()
        let presenter = StubQuitConfirmationPresenter(shouldConfirm: true)
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: presenter,
            isServerRunning: { false }
        )

        coordinator.requestQuit()

        XCTAssertEqual(presenter.confirmationCount, 0)
        XCTAssertEqual(proxyService.stopCount, 0)
        XCTAssertEqual(terminator.terminateCount, 1)
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

    func testConfirmQuitDoesNotTerminateWhenServerStopFails() async {
        let proxyService = StubProxyService(stopError: NSError(domain: "test", code: 1))
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: StubQuitConfirmationPresenter(shouldConfirm: true)
        )

        await coordinator.confirmQuit()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(terminator.terminateCount, 0)
        XCTAssertEqual(coordinator.quitErrorMessage, "CLIProxyAPI 서버 종료에 실패했습니다. 앱 종료를 중단했습니다.")
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

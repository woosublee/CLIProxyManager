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
        await Task.yield()

        XCTAssertEqual(proxyService.stopCount, 0)
        XCTAssertEqual(terminator.terminateCount, 0)
    }

    func testConfirmQuitStopsServerBeforeTerminating() async {
        let proxyService = StubProxyService()
        let terminator = StubAppTerminator()
        let coordinator = QuitCoordinator(
            proxyService: proxyService,
            appTerminator: terminator,
            quitConfirmationPresenter: StubQuitConfirmationPresenter(shouldConfirm: true)
        )

        await coordinator.confirmQuit()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(terminator.terminateCount, 1)
        XCTAssertFalse(coordinator.isQuitConfirmationPresented)
    }
}

private final class StubProxyService: ProxyServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopCount = 0

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    func start(port: Int) async throws {}

    func stop() async throws {
        lock.withLock { _stopCount += 1 }
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
    private var _terminateCount = 0

    var terminateCount: Int {
        lock.withLock { _terminateCount }
    }

    func terminate() {
        lock.withLock { _terminateCount += 1 }
    }
}

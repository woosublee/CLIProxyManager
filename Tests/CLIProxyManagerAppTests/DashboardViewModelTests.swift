import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class DashboardViewModelRefreshTests: XCTestCase {
    func testOnboardingStepsMatchSetupFlow() {
        let viewModel = OnboardingViewModel()

        XCTAssertEqual(viewModel.steps.map(\.title), [
            "Claude Code 설치 확인",
            "Claude 구독 연결",
            "Claude API key 선택 입력",
            "OpenAI/Codex 연결",
            "shell functions 설치",
            "프로필 테스트"
        ])
    }

    func testRefreshUpdatesClaudeAndCodexCardsByCommandAndPreservesClaudeAPICard() async {
        let config = AppConfig(
            port: 9444,
            commands: AppConfig.Commands(cc: "claude-local", ccapi: "api-local", ccodex: "codex-local"),
            ccapi: AppConfig.ClaudeAPI(model: "test-claude"),
            ccodex: AppConfig.Codex(opusModel: "test-opus", sonnetModel: "test-sonnet", haikuModel: "test-haiku"),
            includeDangerouslySkipPermissions: false
        )
        let serverStatus = DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI 실행 중",
            message: "포트 9444에서 모델 목록을 불러올 수 있습니다."
        )
        let claudeStatus = DiagnosticStatus(
            severity: .ready,
            title: "Claude Code 연결됨",
            message: "로그인되어 있습니다."
        )
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.serverStatus, serverStatus)
        XCTAssertEqual(viewModel.cards.first { $0.command == "claude-local" }?.status, claudeStatus)
        XCTAssertEqual(viewModel.cards.first { $0.command == "api-local" }?.status, DiagnosticStatus(
            severity: .warning,
            title: "확인 필요",
            message: "상태 확인 전입니다."
        ))
        XCTAssertEqual(viewModel.cards.first { $0.command == "codex-local" }?.status, serverStatus)
    }

    func testStartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testStopServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.stopServer()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testRestartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.restartServer()

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testStartServerFailureUpdatesServerAndCodexCardStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter(error: ProxyServiceError.missingBinary("test"))
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: []))
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "CLIProxyAPI 시작 실패")
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .error)
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testLifecycleActionInProgressPreventsOverlappingActions() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        viewModel.isServerActionInProgress = true
        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [])
        XCTAssertTrue(viewModel.isServerActionInProgress)
    }
}

private struct StubHTTPClient: HTTPClient {
    let result: Result<Data, Error>

    func get(_ url: URL) async throws -> Data {
        try result.get()
    }
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        results.removeFirst()
    }
}

private final class StubProxyServiceStarter: ProxyServiceControlling, @unchecked Sendable {
    private let error: Error?
    private let lock = NSLock()
    private var _ports: [Int] = []
    private var _restartPorts: [Int] = []
    private var _stopCount = 0

    var ports: [Int] {
        lock.withLock { _ports }
    }

    var restartPorts: [Int] {
        lock.withLock { _restartPorts }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func start(port: Int) async throws {
        lock.withLock { _ports.append(port) }
        if let error {
            throw error
        }
    }

    func stop() async throws {
        lock.withLock { _stopCount += 1 }
        if let error {
            throw error
        }
    }

    func restart(port: Int) async throws {
        lock.withLock { _restartPorts.append(port) }
        if let error {
            throw error
        }
    }
}

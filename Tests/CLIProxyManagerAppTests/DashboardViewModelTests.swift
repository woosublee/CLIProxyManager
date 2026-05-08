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

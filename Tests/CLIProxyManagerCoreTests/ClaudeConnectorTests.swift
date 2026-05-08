import XCTest
@testable import CLIProxyManagerCore

final class ClaudeConnectorTests: XCTestCase {
    func testInstalledClaudeReportsReadyWhenAuthStatusSucceeds() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .ready)
        XCTAssertEqual(status.title, "Claude Code 연결됨")
    }

    func testMissingClaudeReportsError() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .error)
        XCTAssertEqual(status.title, "Claude Code 미설치")
    }

    func testLoggedOutClaudeReportsWarning() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "not logged in")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .warning)
        XCTAssertEqual(status.title, "Claude 로그인 필요")
    }

    func testLoginCommandUsesOfficialClaudeAuthLogin() {
        let connector = ClaudeConnector(runner: FakeProcessRunner(results: []))

        XCTAssertEqual(connector.loginCommand(), ["claude", "auth", "login"])
    }

    func testLogoutCommandUsesOfficialClaudeAuthLogout() {
        let connector = ClaudeConnector(runner: FakeProcessRunner(results: []))

        XCTAssertEqual(connector.logoutCommand(), ["claude", "auth", "logout"])
    }
}

private final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        results.removeFirst()
    }
}

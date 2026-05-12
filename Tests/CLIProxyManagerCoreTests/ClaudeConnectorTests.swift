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
        XCTAssertEqual(status.title, "Claude Code Connected")
    }

    func testStatusChecksClaudeCommandsInOrder() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ])
        let connector = ClaudeConnector(runner: runner)

        _ = await connector.status()

        XCTAssertEqual(runner.calls, [
            FakeProcessRunner.Call(executable: "/usr/bin/env", arguments: ["which", "claude"]),
            FakeProcessRunner.Call(executable: "/usr/bin/env", arguments: ["claude", "--version"]),
            FakeProcessRunner.Call(executable: "/usr/bin/env", arguments: ["claude", "auth", "status"])
        ])
    }

    func testMissingClaudeReportsError() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, stdout: "", stderr: "not found")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .error)
        XCTAssertEqual(status.title, "Claude Code Not Installed")
    }

    func testWhichTimeoutReportsTimeoutError() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 124, stdout: "", stderr: "Process timed out after 10.0 seconds", timedOut: true)
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .error)
        XCTAssertEqual(status.title, "Claude Code Check Timed Out")
        XCTAssertEqual(status.message, "Process timed out after 10.0 seconds")
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
        XCTAssertEqual(status.title, "Claude Login Required")
    }

    func testVersionFailureWithEmptyOutputUsesDefaultMessage() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "")
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .warning)
        XCTAssertEqual(status.title, "Claude Code Check Failed")
        XCTAssertEqual(status.message, "Could not determine the Claude Code version.")
    }

    func testAuthTimeoutReportsTimeoutWarning() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "1.2.3\n", stderr: ""),
            ProcessResult(exitCode: 124, stdout: "", stderr: "Process timed out after 10.0 seconds", timedOut: true)
        ])
        let connector = ClaudeConnector(runner: runner)

        let status = await connector.status()

        XCTAssertEqual(status.severity, .warning)
        XCTAssertEqual(status.title, "Claude Login Check Timed Out")
        XCTAssertEqual(status.message, "Process timed out after 10.0 seconds")
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
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private var results: [ProcessResult]
    private(set) var calls: [Call] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        guard results.isEmpty == false else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "FakeProcessRunner exhausted results")
        }
        return results.removeFirst()
    }
}

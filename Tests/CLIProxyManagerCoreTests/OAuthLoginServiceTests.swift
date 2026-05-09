import XCTest
@testable import CLIProxyManagerCore

final class OAuthLoginServiceTests: XCTestCase {
    func testClaudeLoginPreparesRuntimeAndRunsClaudeLoginFlag() async throws {
        let runtime = StubRuntimePreparer()
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed"))
        let service = OAuthLoginService(paths: paths, runtimePreparer: runtime, runner: runner)

        try await service.login(provider: .claude, port: 18_317)

        XCTAssertEqual(runtime.ports, [18_317])
        XCTAssertEqual(runner.invocations, [
            StubProcessRunner.Invocation(
                executable: "/tmp/managed/cliproxyapi/cliproxyapi",
                arguments: ["--config", "/tmp/managed/cliproxyapi/config.yaml", "-claude-login"]
            )
        ])
    }

    func testCodexLoginUsesCodexLoginFlag() async throws {
        let runtime = StubRuntimePreparer()
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let paths = ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed"))
        let service = OAuthLoginService(paths: paths, runtimePreparer: runtime, runner: runner)

        try await service.login(provider: .codex, port: 18_317)

        XCTAssertEqual(runner.invocations.first?.arguments, ["--config", "/tmp/managed/cliproxyapi/config.yaml", "-codex-login"])
    }

    func testLoginFailureIncludesProviderAndProcessOutput() async throws {
        let service = OAuthLoginService(
            paths: ManagedPaths(rootDirectory: URL(fileURLWithPath: "/tmp/managed")),
            runtimePreparer: StubRuntimePreparer(),
            runner: StubProcessRunner(result: ProcessResult(exitCode: 2, stdout: "", stderr: "oauth failed"))
        )

        do {
            try await service.login(provider: .codex, port: 18_317)
            XCTFail("Expected login failure")
        } catch let error as OAuthLoginError {
            XCTAssertEqual(error, .failed(provider: .codex, exitCode: 2, message: "oauth failed"))
        }
    }
}

private final class StubRuntimePreparer: ProxyRuntimePreparing, @unchecked Sendable {
    private let lock = NSLock()
    private var _ports: [Int] = []

    var ports: [Int] { lock.withLock { _ports } }

    func prepare(port: Int) throws {
        lock.withLock { _ports.append(port) }
    }
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let result: ProcessResult
    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] { lock.withLock { _invocations } }

    init(result: ProcessResult) {
        self.result = result
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        return result
    }
}

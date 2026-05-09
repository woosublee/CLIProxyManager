import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class AutomaticShellInstallServiceTests: XCTestCase {
    func testViewModelInstallsDefaultShellFunctionsOnInitialization() {
        let installer = StubShellInstaller()

        _ = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(installer.installedFunctionNames, ["ccm", "ccmapi", "ccmcodex"])
        XCTAssertTrue(installer.installedScript?.contains("ccm() {") == true)
    }

    func testApplyRendersAndInstallsCurrentConfig() throws {
        var config = AppConfig.default
        config.commands.ccodex = "codexcustom"
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(installer: installer, helperCommand: "/usr/local/bin/cliproxy-manager")

        try service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["ccm", "ccmapi", "codexcustom"])
        XCTAssertTrue(installer.installedScript?.contains("codexcustom() {") == true)
    }
}

private final class StubConfigStore: AppConfigStoring, @unchecked Sendable {
    var config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func load() throws -> AppConfig { config }
    func save(_ config: AppConfig) throws { self.config = config }
}

private final class StubShellInstaller: ShellFunctionInstalling, @unchecked Sendable {
    private(set) var installedScript: String?
    private(set) var installedFunctionNames: [String] = []

    func install(functionScript: String, functionNames: [String]) throws {
        installedScript = functionScript
        installedFunctionNames = functionNames
    }

    func isInstalled() -> Bool { installedScript != nil }
}

private final class StubProxyService: ProxyServiceControlling, @unchecked Sendable {
    func start(port: Int) async throws {}
    func stop() async throws {}
    func restart(port: Int) async throws {}
}

private func connectedClaudeConnector() -> ClaudeConnector {
    ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
        ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
    ], count: 4).flatMap { $0 }))
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock {
            guard results.isEmpty == false else {
                XCTFail("Unexpected process run: \(executable) \(arguments.joined(separator: " "))")
                return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected process run")
            }
            return results.removeFirst()
        }
    }
}

import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class ProviderSettingsViewModelTests: XCTestCase {
    func testDefaultProviderRowsHideProfilesUntilAuthExists() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows, [])
    }

    func testAddProviderShowsClaudeAPIHiddenMessage() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.addProvider()

        XCTAssertEqual(viewModel.settingsMessage, "Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다.")
    }

    func testSaveClaudeFunctionNamePersistsAndRebuildsRows() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.saveClaudeFunctionName("myclaude")

        XCTAssertEqual(store.savedConfigs.last?.commands.cc, "myclaude")
        XCTAssertEqual(viewModel.providerRows.first?.functionName, "myclaude")
    }

    func testSaveClaudeOAuthSettingsValidatesActiveFunctionNameBeforePersisting() throws {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller(validationError: ShellProfileInstallerError.functionNameConflicts(["cc"]))
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(functionName: "cc", nickname: "", dangerousPermissionsEnabled: true)) { error in
            XCTAssertEqual(error as? ShellProfileInstallerError, .functionNameConflicts(["cc"]))
        }

        XCTAssertEqual(installer.validatedFunctionNames, [["cc"]])
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSaveClaudeOAuthSettingsPersistsFunctionNameAndPermission() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.saveClaudeOAuthSettings(functionName: "myclaude", nickname: "", dangerousPermissionsEnabled: true)

        XCTAssertEqual(store.savedConfigs.last?.commands.cc, "myclaude")
        XCTAssertEqual(store.savedConfigs.last?.includeDangerouslySkipPermissions, true)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.functionName, "myclaude")
    }

    func testSaveCodexSettingsPersistsFunctionNameRolesAndPermission() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        let codex = testCodex()

        try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "", codex: codex, dangerousPermissionsEnabled: true)

        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "mycodex")
        XCTAssertEqual(store.savedConfigs.last?.ccodex, codex)
        XCTAssertEqual(store.savedConfigs.last?.includeDangerouslySkipPermissions, true)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "mycodex")
    }

    func testSaveCodexSettingsKeepsCurrentConfigWhenPersistenceFails() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        let codex = testCodex()

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "", codex: codex, dangerousPermissionsEnabled: true))

        XCTAssertEqual(viewModel.config, .default)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "ccodex")
        XCTAssertEqual(store.savedConfigs, [])
    }

    private func testCodex() -> AppConfig.Codex {
        AppConfig.Codex(
            opus: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto),
            sonnet: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
            haiku: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
        )
    }

    private func claudeProfile() -> AuthProfile {
        AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
    }

    private func codexProfile() -> AuthProfile {
        AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
    }

    private func connectedClaudeConnector() -> ClaudeConnector {
        ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ], count: 4).flatMap { $0 }))
    }
}

private final class StubConfigStore: AppConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let saveError: Error?
    private(set) var savedConfigs: [AppConfig] = []
    var config: AppConfig

    init(config: AppConfig, saveError: Error? = nil) {
        self.config = config
        self.saveError = saveError
    }

    func load() throws -> AppConfig { config }

    func save(_ config: AppConfig) throws {
        if let saveError {
            throw saveError
        }
        lock.withLock { savedConfigs.append(config) }
        self.config = config
    }
}

private final class StubShellInstaller: ShellFunctionInstalling, @unchecked Sendable {
    private let validationError: Error?
    private(set) var validatedFunctionNames: [[String]] = []

    init(validationError: Error? = nil) {
        self.validationError = validationError
    }

    func install(functionScript: String, functionNames: [String]) throws {}
    func isInstalled() -> Bool { false }

    func validateFunctionNames(_ names: [String]) throws {
        validatedFunctionNames.append(names)
        if let validationError { throw validationError }
    }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    let profilesValue: [AuthProfile]

    init(profiles: [AuthProfile]) {
        profilesValue = profiles
    }

    func profiles() throws -> [AuthProfile] { profilesValue }
    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int { 0 }
    func delete(for type: AuthProfileType) throws -> Int { 0 }
}

private final class StubProxyService: ProxyServiceControlling, @unchecked Sendable {
    func start(port: Int) async throws {}
    func stop() async throws {}
    func restart(port: Int) async throws {}
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

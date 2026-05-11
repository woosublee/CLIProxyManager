import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class AutomaticShellInstallServiceTests: XCTestCase {
    func testViewModelCreatesEmptyShellFunctionsFileOnInitialization() {
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        _ = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }


    func testViewModelInstallsClaudeFunctionAfterSettingsSave() throws {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        try viewModel.saveClaudeOAuthSettings(functionName: "cc", nickname: "", dangerousPermissionsEnabled: false)

        XCTAssertEqual(installer.installedFunctionNames, ["cc"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testViewModelInstallsCodexFunctionAfterSettingsSave() throws {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        try viewModel.saveCodexSettings(functionName: "ccodex", nickname: "", codex: AppConfig.default.ccodex, dangerousPermissionsEnabled: false)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testApplyRendersAndInstallsCurrentConfigWithoutClaudeAPIWhenSecretIsMissing() throws {
        var config = AppConfig.default
        config.commands.ccodex = "codexcustom"
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        try service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "codexcustom"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("codexcustom() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyIncludesClaudeAPIWhenSecretExists() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        try service.apply(
            config: .default,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex", "ccapi"])
        XCTAssertTrue(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyOmitsClaudeAPIOnlyWhenSecretIsMissing() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        try service.apply(config: .default)

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyPropagatesSecretReadFailure() {
        let service = AutomaticShellInstallService(
            installer: StubShellInstaller(),
            secretStore: FailingSecretStore(error: SecretStoreError.readFailed(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        XCTAssertThrowsError(try service.apply(
            config: .default,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )) { error in
            XCTAssertEqual(error as? SecretStoreError, .readFailed(SecretKey.claudeAPIKey.rawValue))
        }
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
    func validateFunctionNames(_ names: [String]) throws {}

    func reset() {
        installedScript = nil
        installedFunctionNames = []
    }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    var profilesValue: [AuthProfile]
    var nextProfiles: [AuthProfile]?

    init(profiles: [AuthProfile]) {
        self.profilesValue = profiles
    }

    func profiles() throws -> [AuthProfile] { profilesValue }

    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int {
        if let nextProfiles { profilesValue = nextProfiles }
        return 1
    }

    func delete(for type: AuthProfileType) throws -> Int { 0 }
}

private final class StubOAuthLoginService: OAuthLoginStarting, @unchecked Sendable {
    func login(provider: OAuthLoginProvider, port: Int) async throws {}
}

private struct FailingSecretStore: SecretStore {
    let error: Error

    func get(_ key: SecretKey) throws -> String { throw error }
    func set(_ value: String, for key: SecretKey) throws {}
    func delete(_ key: SecretKey) throws {}
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

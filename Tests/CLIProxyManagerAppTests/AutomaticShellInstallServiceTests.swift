import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class AutomaticShellInstallServiceTests: XCTestCase {
    func testRuntimeDefaultInstallsShellFunctionsInDebugBuild() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService.runtimeDefault(installer: installer)
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc")
        ]

        try service.apply(config: config)

        XCTAssertNotNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, ["cc"])
    }

    func testDebugDefaultHelperCommandUsesHelperBesideCurrentExecutableWhenAvailable() {
        #if DEBUG
        let executableURL = URL(fileURLWithPath: "/build/debug/CLIProxyManager")

        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: executableURL,
            fileExists: { $0 == "/build/debug/cpm" }
        )

        XCTAssertEqual(helperCommand, "/build/debug/cpm")
        #endif
    }

    func testDefaultHelperCommandUsesBundledHelperInsideAppBundleWhenAvailable() {
        let executableURL = URL(fileURLWithPath: "/Applications/CLIProxyManager.app/Contents/MacOS/CLIProxyManager")

        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: executableURL,
            fileExists: { $0 == "/Applications/CLIProxyManager.app/Contents/Helpers/cpm" }
        )

        XCTAssertEqual(helperCommand, "/Applications/CLIProxyManager.app/Contents/Helpers/cpm")
    }

    func testDefaultHelperCommandMatchesAppBundleExtensionCaseInsensitively() {
        let executableURL = URL(fileURLWithPath: "/Applications/CLIProxyManager.APP/Contents/MacOS/CLIProxyManager")

        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: executableURL,
            fileExists: { $0 == "/Applications/CLIProxyManager.APP/Contents/Helpers/cpm" }
        )

        XCTAssertEqual(helperCommand, "/Applications/CLIProxyManager.APP/Contents/Helpers/cpm")
    }

    func testDefaultHelperCommandIgnoresNonAppBundleHelperCandidate() {
        let executableURL = URL(fileURLWithPath: "/Volumes/CLIProxyManager/CLIProxyManager/Contents/MacOS/CLIProxyManager")

        // Neither /usr/local/bin/cpm nor any bundle path matches → falls back to cliproxy-manager
        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: executableURL,
            fileExists: { $0 == "/Volumes/CLIProxyManager/CLIProxyManager/Contents/Helpers/cpm" }
        )

        XCTAssertEqual(helperCommand, "/usr/local/bin/cliproxy-manager")
    }

    func testDefaultHelperCommandFallsBackToLegacyWhenCpmNotInstalled() {
        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: nil,
            fileExists: { $0 == "/usr/local/bin/cliproxy-manager" }
        )

        XCTAssertEqual(helperCommand, "/usr/local/bin/cliproxy-manager")
    }

    func testDefaultHelperCommandPrefersCpmWhenBothExternalHelpersArePresent() {
        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: nil,
            fileExists: { $0 == "/usr/local/bin/cpm" || $0 == "/usr/local/bin/cliproxy-manager" }
        )

        XCTAssertEqual(helperCommand, "/usr/local/bin/cpm")
    }

    func testDebugDefaultHelperCommandPrefersHelperBesideCurrentExecutableOverParentHelperCandidate() {
        #if DEBUG
        let executableURL = URL(fileURLWithPath: "/build/debug/CLIProxyManager")

        let helperCommand = AutomaticShellInstallService.resolvedDefaultHelperCommand(
            currentExecutableURL: executableURL,
            fileExists: {
                $0 == "/build/debug/cpm" || $0 == "/build/Helpers/cpm"
            }
        )

        XCTAssertEqual(helperCommand, "/build/debug/cpm")
        #endif
    }

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

        try viewModel.saveCodexSettings(functionName: "ccodex", nickname: "", codex: AppConfig.Codex.default, dangerousPermissionsEnabled: false)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testApplyRendersAndInstallsCurrentConfigWithoutClaudeAPIWhenSecretIsMissing() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "codexcustom", codex: .default)
        ]
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

    func testApplyIncludesRoundRobinNameWithoutBlankLegacyName() throws {
        var config = AppConfig.default
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-a.json", "codex-b.json"]
            )
        ]
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        try service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testApplyIncludesClaudeAPIWhenSecretExists() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]
        config.claudeAPI.commandName = "ccapi"

        try service.apply(
            config: config,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex", "ccapi"])
        XCTAssertTrue(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplySkipsClaudeAPIWhenCommandNameIsBlankEvenIfSecretExists() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]

        try service.apply(
            config: config,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyOmitsClaudeAPIOnlyWhenSecretIsMissing() throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]

        try service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyPropagatesSecretReadFailure() {
        let service = AutomaticShellInstallService(
            installer: StubShellInstaller(),
            secretStore: FailingSecretStore(error: SecretStoreError.readFailed(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        var config = AppConfig.default
        config.claudeAPI.commandName = "ccapi"

        XCTAssertThrowsError(try service.apply(
            config: config,
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

    func setPrefix(_ prefix: String?, id: String) throws -> Bool {
        guard let index = profilesValue.firstIndex(where: { $0.id == id }) else { return false }
        let profile = profilesValue[index]
        profilesValue[index] = AuthProfile(
            fileName: profile.fileName,
            type: profile.type,
            email: profile.email,
            accountID: profile.accountID,
            expired: profile.expired,
            disabled: profile.disabled,
            prefix: prefix
        )
        return true
    }

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

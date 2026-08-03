import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class AutomaticShellInstallServiceTests: XCTestCase {
    func testRuntimeDefaultInstallsShellFunctionsInDebugBuild() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService.runtimeDefault(
            installer: installer,
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc")
        ]

        try await service.apply(config: config)

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

    func testViewModelCreatesEmptyShellFunctionsFileOnInitialization() async {
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        _ = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }


    func testViewModelInstallsClaudeFunctionAfterSettingsSave() async throws {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
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
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(installer.installedFunctionNames, ["cc"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testViewModelInstallsCodexFunctionAfterSettingsSave() async throws {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
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
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testApplyRendersAndInstallsCurrentConfigWithoutClaudeAPIWhenSecretIsMissing() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "codexcustom", codex: .default)
        ]
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        try await service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "codexcustom"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("codexcustom() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyIncludesRoundRobinNameWithoutBlankLegacyName() async throws {
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
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        try await service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testApplyIncludesClaudeAPIWhenSecretExists() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]
        config.claudeAPI.commandName = "ccapi"

        try await service.apply(
            config: config,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex", "ccapi"])
        XCTAssertTrue(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplySkipsClaudeAPIWhenCommandNameIsBlankEvenIfSecretExists() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]

        try await service.apply(
            config: config,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplyOmitsClaudeAPIOnlyWhenSecretIsMissing() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.missingSecret(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "ccodex", codex: .default)
        ]

        try await service.apply(config: config)

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testApplySkipsAPIProfileWhenSecretReadFails() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            secretStore: FailingSecretStore(error: SecretStoreError.readFailed(SecretKey.claudeAPIKey.rawValue)),
            helperCommand: "/usr/local/bin/cliproxy-manager",
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport())
        )

        var config = AppConfig.default
        config.claudeAPI.commandName = "ccapi"

        try await service.apply(
            config: config,
            enabledFunctions: AutomaticShellInstallService.EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: true)
        )

        XCTAssertTrue(installer.installedFunctionNames.isEmpty)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testNonZshExplicitInstallDoesNotWriteShellFiles() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(
                report: compatibilityReport(
                    finding: .unsupportedLoginShell(expectedBasename: "zsh", actualBasename: "bash")
                )
            )
        )

        do {
            _ = try await service.apply(config: .default)
            XCTFail("Expected unsupported-login-shell block")
        } catch let error as ShellFunctionInstallationError {
            XCTAssertEqual(error, .unsupportedLoginShell)
        } catch {
            XCTFail("Expected sanitized shell compatibility blocker, got \(error)")
        }

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, [])
    }

    func testClaudeUnavailableExplicitInstallDoesNotWriteClaudeShellFunctions() async throws {
        let installer = StubShellInstaller()
        let service = AutomaticShellInstallService(
            installer: installer,
            compatibilityAuthorizer: FixedCompatibilityAuthorizer(report: allowedCompatibilityReport()),
            claudeInspector: FixedClaudeCodeInspector(observation: .unavailable)
        )
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude",
                provider: .claude,
                authProfileID: "claude.json",
                commandName: "cc"
            )
        ]

        do {
            try await service.apply(config: config)
            XCTFail("Expected unavailable-Claude block")
        } catch let error as ShellFunctionInstallationError {
            XCTAssertEqual(error, .claudeCodeUnavailable)
        } catch {
            XCTFail("Expected sanitized shell compatibility blocker, got \(error)")
        }

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, [])
    }

    func testApplyFinishesCompatibilityPreflightBeforeWritingShellFiles() async throws {
        let events = InstallationEventLog()
        let installer = OrderedShellInstaller(events: events)
        let service = AutomaticShellInstallService(
            installer: installer,
            compatibilityAuthorizer: OrderedCompatibilityAuthorizer(events: events)
        )

        _ = try await service.apply(config: .default)

        XCTAssertEqual(events.events, ["preflight", "install"])
    }

    func testLatestAutomaticReconciliationPreventsOlderPreflightFromOverwritingNewerFunctions() async throws {
        let installer = StubShellInstaller()
        let compatibilityAuthorizer = FirstPreflightDelayingCompatibilityAuthorizer()
        let service = AutomaticShellInstallService(
            installer: installer,
            compatibilityAuthorizer: compatibilityAuthorizer
        )
        var olderConfig = AppConfig.default
        olderConfig.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude",
                provider: .claude,
                authProfileID: "claude.json",
                commandName: "ccold"
            )
        ]
        var newerConfig = olderConfig
        newerConfig.oauthCommandProfiles[0].commandName = "ccnew"

        let olderReconciliation = Task {
            try await service.reconcile(config: olderConfig)
        }
        await compatibilityAuthorizer.waitForFirstPreflight()

        _ = try await service.reconcile(config: newerConfig)
        await compatibilityAuthorizer.releaseFirstPreflight()
        _ = try await olderReconciliation.value

        XCTAssertEqual(installer.installationHistory, [["ccnew"]])
    }

    func testExplicitInstallWinsOverAutomaticReconciliationStartedDuringExplicitPreflight() async throws {
        let installer = StubShellInstaller()
        let compatibilityAuthorizer = FirstPreflightDelayingCompatibilityAuthorizer()
        let service = AutomaticShellInstallService(
            installer: installer,
            compatibilityAuthorizer: compatibilityAuthorizer
        )
        var explicitConfig = AppConfig.default
        explicitConfig.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude",
                provider: .claude,
                authProfileID: "claude.json",
                commandName: "ccexplicit"
            )
        ]
        var automaticConfig = explicitConfig
        automaticConfig.oauthCommandProfiles[0].commandName = "ccautomatic"

        let explicitInstall = Task {
            try await service.apply(config: explicitConfig)
        }
        await compatibilityAuthorizer.waitForFirstPreflight()

        let automaticResult = try await service.reconcile(config: automaticConfig)
        await compatibilityAuthorizer.releaseFirstPreflight()
        try await explicitInstall.value

        XCTAssertEqual(automaticResult, .skippedForSupersededRequest)
        XCTAssertEqual(installer.installationHistory, [["ccexplicit"]])
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
    private(set) var installationHistory: [[String]] = []

    func install(functionScript: String, functionNames: [String]) throws {
        installedScript = functionScript
        installedFunctionNames = functionNames
        installationHistory.append(functionNames)
    }

    func isInstalled() -> Bool { installedScript != nil }
    func validateFunctionNames(_ names: [String]) throws {}

    func reset() {
        installedScript = nil
        installedFunctionNames = []
        installationHistory = []
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

private struct FixedCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing {
    let report: RuntimeCompatibilityReport

    func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport { report }

    func report(artifacts _: CompatibilityArtifacts) async -> RuntimeCompatibilityReport { report }

    func require(_ action: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {
        guard report.decision(for: action).disposition != .blocked else {
            throw RuntimeCompatibilityError.actionBlocked(action)
        }
    }
}

private func compatibilityReport(finding: CompatibilityFinding) -> RuntimeCompatibilityReport {
    let disposition: CompatibilityDisposition
    switch finding {
    case .unsupportedLoginShell:
        disposition = .blocked
    default:
        disposition = .blocked
    }
    return RuntimeCompatibilityReport(
        findings: [finding],
        decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
            (
                action,
                CompatibilityDecision(
                    action: action,
                    disposition: action == .installShellFunctions ? disposition : .allowed
                )
            )
        })
    )
}

private func allowedCompatibilityReport() -> RuntimeCompatibilityReport {
    RuntimeCompatibilityReport(
        findings: [],
        decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
            (action, CompatibilityDecision(action: action, disposition: .allowed))
        })
    )
}

private final class InstallationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] { lock.withLock { recordedEvents } }

    func record(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private struct FixedClaudeCodeInspector: ClaudeCodeInspecting {
    let observation: ClaudeCodeObservation

    func observeVersion() async -> ClaudeCodeObservation {
        observation
    }
}

private struct OrderedCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing {
    let events: InstallationEventLog

    func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        allowedCompatibilityReport()
    }

    func report(artifacts _: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        events.record("preflight")
        return allowedCompatibilityReport()
    }

    func require(_: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {}
}

private final class OrderedShellInstaller: ShellFunctionInstalling, @unchecked Sendable {
    private let events: InstallationEventLog

    init(events: InstallationEventLog) {
        self.events = events
    }

    func install(functionScript _: String, functionNames _: [String]) throws {
        events.record("install")
    }

    func isInstalled() -> Bool { false }

    func validateFunctionNames(_: [String]) throws {}
}

private actor FirstPreflightDelayingCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing {
    private var firstPreflightStarted = false
    private var firstPreflightWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstPreflightRelease: CheckedContinuation<Void, Never>?
    private var firstPreflightReleased = false
    private var reportCount = 0

    nonisolated func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        allowedCompatibilityReport()
    }

    func report(artifacts _: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        reportCount += 1
        guard reportCount == 1 else { return allowedCompatibilityReport() }

        firstPreflightStarted = true
        let waiters = firstPreflightWaiters
        firstPreflightWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !firstPreflightReleased {
            await withCheckedContinuation { firstPreflightRelease = $0 }
        }
        return allowedCompatibilityReport()
    }

    nonisolated func require(_: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {}

    func waitForFirstPreflight() async {
        guard !firstPreflightStarted else { return }
        await withCheckedContinuation { firstPreflightWaiters.append($0) }
    }

    func releaseFirstPreflight() {
        firstPreflightReleased = true
        let release = firstPreflightRelease
        firstPreflightRelease = nil
        release?.resume()
    }
}

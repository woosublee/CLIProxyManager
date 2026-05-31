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

        XCTAssertEqual(viewModel.settingsMessage, "Claude API profiles are hidden from the default account list in this version.")
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


    func testSaveClaudeFunctionNameRejectsInvalidShellName() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertThrowsError(try viewModel.saveClaudeFunctionName("//")) { error in
            XCTAssertEqual(error as? ShellFunctionRendererError, .invalidFunctionName("//"))
        }

        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(viewModel.config.commands.cc, "")
    }

    func testSaveClaudeOAuthSettingsRejectsInvalidShellName() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(functionName: "//", nickname: "", dangerousPermissionsEnabled: false)) { error in
            XCTAssertEqual(error as? ShellFunctionRendererError, .invalidFunctionName("//"))
        }

        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(viewModel.config.commands.cc, "")
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

    func testInitialOAuthSettingsDisableDangerousPermissionsByDefault() {
        var config = AppConfig.default
        config.includeDangerouslySkipPermissions = true

        XCTAssertFalse(oauthSettingsDangerousPermissionDefault(config: config, isInitialSetup: true))
    }

    func testInitialOAuthSettingsLeaveCommandNamesEmptyAndNicknameBlank() {
        var config = AppConfig.default
        config.commands.cc = "customclaude"
        config.commands.ccodex = "ccmcodex"
        config.nicknames = AppConfig.Nicknames(cc: "old-claude", ccodex: "old-codex")
        config.includeDangerouslySkipPermissions = true

        XCTAssertEqual(oauthSettingsInitialState(config: config, provider: .claude, isInitialSetup: true), OAuthSettingsInitialState(
            functionName: "",
            nickname: "",
            dangerousPermissionsEnabled: false
        ))
        XCTAssertEqual(oauthSettingsInitialState(config: config, provider: .codex, isInitialSetup: true), OAuthSettingsInitialState(
            functionName: "",
            nickname: "",
            dangerousPermissionsEnabled: false
        ))
        XCTAssertEqual(oauthSettingsRecommendedFunctionName(provider: .claude), "")
        XCTAssertEqual(oauthSettingsRecommendedFunctionName(provider: .codex), "")
    }

    func testInitialCodexSettingsUseDefaultModelRouting() {
        var config = AppConfig.default
        config.ccodex = AppConfig.Codex(
            opus: AppConfig.CodexRole(model: "old-opus", reasoning: .high, contextWindow: .context200k),
            sonnet: AppConfig.CodexRole(model: "old-sonnet", reasoning: .medium, contextWindow: .context400k),
            haiku: AppConfig.CodexRole(model: "old-haiku", reasoning: .low, contextWindow: .context1m)
        )

        XCTAssertEqual(oauthSettingsInitialCodex(config: config, isInitialSetup: true), AppConfig.default.ccodex)
    }

    func testExistingOAuthSettingsUseConfiguredCommandNamesAndNickname() {
        var config = AppConfig.default
        config.commands.cc = "customclaude"
        config.commands.ccodex = "ccmcodex"
        config.nicknames = AppConfig.Nicknames(cc: "work", ccodex: "personal")
        config.includeDangerouslySkipPermissions = true

        XCTAssertEqual(oauthSettingsInitialState(config: config, provider: .claude, isInitialSetup: false), OAuthSettingsInitialState(
            functionName: "customclaude",
            nickname: "work",
            dangerousPermissionsEnabled: true
        ))
        XCTAssertEqual(oauthSettingsInitialState(config: config, provider: .codex, isInitialSetup: false), OAuthSettingsInitialState(
            functionName: "ccmcodex",
            nickname: "personal",
            dangerousPermissionsEnabled: true
        ))
    }

    func testExistingOAuthSettingsUseCurrentDangerousPermissionValue() {
        var config = AppConfig.default
        config.includeDangerouslySkipPermissions = true

        XCTAssertTrue(oauthSettingsDangerousPermissionDefault(config: config, isInitialSetup: false))
    }

    func testInitialSetupCommandConflictDoesNotBlockSettingsSheet() {
        XCTAssertFalse(oauthSettingsShouldBlockInitialDisplay(isInitialSetup: true, availability: .unavailable("conflict")))
        XCTAssertTrue(oauthSettingsShouldBlockInitialDisplay(isInitialSetup: false, availability: .unavailable("conflict")))
    }

    func testCommandNameAvailabilityReportsValidNamesAsAvailable() async {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "myclaude")

        XCTAssertEqual(availability, .available)
    }

    func testCommandNameAvailabilityReportsInvalidNames() async {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "//")

        XCTAssertEqual(availability, .unavailable("Invalid command name `//`. Use lowercase ASCII letters, numbers, and underscores. The first character must be a lowercase letter or underscore."))
    }

    func testCommandNameAvailabilityReportsZshrcConflicts() async {
        let installer = StubShellInstaller(validationError: ShellProfileInstallerError.functionNameConflicts(["myclaude"]))
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "myclaude")

        XCTAssertEqual(installer.validatedFunctionNames, [["myclaude"]])
        XCTAssertEqual(availability, .unavailable("Cannot install shell functions: `myclaude` is already defined as an alias or function in ~/.zshrc. Pick a different command name in account settings, or remove the existing definition from your shell profile."))
    }

    func testCommandNameAvailabilityIgnoresOtherProviderZshrcConflicts() async {
        let installer = StubShellInstaller(conflictingFunctionNames: ["cc"])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        let availability = await viewModel.commandNameAvailability(provider: .codex, functionName: "ccd123")

        XCTAssertEqual(installer.validatedFunctionNames, [["ccd123"]])
        XCTAssertEqual(availability, .available)
    }

    func testCommandNameAvailabilityReportsDuplicateActiveProviderNames() async {
        var config = AppConfig.default
        config.commands.ccodex = "same"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "same")

        XCTAssertEqual(availability, .unavailable("Command name `same` is already used by another provider."))
    }

    func testSaveClaudeOAuthSettingsRejectsDuplicateActiveProviderNames() throws {
        var config = AppConfig.default
        config.commands.ccodex = "same"
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(functionName: "same", nickname: "", dangerousPermissionsEnabled: false)) { error in
            XCTAssertEqual(error as? ShellFunctionRendererError, .duplicateFunctionNames(["same"]))
        }

        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSaveClaudeOAuthSettingsNormalizesCommandNameBeforePersisting() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.saveClaudeOAuthSettings(functionName: " myclaude ", nickname: "", dangerousPermissionsEnabled: false)

        XCTAssertEqual(store.savedConfigs.last?.commands.cc, "myclaude")
        XCTAssertEqual(viewModel.config.commands.cc, "myclaude")
    }

    func testSaveClaudeOAuthSettingsIgnoresInvalidInactiveProviderCommandName() throws {
        var config = AppConfig.default
        config.commands.ccodex = "bad;rm"
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.saveClaudeOAuthSettings(functionName: "myclaude", nickname: "", dangerousPermissionsEnabled: false)

        XCTAssertEqual(store.savedConfigs.last?.commands.cc, "myclaude")
        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "bad;rm")
    }

    func testSaveClaudeAPISettingsValidatesEditedCommandNameOnly() throws {
        var config = AppConfig.default
        config.commands.cc = "bad;rm"
        config.commands.ccodex = "also;bad"
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller(conflictingFunctionNames: ["ccapi"])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveClaudeAPISettings(functionName: "ccapi", model: "claude-opus-4-8")) { error in
            XCTAssertEqual(error as? ShellProfileInstallerError, .functionNameConflicts(["ccapi"]))
        }

        XCTAssertEqual(installer.validatedFunctionNames, [["ccapi"]])
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSaveClaudeAPISettingsPersistsExplicitCommandNameAndModel() throws {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        try viewModel.saveClaudeAPISettings(functionName: " myapi ", model: "claude-sonnet-4-6")

        XCTAssertEqual(store.savedConfigs.last?.commands.ccapi, "myapi")
        XCTAssertEqual(store.savedConfigs.last?.ccapi.model, "claude-sonnet-4-6")
    }

    func testSaveClaudeAPISettingsAllowsBlankCommandNameToDisableFunction() throws {
        var config = AppConfig.default
        config.commands.ccapi = "oldapi"
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        try viewModel.saveClaudeAPISettings(functionName: "   ", model: "claude-opus-4-8")

        XCTAssertEqual(store.savedConfigs.last?.commands.ccapi, "")
        XCTAssertEqual(store.savedConfigs.last?.ccapi.model, "claude-opus-4-8")
        XCTAssertEqual(installer.validatedFunctionNames, [])
    }

    func testSaveCodexSettingsNormalizesCommandNameBeforePersisting() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.saveCodexSettings(functionName: " mycodex ", nickname: "", codex: testCodex(), dangerousPermissionsEnabled: false)

        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "mycodex")
        XCTAssertEqual(viewModel.config.commands.ccodex, "mycodex")
    }

    func testSaveCodexSettingsIgnoresClaudeZshrcConflict() throws {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller(conflictingFunctionNames: ["cc"])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        try viewModel.saveCodexSettings(functionName: "ccd123", nickname: "", codex: testCodex(), dangerousPermissionsEnabled: false)

        XCTAssertEqual(installer.validatedFunctionNames, [["ccd123"]])
        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "ccd123")
        XCTAssertTrue(installer.installedScript?.contains("ccd123() {") == true)
    }

    func testInitialShellInstallKeepsCodexFunctionWhenClaudeNameConflictsInZshrc() {
        var config = AppConfig.default
        config.commands.cc = "cc"
        config.commands.ccodex = "ccd123"
        let installer = StubShellInstaller(conflictingFunctionNames: ["cc"])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(installer.validatedFunctionNames, [])
        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccd123"])
        XCTAssertTrue(installer.installedScript?.contains("ccd123() {") == true)
        XCTAssertFalse(viewModel.settingsMessage?.contains("Cannot install shell functions") == true)
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
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "")
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testRemoveClaudeProviderResetsClaudeSettings() {
        var config = AppConfig.default
        config.commands.cc = "customclaude"
        config.commands.ccodex = "teamcodex"
        config.nicknames = AppConfig.Nicknames(cc: "old-claude", ccodex: "keep-codex")
        config.includeDangerouslySkipPermissions = true
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.removeProvider(.claude)

        XCTAssertEqual(viewModel.config.commands.cc, AppConfig.default.commands.cc)
        XCTAssertEqual(viewModel.config.commands.ccodex, "teamcodex")
        XCTAssertEqual(viewModel.config.nicknames.cc, "")
        XCTAssertEqual(viewModel.config.nicknames.ccodex, "keep-codex")
        XCTAssertFalse(viewModel.config.includeDangerouslySkipPermissions)
        XCTAssertEqual(store.savedConfigs.last?.commands.cc, AppConfig.default.commands.cc)
    }

    func testRemoveCodexProviderResetsCodexSettings() {
        var config = AppConfig.default
        config.commands.cc = "teamclaude"
        config.commands.ccodex = "customcodex"
        config.nicknames = AppConfig.Nicknames(cc: "keep-claude", ccodex: "old-codex")
        config.ccodex = testCodex(model: "custom-model")
        config.includeDangerouslySkipPermissions = true
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.removeProvider(.codex)

        XCTAssertEqual(viewModel.config.commands.cc, "teamclaude")
        XCTAssertEqual(viewModel.config.commands.ccodex, AppConfig.default.commands.ccodex)
        XCTAssertEqual(viewModel.config.nicknames.cc, "keep-claude")
        XCTAssertEqual(viewModel.config.nicknames.ccodex, "")
        XCTAssertEqual(viewModel.config.ccodex, AppConfig.default.ccodex)
        XCTAssertFalse(viewModel.config.includeDangerouslySkipPermissions)
        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, AppConfig.default.commands.ccodex)
    }

    func testRemoveProviderRewritesShellFunctionsWithoutDeletedProvider() {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()])
        var config = AppConfig.default
        config.commands.cc = "cc"
        config.commands.ccodex = "ccodex"
        _ = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        viewModel.removeProvider(.claude)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testDisconnectProviderDoesNotRewriteShellFunctions() {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector()
        )
        installer.reset()

        viewModel.disconnectProvider(.claude)

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, [])
    }

    private func testCodex(model: String = "gpt-5.5") -> AppConfig.Codex {
        AppConfig.Codex(
            opus: AppConfig.CodexRole(model: model, reasoning: .xhigh, contextWindow: .auto),
            sonnet: AppConfig.CodexRole(model: model, reasoning: .medium, contextWindow: .auto),
            haiku: AppConfig.CodexRole(model: model, reasoning: .low, contextWindow: .auto)
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
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
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
    private let conflictingFunctionNames: Set<String>
    private(set) var installedScript: String?
    private(set) var installedFunctionNames: [String] = []
    private(set) var validatedFunctionNames: [[String]] = []

    init(validationError: Error? = nil, conflictingFunctionNames: Set<String> = []) {
        self.validationError = validationError
        self.conflictingFunctionNames = conflictingFunctionNames
    }

    func install(functionScript: String, functionNames: [String]) throws {
        installedScript = functionScript
        installedFunctionNames = functionNames
    }

    func isInstalled() -> Bool { false }

    func validateFunctionNames(_ names: [String]) throws {
        validatedFunctionNames.append(names)
        let conflicts = names.filter { conflictingFunctionNames.contains($0) }
        if !conflicts.isEmpty { throw ShellProfileInstallerError.functionNameConflicts(conflicts) }
        if let validationError { throw validationError }
    }

    func reset() {
        installedScript = nil
        installedFunctionNames = []
        validatedFunctionNames = []
    }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private var profilesValue: [AuthProfile]

    init(profiles: [AuthProfile]) {
        profilesValue = profiles
    }

    func profiles() throws -> [AuthProfile] { profilesValue }

    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int {
        let matchingCount = profilesValue.filter { $0.type == type }.count
        profilesValue = profilesValue.map { profile in
            guard profile.type == type else { return profile }
            return AuthProfile(fileName: profile.fileName, type: profile.type, email: profile.email, accountID: profile.accountID, expired: profile.expired, disabled: disabled)
        }
        return matchingCount
    }

    func delete(for type: AuthProfileType) throws -> Int {
        let matchingCount = profilesValue.filter { $0.type == type }.count
        profilesValue.removeAll { $0.type == type }
        return matchingCount
    }
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

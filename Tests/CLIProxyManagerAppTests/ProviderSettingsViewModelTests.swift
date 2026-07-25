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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows, [])
    }

    func testConfiguredAPIKeysAppearAsProviderRows() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "claude-key", .codexAPIKey: "codex-key"])
        )

        let apiRows = viewModel.providerRows.filter { $0.id == .claudeAPI || $0.id == .codexAPI }
        XCTAssertEqual(apiRows.map { $0.id.rawValue }, ["claude-api", "codex-api"])
        XCTAssertEqual(apiRows.map { $0.name }, ["Claude API Key", "OpenAI API Key"])
        XCTAssertEqual(apiRows.map(\.usageState), [.apiCost(.disabled), .apiCost(.disabled)])
    }

    func testConfiguredAPIKeyRowsExposePersistedNicknames() {
        var config = AppConfig.default
        config.ccapi = .init(nickname: "Anthropic Work")
        config.codexAPI = .init(codex: config.ccodex, nickname: "OpenAI Personal")
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "claude-key", .codexAPIKey: "codex-key"])
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claudeAPI }?.nickname, "Anthropic Work")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codexAPI }?.nickname, "OpenAI Personal")
    }

    func testSaveClaudeAPIKeyDoesNotPersistKeyInAppConfig() throws {
        let store = StubConfigStore(config: .default)
        let secretStore = InMemorySecretStore()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )

        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            nickname: "Anthropic Work",
            dangerousPermissionsEnabled: true,
            key: "secret-value"
        )

        XCTAssertEqual(try secretStore.get(.claudeAPIKey), "secret-value")
        XCTAssertEqual(store.config.commands.ccapi, "ccapi")
        XCTAssertEqual(store.config.ccapi.nickname, "Anthropic Work")
        XCTAssertEqual(store.config.ccapi.connectionMode, .proxy)
        XCTAssertTrue(store.config.ccapi.dangerousPermissionsEnabled)
        XCTAssertFalse(String(data: try JSONEncoder().encode(store.config), encoding: .utf8)!.contains("secret-value"))
    }

    func testClaudeAPISettingsRestorePreviousKeyWhenConfigSaveFails() throws {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let secretStore = InMemorySecretStore(values: [.claudeAPIKey: "old-key"])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )

        XCTAssertThrowsError(try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        ))

        XCTAssertEqual(try secretStore.get(.claudeAPIKey), "old-key")
    }

    func testRemoveAPIProviderRestoresKeyWhenConfigSaveFails() throws {
        var config = AppConfig.default
        config.commands.ccapi = "ccapi"
        let store = StubConfigStore(config: config, saveError: NSError(domain: "test", code: 1))
        let secretStore = InMemorySecretStore(values: [.claudeAPIKey: "old-key"])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )

        viewModel.removeAPIProvider(.claudeAPI)

        XCTAssertEqual(try secretStore.get(.claudeAPIKey), "old-key")
        XCTAssertEqual(viewModel.config.commands.ccapi, "ccapi")
    }

    func testSaveCodexAPISettingsNormalizesPrefixedModelsBeforePersisting() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let routing = AppConfig.Codex(
            opus: .init(model: "cpm-codex-api/gpt-5.6(xhigh)", reasoning: .xhigh),
            sonnet: .init(model: "codex-work/gpt-5.6", reasoning: .medium),
            haiku: .init(model: "openai/gpt-5.6-mini(low)", reasoning: .low)
        )

        try viewModel.saveCodexAPISettings(
            functionName: "ccodexapi",
            codex: routing,
            dangerousPermissionsEnabled: false,
            key: nil
        )

        XCTAssertEqual(store.config.codexAPI.codex.opus.model, "gpt-5.6")
        XCTAssertEqual(store.config.codexAPI.codex.sonnet.model, "gpt-5.6")
        XCTAssertEqual(store.config.codexAPI.codex.haiku.model, "gpt-5.6-mini")
    }

    func testSaveCodexAPISettingsPersistsRoleRoutingAndItsOwnSkipPermissionSetting() throws {
        let store = StubConfigStore(config: .default)
        let secretStore = InMemorySecretStore()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )
        let routing = AppConfig.Codex(
            opus: .init(model: "gpt-5.6", reasoning: .xhigh),
            sonnet: .init(model: "gpt-5.6", reasoning: .medium),
            haiku: .init(model: "gpt-5.6-mini", reasoning: .low)
        )

        try viewModel.saveCodexAPISettings(
            functionName: "ccodexapi",
            nickname: "OpenAI Personal",
            codex: routing,
            dangerousPermissionsEnabled: true,
            key: "codex-secret"
        )

        XCTAssertEqual(try secretStore.get(.codexAPIKey), "codex-secret")
        XCTAssertEqual(store.config.commands.ccodexapi, "ccodexapi")
        XCTAssertEqual(store.config.codexAPI.nickname, "OpenAI Personal")
        XCTAssertEqual(store.config.codexAPI.codex, routing)
        XCTAssertTrue(store.config.codexAPI.dangerousPermissionsEnabled)
        XCTAssertFalse(store.config.includeDangerouslySkipPermissions)
    }

    func testRollbackLegacyFallbackProviderRowsUseUniqueIDsForMultipleSameProviderAuthProfiles() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(provider: .claude, functionName: "ccwork", nickname: "", dangerousPermissionsEnabled: false))

        XCTAssertEqual(viewModel.providerRows.map(\.id), [
            ProviderRowState.ID(rawValue: "claude"),
            ProviderRowState.ID(rawValue: "claude-claude-personal-json")
        ])
        XCTAssertEqual(Set(viewModel.providerRows.map(\.id)).count, 2)
        XCTAssertEqual(viewModel.providerRows.map(\.authProfileID), ["claude-work.json", "claude-personal.json"])
    }

    func testSaveClaudeFunctionNamePersistsAndRebuildsRows() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            opus: AppConfig.CodexRole(model: "old-opus", reasoning: .high),
            sonnet: AppConfig.CodexRole(model: "old-sonnet", reasoning: .medium),
            haiku: AppConfig.CodexRole(model: "old-haiku", reasoning: .low)
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "same")

        XCTAssertEqual(availability, .unavailable("Command name `same` is already used by another provider."))
    }

    func testCommandNameAvailabilityReportsDuplicateRoundRobinNames() async {
        var config = AppConfig.default
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "same",
                includedAuthProfileIDs: ["codex.json", "codex-team.json"]
            )
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveClaudeAPISettings(functionName: "ccapi", dangerousPermissionsEnabled: false, key: nil)) { error in
            XCTAssertEqual(error as? ShellProfileInstallerError, .functionNameConflicts(["ccapi"]))
        }

        XCTAssertEqual(installer.validatedFunctionNames, [["ccapi"]])
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSaveClaudeAPISettingsPersistsExplicitCommandNameAndSkipPermissionSetting() throws {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        let routing = ClaudeRouting(
            opus: .model("claude-opus-4-8"),
            sonnet: .automatic,
            haiku: .model("claude-haiku-4-5")
        )
        try viewModel.saveClaudeAPISettings(
            functionName: " myapi ",
            claudeRouting: routing,
            dangerousPermissionsEnabled: true,
            key: nil
        )

        XCTAssertEqual(store.savedConfigs.last?.commands.ccapi, "myapi")
        XCTAssertEqual(store.savedConfigs.last?.ccapi.connectionMode, .proxy)
        XCTAssertEqual(store.savedConfigs.last?.ccapi.claude, routing)
        XCTAssertTrue(store.savedConfigs.last?.ccapi.dangerousPermissionsEnabled ?? false)
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        try viewModel.saveClaudeAPISettings(
            functionName: "   ",
            dangerousPermissionsEnabled: false,
            key: nil
        )

        XCTAssertEqual(store.savedConfigs.last?.commands.ccapi, "")
        XCTAssertEqual(store.savedConfigs.last?.ccapi.connectionMode, .proxy)
        XCTAssertFalse(store.savedConfigs.last?.ccapi.dangerousPermissionsEnabled ?? true)
        XCTAssertEqual(installer.validatedFunctionNames, [])
    }

    func testSaveCodexSettingsNormalizesCommandNameBeforePersisting() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.saveCodexSettings(functionName: " mycodex ", nickname: "", codex: testCodex(), dangerousPermissionsEnabled: false)

        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "mycodex")
        XCTAssertEqual(viewModel.config.commands.ccodex, "mycodex")
    }

    func testSaveCodexSettingsIgnoresClaudeZshrcConflict() throws {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller(conflictingFunctionNames: ["cc"])
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()]),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(installer.validatedFunctionNames, [])
        XCTAssertEqual(installer.installedFunctionNames, ["cc", "ccd123"])
        XCTAssertTrue(installer.installedScript?.contains("ccd123() {") == true)
        XCTAssertFalse(viewModel.settingsMessage?.contains("Cannot install shell functions") == true)
    }

    func testInitialShellInstallIncludesRoundRobinFunctionWhenOnlyRoundRobinCommandExists() {
        var config = AppConfig.default
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex.json", "codex-team.json"]
            )
        ]
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                codexProfile(),
                AuthProfile(fileName: "codex-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-team")
            ]),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("routing next 'codex-default'") == true)
        XCTAssertFalse(viewModel.settingsMessage?.contains("Cannot install shell functions") == true)
    }

    func testRoundRobinSettingsAvailableForTwoEnabledCodexProfiles() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let state = viewModel.roundRobinSettings(for: .codex)

        XCTAssertEqual(state.profile.id, "codex-default")
        XCTAssertEqual(state.profile.provider, .codex)
        XCTAssertEqual(state.profile.commandName, "")
        XCTAssertEqual(state.profile.includedAuthProfileIDs, ["codex-fast.json", "codex-deep.json"])
        XCTAssertEqual(state.availability, .available(count: 2))
    }

    func testRoundRobinSettingsExcludesDirectClaudeAccountsAndMakesStoredGroupUnavailable() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "claude-proxy", provider: .claude, authProfileID: "claude-proxy.json", commandName: "ccproxy", modelPrefix: "proxy"),
            .init(id: "claude-direct", provider: .claude, authProfileID: "claude-direct.json", commandName: "ccdirect", modelPrefix: "direct", connectionMode: .direct)
        ]
        config.roundRobinProfiles = [
            .init(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-proxy.json", "claude-direct.json"])
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                .init(fileName: "claude-proxy.json", type: .claude, email: "proxy@example.com", accountID: nil, expired: nil, disabled: false, prefix: "proxy"),
                .init(fileName: "claude-direct.json", type: .claude, email: "direct@example.com", accountID: nil, expired: nil, disabled: false, prefix: "direct")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let state = viewModel.roundRobinSettings(for: .claude)

        XCTAssertEqual(state.accountOptions.map(\.id), ["claude-proxy.json"])
        XCTAssertEqual(state.availability, .insufficientProviderAccounts(count: 1))
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.id == "claude-direct" }?.connectionMode, .direct)
    }

    func testRoundRobinSettingsUnavailableForOneSelectedProfile() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: false, commandName: "ccodex", includedAuthProfileIDs: ["codex-fast.json"])
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).availability, .insufficientSelectedAccounts(count: 1))
    }

    func testRoundRobinSettingsUpdatingProfileRecomputesAvailabilityFromSelectedIDs() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, commandName: "ccodex", includedAuthProfileIDs: ["codex-fast.json"])
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        var profile = viewModel.roundRobinSettings(for: .codex).profile
        profile.includedAuthProfileIDs.append("codex-deep.json")

        XCTAssertEqual(viewModel.roundRobinSettings(updating: profile).availability, .available(count: 2))
    }

    func testRoundRobinSettingsUsesAuthPrefixWhenCommandProfilePrefixIsBlank() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: ""),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).availability, .available(count: 2))
    }

    func testRoundRobinSettingsToleratesDuplicateCommandProfilesForSameAuthProfile() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast-a", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-fast-b", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast2", modelPrefix: "codex-fast-2"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).availability, .available(count: 2))
    }

    func testRoundRobinSettingsExistingCodexProfileFallsBackToConfiguredCodexRoles() {
        var config = AppConfig.default
        config.ccodex = testCodex(model: "custom-gpt")
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, commandName: "ccodex", includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"])
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).profile.codex, config.ccodex)
    }

    func testSaveRoundRobinSettingsPersistsCodexRoleReasoningAndContextWindow() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        var state = viewModel.roundRobinSettings(for: .codex)
        state.profile.isEnabled = true
        state.profile.commandName = "ccodexrr"
        state.profile.codex = AppConfig.Codex(
            opus: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh),
            sonnet: AppConfig.CodexRole(model: "gpt-5.1", reasoning: .medium),
            haiku: AppConfig.CodexRole(model: "gpt-5-mini", reasoning: .low)
        )

        try viewModel.saveRoundRobinSettings(state)

        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles.first?.codex, state.profile.codex)
    }

    func testSaveRoundRobinSettingsPersistsProfileAndKeepsFixedCommands() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        var state = viewModel.roundRobinSettings(for: .codex)
        state.profile.isEnabled = true
        state.profile.commandName = "ccodexrr"
        state.profile.dangerousPermissionsEnabled = true

        try viewModel.saveRoundRobinSettings(state)

        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles.first?.commandName, "ccodexrr")
        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles.first?.dangerousPermissionsEnabled, true)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.commandName), ["ccfast", "ccdeep"])
    }

    func testNewRoundRobinProfileUsesBlankCommandName() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.roundRobinSettings(for: .codex).profile.commandName, "")
    }

    func testDisablingRoundRobinSettingsDeletesStoredProfile() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"]
            )
        ]
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        var state = viewModel.roundRobinSettings(for: .codex)
        state.profile.isEnabled = false

        try viewModel.saveRoundRobinSettings(state)

        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles, [])
    }

    func testSaveRoundRobinSettingsShowsSavedMessage() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", modelPrefix: "codex-deep")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        var state = viewModel.roundRobinSettings(for: .codex)
        state.profile.isEnabled = true
        state.profile.commandName = "ccodex"

        try viewModel.saveRoundRobinSettings(state)

        XCTAssertEqual(viewModel.settingsMessage, "Round-robin settings saved.")
    }

    func testSaveClaudeOAuthSettingsPersistsRoutingAndDirectModeWithoutDiscardingPolicy() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                modelPrefix: "claude-work"
            )
        ]
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let routing = ClaudeRouting(
            opus: .model("claude-opus-4-8"),
            sonnet: .automatic,
            haiku: .model("claude-haiku-4-5")
        )

        try viewModel.saveClaudeOAuthSettings(
            provider: .init(rawValue: "claude-work"),
            functionName: "ccwork",
            nickname: "Work",
            dangerousPermissionsEnabled: false,
            connectionMode: .direct,
            claudeRouting: routing
        )

        let saved = try XCTUnwrap(store.savedConfigs.last?.oauthCommandProfiles.first)
        XCTAssertEqual(saved.claude, routing)
        XCTAssertEqual(saved.connectionMode, .direct)
    }

    func testSaveClaudeOAuthSettingsPersistsFunctionNameAndPermission() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [claudeProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let codex = testCodex()

        try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "", codex: codex, dangerousPermissionsEnabled: true)

        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, "mycodex")
        XCTAssertEqual(store.savedConfigs.last?.ccodex, codex)
        XCTAssertEqual(store.savedConfigs.last?.includeDangerouslySkipPermissions, true)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "mycodex")
    }

    func testSaveClaudeOAuthSettingsRecomputesModelPrefixFromNicknameAndSyncsAuthProfilePrefix() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Old Team",
                modelPrefix: "claude-old-team"
            )
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-old-team")
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.saveClaudeOAuthSettings(
            provider: ProviderRowState.ID(rawValue: "claude-work"),
            functionName: "ccwork",
            nickname: "Work Team",
            dangerousPermissionsEnabled: false
        )

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.modelPrefix), ["claude-work-team"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["claude-work-team"])
        XCTAssertEqual(authStore.prefixUpdates, [PrefixUpdate(id: "claude-work.json", prefix: "claude-work-team")])
    }

    func testSaveCodexSettingsFallsBackToShortAuthProfilePrefixWhenNicknameIsBlankAndSyncsAuthProfilePrefix() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-team",
                provider: .codex,
                authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
                commandName: "ccteam",
                nickname: "Team",
                codex: testCodex(),
                modelPrefix: "codex-team"
            )
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-team")
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.saveCodexSettings(
            provider: ProviderRowState.ID(rawValue: "codex-team"),
            functionName: "ccteam",
            nickname: "   ",
            codex: testCodex(),
            dangerousPermissionsEnabled: false
        )

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
        XCTAssertEqual(authStore.prefixUpdates, [PrefixUpdate(id: "codex-18c2ca10-woosub-classting-com-team.json", prefix: "codex-18c2ca10")])
    }

    func testSaveClaudeOAuthSettingsPrefixSyncFailureBlocksShellInstall() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Old Team",
                modelPrefix: "claude-old-team"
            )
        ]
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(
            profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-old-team")
            ],
            setPrefixError: NSError(domain: "auth", code: 1)
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let initialConfig = viewModel.config
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(
            provider: ProviderRowState.ID(rawValue: "claude-work"),
            functionName: "ccwork",
            nickname: "Work Team",
            dangerousPermissionsEnabled: false
        ))

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(store.config, config)
        XCTAssertEqual(viewModel.config, initialConfig)
        XCTAssertEqual(authStore.prefixUpdates, [PrefixUpdate(id: "claude-work.json", prefix: "claude-work-team")])
    }

    func testSaveClaudeOAuthSettingsPartialPrefixSyncFailureRollsBackEarlierAuthProfiles() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Old Work",
                modelPrefix: "claude-old-work"
            ),
            AppConfig.OAuthCommandProfile(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal",
                nickname: "New Work",
                modelPrefix: "claude-new-work"
            )
        ]
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(
            profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-old-work"),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-new-work")
            ],
            setPrefixErrors: [nil, NSError(domain: "auth", code: 2)]
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let initialConfig = viewModel.config
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(
            provider: ProviderRowState.ID(rawValue: "claude-work"),
            functionName: "ccwork",
            nickname: "New Work",
            dangerousPermissionsEnabled: false
        ))

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(store.config, config)
        XCTAssertEqual(viewModel.config, initialConfig)
        XCTAssertEqual(authStore.prefixUpdates, [
            PrefixUpdate(id: "claude-work.json", prefix: "claude-new-work"),
            PrefixUpdate(id: "claude-personal.json", prefix: "claude-new-work-2"),
            PrefixUpdate(id: "claude-work.json", prefix: "claude-old-work")
        ])
        XCTAssertEqual(try authStore.profiles().map(\.prefix), ["claude-old-work", "claude-new-work"])
    }

    func testSaveClaudeOAuthSettingsShellInstallFailureRollsBackAuthProfilePrefix() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Old Team",
                modelPrefix: "claude-old-team"
            )
        ]
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller(installError: NSError(domain: "shell", code: 1))
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-old-team")
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let initialConfig = viewModel.config
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveClaudeOAuthSettings(
            provider: ProviderRowState.ID(rawValue: "claude-work"),
            functionName: "ccwork",
            nickname: "Work Team",
            dangerousPermissionsEnabled: false
        ))

        XCTAssertNil(installer.installedScript)
        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(store.config, config)
        XCTAssertEqual(viewModel.config, initialConfig)
        XCTAssertEqual(authStore.prefixUpdates, [
            PrefixUpdate(id: "claude-work.json", prefix: "claude-work-team"),
            PrefixUpdate(id: "claude-work.json", prefix: "claude-old-team")
        ])
        XCTAssertEqual(try authStore.profiles().first?.prefix, "claude-old-team")
    }

    func testSaveCodexSettingsDoesNotLeaveNewShellFunctionWhenPersistenceFails() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "", codex: testCodex(), dangerousPermissionsEnabled: true))

        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(installer.installedScript?.contains("mycodex() {") == true)
    }

    func testSaveCodexSettingsKeepsCurrentConfigWhenShellApplyFails() {
        let store = StubConfigStore(config: .default)
        let installer = StubShellInstaller(installError: NSError(domain: "shell", code: 1))
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let initialConfig = viewModel.config
        let codex = testCodex()
        installer.reset()

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "team", codex: codex, dangerousPermissionsEnabled: true))

        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(store.config, .default)
        XCTAssertEqual(viewModel.config, initialConfig)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "")
    }

    func testSaveCodexSettingsKeepsCurrentConfigWhenPersistenceFails() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [codexProfile()]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let initialConfig = viewModel.config
        let codex = testCodex()

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "mycodex", nickname: "", codex: codex, dangerousPermissionsEnabled: true))

        XCTAssertEqual(viewModel.config, initialConfig)
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
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
        let automaticInstaller = AutomaticShellInstallService(installer: installer)
        _ = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: authStore,
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: authStore,
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.removeProvider(.claude)

        XCTAssertEqual(installer.installedFunctionNames, ["ccodex"])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertTrue(installer.installedScript?.contains("ccodex() {") == true)
    }

    func testDisconnectProviderRewritesShellFunctionsAfterCleanup() {
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [claudeProfile(), codexProfile()])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.disconnectProvider(.claude)

        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
    }

    func testSameProviderCanHaveTwoAccountsAndCommandProfiles() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.map(\.id), [
            ProviderRowState.ID(rawValue: "claude"),
            ProviderRowState.ID(rawValue: "claude-claude-personal-json")
        ])
        XCTAssertEqual(viewModel.providerRows.map(\.authProfileID), ["claude-work.json", "claude-personal.json"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.authProfileID), ["claude-work.json", "claude-personal.json"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["claude-work", "claude-personal"])
    }

    func testReconciliationUsesNicknameBasedModelPrefixesWithDuplicateSuffixes() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                nickname: "Work",
                modelPrefix: "claude-claude-work-json"
            ),
            AppConfig.OAuthCommandProfile(
                id: "codex-team",
                provider: .codex,
                authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
                nickname: "Team",
                modelPrefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"
            ),
            AppConfig.OAuthCommandProfile(
                id: "codex-team-secondary",
                provider: .codex,
                authProfileID: "codex-dntjqdlekd-gmail-com-pro.json",
                nickname: "Team",
                modelPrefix: "codex-codex-dntjqdlekd-gmail-com-pro-json"
            )
        ]

        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-claude-work-json"),
                AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"),
                AuthProfile(fileName: "codex-dntjqdlekd-gmail-com-pro.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-dntjqdlekd-gmail-com-pro-json")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), [
            "claude-work",
            "codex-team",
            "codex-team-2"
        ])
    }

    func testBlankNicknameFallsBackToShortAuthProfileModelPrefix() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-team",
                provider: .codex,
                authProfileID: "codex-18c2ca10-woosub-classting-com-team.json",
                nickname: "   ",
                modelPrefix: "codex-codex-18c2ca10-woosub-classting-com-team-json"
            )
        ]

        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-18c2ca10-woosub-classting-com-team.json", type: .codex, email: "team@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-codex-18c2ca10-woosub-classting-com-team-json")
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.modelPrefix), ["codex-18c2ca10"])
    }

    func testRemoveExplicitCommandProfileDeletesOnlySelectedAccount() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork"),
            AppConfig.OAuthCommandProfile(id: "claude-personal", provider: .claude, authProfileID: "claude-personal.json", commandName: "ccpersonal")
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeProvider(ProviderRowState.ID(rawValue: "claude-work"))

        XCTAssertEqual(authStore.deletedIDs, ["claude-work.json"])
        XCTAssertEqual(authStore.deleteInvocations, [])
        XCTAssertEqual(viewModel.providerRows.map(\.authProfileID), ["claude-personal.json"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.authProfileID), ["claude-personal.json"])
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.authProfileID), ["claude-personal.json"])
    }

    func testRemoveExplicitCommandProfileDeletesRoundRobinWhenLessThanTwoAccountsRemain() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "ccwork", modelPrefix: "codex-work"),
            AppConfig.OAuthCommandProfile(id: "codex-personal", provider: .codex, authProfileID: "codex-personal.json", commandName: "ccpersonal", modelPrefix: "codex-personal")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-work.json", "codex-personal.json"]
            )
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
            AuthProfile(fileName: "codex-personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
        ])
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.removeProvider(ProviderRowState.ID(rawValue: "codex-work"))

        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles, [])
        XCTAssertEqual(viewModel.config.roundRobinProfiles, [])
        XCTAssertFalse(installer.installedFunctionNames.contains("ccodex"))
    }

    func testDisconnectExplicitCommandProfileDisablesOnlySelectedAccount() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork"),
            AppConfig.OAuthCommandProfile(id: "claude-personal", provider: .claude, authProfileID: "claude-personal.json", commandName: "ccpersonal")
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.disconnectProvider(ProviderRowState.ID(rawValue: "claude-work"))

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["claude-work.json"])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true])
        XCTAssertEqual(authStore.disabledUpdates, [])
        XCTAssertEqual(viewModel.providerRows.first { $0.authProfileID == "claude-work.json" }?.isConnected, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.authProfileID == "claude-personal.json" }?.isConnected, true)
    }

    func testDisconnectExplicitCommandProfilePreservesRoundRobinConfigurationForReenable() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "ccwork", modelPrefix: "codex-work"),
            AppConfig.OAuthCommandProfile(id: "codex-personal", provider: .codex, authProfileID: "codex-personal.json", commandName: "ccpersonal", modelPrefix: "codex-personal")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-work.json", "codex-personal.json"]
            )
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
            AuthProfile(fileName: "codex-personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
        ])
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.disconnectProvider(ProviderRowState.ID(rawValue: "codex-work"))

        XCTAssertEqual(store.savedConfigs.last?.roundRobinProfiles, config.roundRobinProfiles)
        XCTAssertEqual(viewModel.config.roundRobinProfiles, config.roundRobinProfiles)
        XCTAssertFalse(installer.installedFunctionNames.contains("ccodex"))
    }

    func testDormantAPICommandDoesNotBlockOAuthCommandValidationWhenKeyIsMissing() async {
        var config = AppConfig.default
        config.commands.ccapi = "shared"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let availability = await viewModel.commandNameAvailability(provider: .claude, functionName: "shared")

        XCTAssertEqual(availability, .available)
    }

    func testClaudeAPICommandNameAvailabilityChecksAgainstOAuthCommands() async {
        var config = AppConfig.default
        config.commands.cc = "claudeoauth"
        config.commands.ccapi = "claudeapi"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "secret"])
        )

        let availability = await viewModel.commandNameAvailability(provider: .claudeAPI, functionName: "claudeoauth")

        XCTAssertEqual(availability, .unavailable("Command name `claudeoauth` is already used by another provider."))
    }

    func testCodexAPICommandNameAvailabilityChecksAgainstOAuthCommands() async {
        var config = AppConfig.default
        config.commands.ccodex = "codexoauth"
        config.commands.ccodexapi = "codexapi"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(values: [.codexAPIKey: "secret"])
        )

        let availability = await viewModel.commandNameAvailability(provider: .codexAPI, functionName: "codexoauth")

        XCTAssertEqual(availability, .unavailable("Command name `codexoauth` is already used by another provider."))
    }

    func testCommandNameAvailabilityChecksAllOAuthCommandProfilesForDuplicates() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork"),
            AppConfig.OAuthCommandProfile(id: "claude-personal", provider: .claude, authProfileID: "claude-personal.json", commandName: "ccpersonal")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let availability = await viewModel.commandNameAvailability(
            provider: ProviderRowState.ID(rawValue: "claude-work"),
            functionName: "ccpersonal"
        )

        XCTAssertEqual(availability, .unavailable("Command name `ccpersonal` is already used by another provider."))
    }

    private func testCodex(model: String = "gpt-5.5") -> AppConfig.Codex {
        AppConfig.Codex(
            opus: AppConfig.CodexRole(model: model, reasoning: .xhigh),
            sonnet: AppConfig.CodexRole(model: model, reasoning: .medium),
            haiku: AppConfig.CodexRole(model: model, reasoning: .low)
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
    private let installError: Error?
    private let conflictingFunctionNames: Set<String>
    private(set) var installedScript: String?
    private(set) var installedFunctionNames: [String] = []
    private(set) var validatedFunctionNames: [[String]] = []

    init(validationError: Error? = nil, installError: Error? = nil, conflictingFunctionNames: Set<String> = []) {
        self.validationError = validationError
        self.installError = installError
        self.conflictingFunctionNames = conflictingFunctionNames
    }

    func install(functionScript: String, functionNames: [String]) throws {
        if let installError { throw installError }
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
    private let setPrefixError: Error?
    private var setPrefixErrors: [Error?]
    private(set) var disabledUpdates: [DisabledUpdate] = []
    private(set) var disabledIDUpdates: [DisabledIDUpdate] = []
    private(set) var prefixUpdates: [PrefixUpdate] = []
    private(set) var deletedIDs: [String] = []
    private(set) var deleteInvocations: [AuthProfileType] = []

    init(profiles: [AuthProfile], setPrefixError: Error? = nil, setPrefixErrors: [Error?] = []) {
        profilesValue = profiles
        self.setPrefixError = setPrefixError
        self.setPrefixErrors = setPrefixErrors
    }

    func profiles() throws -> [AuthProfile] { profilesValue }

    func setDisabled(_ disabled: Bool, id: String) throws -> Bool {
        guard let index = profilesValue.firstIndex(where: { $0.id == id }) else { return false }
        disabledIDUpdates.append(DisabledIDUpdate(id: id, disabled: disabled))
        let profile = profilesValue[index]
        profilesValue[index] = AuthProfile(
            fileName: profile.fileName,
            type: profile.type,
            email: profile.email,
            accountID: profile.accountID,
            expired: profile.expired,
            disabled: disabled,
            prefix: profile.prefix
        )
        return true
    }

    func setPrefix(_ prefix: String?, id: String) throws -> Bool {
        guard let index = profilesValue.firstIndex(where: { $0.id == id }) else { return false }
        prefixUpdates.append(PrefixUpdate(id: id, prefix: prefix))
        if let nextSetPrefixError = setPrefixErrors.isEmpty ? nil : setPrefixErrors.removeFirst() {
            throw nextSetPrefixError
        }
        if let setPrefixError { throw setPrefixError }
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
        disabledUpdates.append(DisabledUpdate(type: type, disabled: disabled))
        let matchingCount = profilesValue.filter { $0.type == type }.count
        profilesValue = profilesValue.map { profile in
            guard profile.type == type else { return profile }
            return AuthProfile(fileName: profile.fileName, type: profile.type, email: profile.email, accountID: profile.accountID, expired: profile.expired, disabled: disabled, prefix: profile.prefix)
        }
        return matchingCount
    }

    func delete(id: String) throws -> Bool {
        guard profilesValue.contains(where: { $0.id == id }) else { return false }
        deletedIDs.append(id)
        profilesValue.removeAll { $0.id == id }
        return true
    }

    func delete(for type: AuthProfileType) throws -> Int {
        deleteInvocations.append(type)
        let matchingCount = profilesValue.filter { $0.type == type }.count
        profilesValue.removeAll { $0.type == type }
        return matchingCount
    }
}

private struct DisabledUpdate: Equatable {
    let type: AuthProfileType
    let disabled: Bool
}

private struct DisabledIDUpdate: Equatable {
    let id: String
    let disabled: Bool
}

private struct PrefixUpdate: Equatable {
    let id: String
    let prefix: String?
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

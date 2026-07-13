import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class DashboardViewModelRefreshTests: XCTestCase {
    func testRefreshUpdatesClaudeAndCodexCardsByCommandAndExcludesClaudeAPICard() async {
        let config = AppConfig(
            port: 9444,
            commands: AppConfig.Commands(cc: "claude-local", ccapi: "api-local", ccodex: "codex-local"),
            ccapi: AppConfig.ClaudeAPI(),
            ccodex: AppConfig.Codex(
                opus: AppConfig.CodexRole(model: "test-opus", reasoning: .auto, contextWindow: .auto),
                sonnet: AppConfig.CodexRole(model: "test-sonnet", reasoning: .auto, contextWindow: .auto),
                haiku: AppConfig.CodexRole(model: "test-haiku", reasoning: .auto, contextWindow: .auto)
            ),
            includeDangerouslySkipPermissions: false,
            startAtLogin: false,
            showDockIcon: true,
            showMenuBarIcon: true
        )
        let serverStatus = DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI Running",
            message: "Models are available on port 9444."
        )
        let claudeStatus = DiagnosticStatus(
            severity: .ready,
            title: "Claude Code Connected",
            message: "Logged in"
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.serverStatus, serverStatus)
        XCTAssertEqual(viewModel.cards.first { $0.command == "claude-local" }?.status, claudeStatus)
        XCTAssertFalse(viewModel.cards.contains { $0.command == "api-local" })
        XCTAssertEqual(viewModel.cards.first { $0.command == "codex-local" }?.status, serverStatus)
    }

    func testRefreshUpdatesBlankCommandCardsByStableIdentity() async {
        let config = AppConfig.default
        let serverStatus = DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI Running",
            message: "Models are available on port \(config.port)."
        )
        let claudeStatus = DiagnosticStatus(
            severity: .ready,
            title: "Claude Code Connected",
            message: "Logged in"
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.cards.first { $0.id == ProfileCard.claudeID }?.status, claudeStatus)
        XCTAssertEqual(viewModel.cards.first { $0.id == ProfileCard.codexID }?.status, serverStatus)
        XCTAssertEqual(viewModel.cards.map(\.command), ["", ""])
    }

    func testTransientServerHealthErrorIsRetriedBeforeUpdatingMenuStatus() async {
        let httpClient = SequencedHTTPClient(results: [
            .failure(HTTPClientError.timedOut),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient, timeout: 0.1),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refresh()

        XCTAssertEqual(httpClient.requestCount, 2)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, false)
        XCTAssertEqual(MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows).erroredCount, 0)
    }

    func testPersistentPassiveServerHealthTimeoutDoesNotCountAsCodexProviderError() async {
        let httpClient = SequencedHTTPClient(results: [
            .failure(HTTPClientError.timedOut),
            .failure(HTTPClientError.timedOut)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient, timeout: 0.1),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refresh()

        let snapshot = MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows)
        XCTAssertEqual(httpClient.requestCount, 2)
        XCTAssertEqual(viewModel.serverStatus.severity, .warning)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, false)
        XCTAssertEqual(snapshot.erroredCount, 0)
        XCTAssertEqual(snapshot.statusLabel, "Stopped")
        XCTAssertEqual(snapshot.indicatorState, .stopped)
    }

    func testInvalidPortStillShowsMenuBarErrorAndCodexProviderError() async {
        var config = AppConfig.default
        config.port = 0
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refresh()

        let snapshot = MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows)
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "CLIProxyAPI Port Configuration Error")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, true)
        XCTAssertEqual(snapshot.statusLabel, "Error")
        XCTAssertEqual(snapshot.indicatorState, .error)
        XCTAssertEqual(snapshot.erroredCount, 1)
    }

    func testDefaultProviderRowsHideProfilesUntilAuthExists() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows, [])
    }

    func testAddProviderExplainsClaudeAPIIsHiddenFromDefaultProfiles() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.addProvider()

        XCTAssertEqual(viewModel.settingsMessage, "Claude API profiles are hidden from the default account list in this version.")
    }

    func testSettingsMessageCanBeClearedByToastTimer() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.addProvider()
        viewModel.clearSettingsMessage()

        XCTAssertNil(viewModel.settingsMessage)
    }

    func testSettingsMessageAutoClearsAfterDelay() async throws {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            settingsMessageAutoClearDelayNanoseconds: 1_000_000
        )

        viewModel.addProvider()
        XCTAssertNotNil(viewModel.settingsMessage)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(viewModel.settingsMessage)
    }

    func testUnavailableFeatureSettingsCannotBeEnabledFromConfigActions() throws {
        var config = AppConfig.default
        config.showNotifications = true
        config.roundRobinEnabled = true
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertFalse(viewModel.config.showNotifications)
        XCTAssertFalse(viewModel.config.roundRobinEnabled)

        try viewModel.saveShowNotifications(true)
        try viewModel.saveRoundRobinEnabled(true)

        XCTAssertFalse(viewModel.config.showNotifications)
        XCTAssertFalse(viewModel.config.roundRobinEnabled)
        XCTAssertEqual(store.savedConfigs.map(\.showNotifications), [false, false])
        XCTAssertEqual(store.savedConfigs.map(\.roundRobinEnabled), [false, false])
    }

    func testProviderRowsIgnoreCustomConfigUntilAuthExists() {
        var config = AppConfig.default
        config.commands.ccodex = "ccmcodex"
        config.includeDangerouslySkipPermissions = true
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows, [])
        XCTAssertFalse(viewModel.cards.contains { $0.command == "ccapi" })
    }

    func testProviderRowsUseConfiguredCommandOnlyForSavedAuthSettings() {
        var config = AppConfig.default
        config.commands.ccodex = "ccmcodex"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "ccmcodex")
    }

    func testProviderRowsShowOAuthProfileEmailsFromAppManagedAuthStore() {
        let profiles = [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: profiles),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionTitle, "Connected")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionDetail, "claude@example.com")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionTitle, "Connected")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
    }

    func testProviderRowsReflectConfiguredAccountPrivacy() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, true)
    }

    func testToggleClaudeAccountDetailVisibilityPersistsOnlyClaudePrivacy() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: false)
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.toggleAccountDetailVisibility(.claude)

        XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
        XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, false)
    }

    func testToggleCodexAccountDetailVisibilityPersistsOnlyCodexPrivacy() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true)
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.toggleAccountDetailVisibility(.codex)

        XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
        XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false))
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, false)
    }

    func testToggleAccountDetailVisibilityDoesNotInstallShellFunctions() {
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let installCountBeforeToggle = installer.installCount
        let installedBeforeToggle = installer.installedFunctionNames

        viewModel.toggleAccountDetailVisibility(.claude)

        XCTAssertEqual(installer.installCount, installCountBeforeToggle)
        XCTAssertEqual(installer.installedFunctionNames, installedBeforeToggle)
    }

    func testToggleAccountDetailVisibilityPreservesCodexProviderErrorState() async {
        var config = AppConfig.default
        config.port = 0
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, true)

        viewModel.toggleAccountDetailVisibility(.codex)

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, true)
    }

    func testToggleAccountDetailVisibilityPreservesDashboardCardStatuses() async {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .failure(HTTPClientError.timedOut)), timeout: 0.1),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        await viewModel.refresh()
        let statusBeforeToggle = viewModel.cards.first { $0.id == ProfileCard.codexID }?.status

        viewModel.toggleAccountDetailVisibility(.codex)

        XCTAssertEqual(viewModel.cards.first { $0.id == ProfileCard.codexID }?.status, statusBeforeToggle)
    }

    func testToggleAccountDetailVisibilityShowsSettingsMessageWhenSaveFails() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: true)
        let store = StubConfigStore(
            config: config,
            saveError: NSError(domain: "AccountPrivacy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed"])
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.toggleAccountDetailVisibility(.claude)

        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: true))
        XCTAssertEqual(viewModel.settingsMessage, "Account privacy update failed: Save failed")
    }

    func testFutureExpiryDoesNotMarkProviderRowAsErrored() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2099-05-14T01:45:44+09:00", disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: "2099-05-22T23:45:34+09:00", disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.isErrored, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, false)
        XCTAssertEqual(MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows).erroredCount, 0)
    }

    func testPastExpiryMarksProviderRowAsErrored() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2000-05-14T01:45:44+09:00", disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.isErrored, true)
        XCTAssertEqual(MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows).erroredCount, 1)
    }

    func testClaudeCLIMissingDoesNotCountAsOAuthProviderError() async {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 1, stdout: "", stderr: "")
            ])),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refresh()

        let claudeRow = viewModel.providerRows.first { $0.id == .claude }
        let snapshot = MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(claudeRow?.isConnected, true)
        XCTAssertEqual(claudeRow?.isErrored, false)
        XCTAssertEqual(snapshot.erroredCount, 0)
    }

    func testConnectProviderStartsBundledOAuthLoginAndRefreshesProfiles() async {
        let authStore = StubAuthProfileStore(profiles: [])
        let oauth = StubOAuthLoginService()
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]

        await viewModel.connectProvider(.codex)

        XCTAssertEqual(oauth.invocations, [.codex])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["codex.json"])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [false])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
        XCTAssertFalse(viewModel.isProfileLoginInProgress)
        XCTAssertNil(viewModel.activeOAuthLoginProvider)
        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertTrue(viewModel.completedOAuthLoginIsInitialSetup)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.map(\.authProfileID), ["codex.json"])
        XCTAssertEqual(store.config.oauthCommandProfiles.map(\.authProfileID), ["codex.json"])
    }

    func testReconnectDisabledProviderCompletesAsExistingSetup() async {
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: true)
        ])
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        await viewModel.connectProvider(.codex)

        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertFalse(viewModel.completedOAuthLoginIsInitialSetup)
    }

    func testConnectProviderDoesNotInstallShellFunctionsBeforeInitialSettingsAreSaved() async {
        let installer = StubShellInstaller(validationError: ShellProfileInstallerError.functionNameConflicts(["cc"]))
        let authStore = StubAuthProfileStore(profiles: [])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let validatedBeforeLogin = installer.validatedFunctionNames
        authStore.nextProfiles = [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ]

        await viewModel.connectProvider(.claude)

        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .claude)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionDetail, "claude@example.com")
        XCTAssertEqual(installer.validatedFunctionNames, validatedBeforeLogin)
        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(viewModel.settingsMessage?.contains("Cannot install shell functions") == true)
    }

    func testStartOAuthLoginTracksProviderUntilCompletion() async throws {
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.startOAuthLogin(.claude)
        await oauth.waitUntilStarted()

        XCTAssertEqual(viewModel.activeOAuthLoginProvider, .claude)
        XCTAssertTrue(viewModel.isProfileLoginInProgress)

        oauth.complete()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(viewModel.activeOAuthLoginProvider)
        XCTAssertFalse(viewModel.isProfileLoginInProgress)
        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .claude)
    }

    func testStartOAuthLoginUsesCodexForCustomCodexCommandProfileID() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "ccwork"
            )
        ]
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.startOAuthLogin(ProviderRowState.ID(rawValue: "codex-work"))
        await oauth.waitUntilStarted()

        XCTAssertEqual(oauth.providers, [.codex])
        XCTAssertEqual(viewModel.activeOAuthLoginProvider, .codex)

        oauth.complete()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testCancelOAuthLoginCancelsActiveProviderLogin() async throws {
        let authStore = StubAuthProfileStore(profiles: [])
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.startOAuthLogin(.codex)
        await oauth.waitUntilStarted()
        viewModel.cancelOAuthLogin()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(oauth.wasCancelled)
        XCTAssertNil(viewModel.activeOAuthLoginProvider)
        XCTAssertNil(viewModel.completedOAuthLoginProvider)
        XCTAssertFalse(viewModel.isProfileLoginInProgress)
        XCTAssertEqual(authStore.disabledUpdates, [])
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth login was cancelled.")
    }

    func testDirectConnectProviderDoesNotReenterActiveOAuthLoginForSameProvider() async throws {
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.startOAuthLogin(.claude)
        await oauth.waitUntilStarted()
        let duplicateLogin = Task { await viewModel.connectProvider(.claude) }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(oauth.invocationCount, 1)

        duplicateLogin.cancel()
        viewModel.cancelOAuthLogin()
        oauth.complete()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testCancelledOAuthSessionCannotClearNewRetryState() async throws {
        let oauth = DeferredCancellationOAuthLoginService()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.startOAuthLogin(.claude)
        await oauth.waitForInvocationCount(1)
        viewModel.cancelOAuthLogin()
        viewModel.startOAuthLogin(.codex)
        await oauth.waitForInvocationCount(2)

        oauth.releaseInvocation(at: 0)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.activeOAuthLoginProvider, .codex)
        XCTAssertTrue(viewModel.isProfileLoginInProgress)
        XCTAssertNil(viewModel.completedOAuthLoginProvider)

        oauth.releaseInvocation(at: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testRemoveInitialProviderDeletesAuthWithoutShowingRemovalMessage() {
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeInitialProvider(.claude)

        XCTAssertEqual(authStore.deleteInvocations, [.claude])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testRemoveExplicitCommandProfileDoesNotFallbackToProviderWideDeleteWhenIDDeleteFails() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork"
            ),
            AppConfig.OAuthCommandProfile(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeProvider(ProviderRowState.ID(rawValue: "claude-work"))

        XCTAssertEqual(authStore.deleteInvocations, [])
        XCTAssertEqual(viewModel.providerRows.map(\.authProfileID), ["claude-work.json", "claude-personal.json"])
        XCTAssertEqual(viewModel.settingsMessage, "Claude OAuth auth file was not found.")
    }

    func testRemoveCustomCodexCommandProfileUsesCodexProviderType() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "ccwork"
            )
        ]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(
            profiles: [
                AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false)
            ],
            supportsIDDelete: true
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeProvider(ProviderRowState.ID(rawValue: "codex-work"))

        XCTAssertEqual(authStore.deletedIDs, ["codex-work.json"])
        XCTAssertEqual(authStore.deleteInvocations, [])
        XCTAssertEqual(store.savedConfigs.last?.commands.cc, AppConfig.default.commands.cc)
        XCTAssertEqual(store.savedConfigs.last?.commands.ccodex, AppConfig.default.commands.ccodex)
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth account was removed.")
    }

    func testDisconnectCustomCodexCommandProfileUsesCodexProviderType() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "ccwork"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.disconnectProvider(ProviderRowState.ID(rawValue: "codex-work"))

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["codex-work.json"])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true])
        XCTAssertEqual(authStore.disabledUpdates, [])
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth account was disabled. The auth file was not deleted.")
    }

    func testRemoveProviderResetsOnlyRemovedClaudeAccountPrivacy() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false)
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeProvider(.claude)

        XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: false))
        XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: true, codexHidden: false))
    }

    func testRemoveProviderResetsOnlyRemovedCodexAccountPrivacy() {
        var config = AppConfig.default
        config.accountPrivacy = AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: false)
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.removeProvider(.codex)

        XCTAssertEqual(store.savedConfigs.last?.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true))
        XCTAssertEqual(viewModel.config.accountPrivacy, AppConfig.AccountPrivacy(claudeHidden: false, codexHidden: true))
    }

    func testExpiredProviderRowIsErrored() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.isErrored, true)
    }

    func testDisabledExpiredProviderRowIsNotErrored() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: true)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.isErrored, false)
        XCTAssertEqual(MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows).erroredCount, 0)
    }

    func testDisconnectExplicitCommandProfileDoesNotFallbackToProviderWideDisableWhenIDDisableFails() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork"
            ),
            AppConfig.OAuthCommandProfile(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.disconnectProvider(ProviderRowState.ID(rawValue: "claude-work"))

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["claude-work.json"])
        XCTAssertEqual(authStore.disabledUpdates, [])
        XCTAssertEqual(viewModel.providerRows.map(\.authProfileID), ["claude-work.json", "claude-personal.json"])
        XCTAssertEqual(viewModel.settingsMessage, "Claude OAuth account was disabled. The auth file was not deleted.")
    }

    func testDisconnectProviderDisablesAuthProfileAndRefreshesRows() {
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: true)
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.disconnectProvider(.codex)

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["codex.json"])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true])
        XCTAssertEqual(authStore.disabledUpdates, [])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionTitle, "Disabled")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isConnected, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isDisabled, true)
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth account was disabled. The auth file was not deleted.")
    }

    func testSetProviderEnabledPreservesSelectedAccountAndRoundRobinConfiguration() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Work",
                accountDetailHidden: false,
                dangerousPermissionsEnabled: true,
                modelPrefix: "work"
            ),
            AppConfig.OAuthCommandProfile(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal",
                nickname: "Personal",
                modelPrefix: "personal"
            )
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "claude-round-robin",
                provider: .claude,
                isEnabled: true,
                commandName: "ccrr",
                includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"]
            )
        ]
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "work"),
            AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "personal")
        ])
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.setProviderEnabled(ProviderRowState.ID(rawValue: "claude-work"), enabled: false)

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.id), ["claude-work.json"])
        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true])
        let disabledConfig = try! XCTUnwrap(store.savedConfigs.last)
        XCTAssertEqual(disabledConfig.oauthCommandProfiles.first { $0.id == "claude-work" }?.isEnabled, false)
        XCTAssertEqual(disabledConfig.oauthCommandProfiles.first { $0.id == "claude-work" }?.nickname, "Work")
        XCTAssertEqual(disabledConfig.oauthCommandProfiles.first { $0.id == "claude-work" }?.accountDetailHidden, false)
        XCTAssertEqual(disabledConfig.oauthCommandProfiles.first { $0.id == "claude-work" }?.dangerousPermissionsEnabled, true)
        XCTAssertEqual(disabledConfig.oauthCommandProfiles.first { $0.id == "claude-personal" }?.isEnabled, true)
        XCTAssertEqual(disabledConfig.roundRobinProfiles, config.roundRobinProfiles)
        XCTAssertEqual(viewModel.providerRows.first { $0.id.rawValue == "claude-work" }?.connectionTitle, "Disabled")
        XCTAssertTrue(viewModel.providerRows.first { $0.id.rawValue == "claude-work" }?.isDisabled == true)
        XCTAssertFalse(viewModel.providerRows.first { $0.id.rawValue == "claude-work" }?.isConnected == true)
        XCTAssertEqual(installer.installedFunctionNames, ["ccpersonal"])

        viewModel.setProviderEnabled(ProviderRowState.ID(rawValue: "claude-work"), enabled: true)

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true, false])
        let enabledConfig = try! XCTUnwrap(store.savedConfigs.last)
        XCTAssertEqual(enabledConfig.oauthCommandProfiles.first { $0.id == "claude-work" }?.isEnabled, true)
        XCTAssertEqual(enabledConfig.roundRobinProfiles, config.roundRobinProfiles)
        XCTAssertTrue(viewModel.providerRows.first { $0.id.rawValue == "claude-work" }?.isConnected == true)
        XCTAssertFalse(viewModel.providerRows.first { $0.id.rawValue == "claude-work" }?.isDisabled == true)
        XCTAssertEqual(installer.installedFunctionNames, ["ccwork", "ccpersonal", "ccrr"])
    }

    func testSetProviderEnabledRollsBackAuthProfileWhenConfigSaveFails() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config, saveError: NSError(domain: "test", code: 1)),
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        viewModel.setProviderEnabled(ProviderRowState.ID(rawValue: "claude-work"), enabled: false)

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true, false])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.isEnabled, true)
        XCTAssertTrue(viewModel.providerRows.first?.isConnected == true)
        XCTAssertFalse(viewModel.providerRows.first?.isDisabled == true)
        XCTAssertEqual(installer.installedFunctionNames, ["ccwork"])
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Claude OAuth account disable failed:") == true)
    }

    func testSetProviderEnabledRollsBackAuthProfileWhenShellInstallFails() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false)
        ])
        let installer = StubShellInstaller(installError: NSError(domain: "test", code: 2))
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.setProviderEnabled(ProviderRowState.ID(rawValue: "claude-work"), enabled: false)

        XCTAssertEqual(authStore.disabledIDUpdates.map(\.disabled), [true, false])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.isEnabled, true)
        XCTAssertTrue(viewModel.providerRows.first?.isConnected == true)
        XCTAssertFalse(viewModel.providerRows.first?.isDisabled == true)
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Claude OAuth account disable failed:") == true)
    }

    func testSavePortPersistsConfigAndRefreshesOptionRows() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.savePort(18_888)

        XCTAssertEqual(store.savedConfigs.last?.port, 18_888)
        XCTAssertEqual(viewModel.config.port, 18_888)
        XCTAssertTrue(viewModel.optionRows.contains { $0.title == "Port" && $0.value == "18888" })
    }

    func testSaveSettingReturnsFalseWhenPortSaveFails() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let didSave = viewModel.saveSetting { try viewModel.savePort(18_888) }

        XCTAssertFalse(didSave)
        XCTAssertEqual(viewModel.config.port, AppConfig.default.port)
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testInstallShellFunctionsRendersAndInstallsCurrentConfig() throws {
        var config = AppConfig.default
        config.commands.cc = "cc"
        config.commands.ccodex = "customcodex"
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.installShellFunctions(helperCommand: "/usr/local/bin/cliproxy-manager")

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "customcodex"])
        XCTAssertTrue(installer.installedScript?.contains("customcodex() {") == true)
    }

    func testInstallShellFunctionsInstallsActiveProvidersOnly() throws {
        var config = AppConfig.default
        config.commands.cc = "cc"
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        try viewModel.installShellFunctions(helperCommand: "/Applications/CLI Proxy/cliproxy-manager")

        XCTAssertEqual(installer.installedFunctionNames, ["cc"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testInstallShellFunctionsSkipsConnectedProvidersWithBlankCommandNames() throws {
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        installer.reset()

        try viewModel.installShellFunctions(helperCommand: "/usr/local/bin/cliproxy-manager")

        XCTAssertEqual(installer.installedFunctionNames, [])
        XCTAssertFalse(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testAPIKeyChangeDuringServerStartQueuesRestartAfterStartCompletes() async throws {
        var config = AppConfig.default
        config.commands.ccapi = "ccapi"
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        try await Task.sleep(nanoseconds: 10_000_000)
        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        await startTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testCodexAPIModelsUseFixedAPIKeyRoutingPrefix() async throws {
        let expected = [
            CodexModelOption(
                id: "gpt-5.6-sol",
                supportedReasoning: [.low, .medium, .high, .xhigh, .max],
                defaultReasoning: .low
            )
        ]
        let modelClient = StubProxyModelClient(optionsByPrefix: ["cpm-codex-api": expected])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let models = try await viewModel.codexAPIModels()

        XCTAssertEqual(models, expected)
        XCTAssertEqual(modelClient.prefixRequests.map(\.prefix), ["cpm-codex-api"])
    }

    func testPrepareClaudeModelsDoesNotMutateCodexLoadingStateOrModels() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                modelPrefix: "claude-work"
            )
        ]
        let modelClient = StubProxyModelClient(claudeOptionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(
                    fileName: "claude-work.json",
                    type: .claude,
                    email: "work@example.com",
                    accountID: nil,
                    expired: nil,
                    disabled: false,
                    prefix: "claude-work"
                )
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            claudeModelOptionsCache: EmptyClaudeModelOptionsCache(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.prepareClaudeModels(for: .init(rawValue: "claude-work"))

        XCTAssertEqual(viewModel.codexModelLoadingState, .idle)
        XCTAssertEqual(viewModel.availableCodexModelOptions, [])
        XCTAssertEqual(modelClient.codexBaseModelsCallCount, 0)
        XCTAssertEqual(modelClient.claudePrefixRequests.map(\.prefix), ["claude-work"])
    }

    func testPrepareClaudeModelsSkipsDuplicateStartAndModelLookupDuringServerAction() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                modelPrefix: "claude-work"
            )
        ]
        let modelClient = StubProxyModelClient(claudeOptionsByPrefix: [
            "claude-work": [.init(id: "claude-opus-4-8")]
        ])
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-work")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            claudeModelOptionsCache: EmptyClaudeModelOptionsCache(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        for _ in 0..<20 {
            if viewModel.isServerActionInProgress { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await viewModel.prepareClaudeModels(for: .init(rawValue: "claude-work"))
        await startTask.value

        XCTAssertEqual(proxyService.ports, [viewModel.config.port])
        XCTAssertEqual(modelClient.claudePrefixRequests, [])
    }

    func testRefreshCodexModelsStartsServerAndFetchesModels() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5", "gpt-5.6"])
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.refreshCodexModels()

        XCTAssertEqual(proxyService.ports, [viewModel.config.port])
        XCTAssertEqual(modelClient.ports, [viewModel.config.port])
        XCTAssertEqual(modelClient.baseModelsCallCount, 0)
        XCTAssertEqual(modelClient.codexBaseModelsCallCount, 1)
        XCTAssertEqual(viewModel.availableCodexModels, ["gpt-5.5", "gpt-5.6"])
        XCTAssertEqual(viewModel.codexModelLoadingState, .idle)
    }

    func testRefreshCodexModelsShowsInlineStatusWhileStartingServer() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5"])
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let task = Task { await viewModel.refreshCodexModels() }
        await Task.yield()

        XCTAssertEqual(viewModel.codexModelLoadingState, .startingServer)

        await task.value
    }

    func testRefreshCodexModelsMarksServerActionInProgressWhileStarting() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5"])
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let task = Task { await viewModel.refreshCodexModels() }
        for _ in 0..<20 {
            if viewModel.isServerActionInProgress { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(viewModel.isServerActionInProgress)

        await task.value
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testRefreshCodexModelsIgnoresConcurrentRefreshRequests() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5"])
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let firstRefresh = Task { await viewModel.refreshCodexModels() }
        await Task.yield()
        await viewModel.refreshCodexModels()
        await firstRefresh.value

        XCTAssertEqual(proxyService.ports, [viewModel.config.port])
        XCTAssertEqual(modelClient.ports, [viewModel.config.port])
    }

    func testRefreshCodexModelsDoesNotStartServerDuringLifecycleAction() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5"])
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        await Task.yield()
        await viewModel.refreshCodexModels()
        await startTask.value

        XCTAssertEqual(proxyService.ports, [viewModel.config.port])
        XCTAssertEqual(modelClient.ports, [])
        XCTAssertEqual(viewModel.codexModelLoadingState, .idle)
    }

    func testLoadCodexModelsFetchesBaseModelsFromCurrentPort() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5", "gpt-5.6"])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        await viewModel.loadCodexModels()

        XCTAssertEqual(modelClient.ports, [viewModel.config.port])
        XCTAssertEqual(viewModel.availableCodexModels, ["gpt-5.5", "gpt-5.6"])
    }

    func testPreferredCodexDefaultModelUsesTerraThenFirstScopedModel() {
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: StubProxyModelClient(models: []),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(
            viewModel.preferredCodexDefaultModel(in: [
                CodexModelOption(id: "gpt-5.6-sol"),
                CodexModelOption(id: "gpt-5.6-terra"),
                CodexModelOption(id: "gpt-5.5")
            ]),
            "gpt-5.6-terra"
        )
        XCTAssertEqual(
            viewModel.preferredCodexDefaultModel(in: [CodexModelOption(id: "gpt-5.5")]),
            "gpt-5.5"
        )
    }

    func testCodexModelsForProviderPreserveOAuthReasoningMetadata() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work")
        ]
        let expected = [
            CodexModelOption(
                id: "gpt-5.6-terra",
                supportedReasoning: [.low, .medium, .high, .xhigh, .max],
                defaultReasoning: .medium
            )
        ]
        let modelClient = StubProxyModelClient(optionsByPrefix: ["codex-work": expected])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let models = try await viewModel.codexModels(for: .init(rawValue: "codex-work"))

        XCTAssertEqual(models, expected)
    }

    func testClaudeModelsForProviderUseOnlyThatCommandProfilePrefix() async throws {
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
        let modelClient = StubProxyModelClient(claudeOptionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let options = try await viewModel.claudeModels(for: .init(rawValue: "claude-work"))

        XCTAssertEqual(options.map(\.id), ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"])
        XCTAssertEqual(modelClient.claudePrefixRequests, [PrefixModelRequest(port: config.port, prefix: "claude-work")])
    }

    func testRoundRobinCodexModelsIntersectModelsAndReasoningCapabilities() async throws {
        let modelClient = StubProxyModelClient(optionsByPrefix: [
            "codex-work": [
                CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low),
                CodexModelOption(id: "gpt-5.5", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
            ],
            "codex-personal": [
                CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
            ]
        ])
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work"),
            .init(id: "personal", provider: .codex, authProfileID: "personal.json", modelPrefix: "codex-personal")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
                AuthProfile(fileName: "personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let profile = AppConfig.RoundRobinProfile(
            id: "codex-round-robin",
            provider: .codex,
            includedAuthProfileIDs: ["work.json", "personal.json"]
        )

        let models = try await viewModel.codexModels(forRoundRobinProfile: profile)

        XCTAssertEqual(models, [
            CodexModelOption(
                id: "gpt-5.6-sol",
                supportedReasoning: [.low, .medium, .high, .xhigh],
                defaultReasoning: .medium
            )
        ])
    }

    func testRoundRobinCodexModelsKeepFirstDuplicateInsteadOfCrashing() async throws {
        let first = CodexModelOption(id: "gpt-5.6", supportedReasoning: [.low, .high], defaultReasoning: .high)
        let duplicate = CodexModelOption(id: "gpt-5.6", supportedReasoning: [.low], defaultReasoning: .low)
        let modelClient = StubProxyModelClient(optionsByPrefix: [
            "codex-work": [first],
            "codex-personal": [first, duplicate]
        ])
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work"),
            .init(id: "personal", provider: .codex, authProfileID: "personal.json", modelPrefix: "codex-personal")
        ]
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "work.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
                AuthProfile(fileName: "personal.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let profile = AppConfig.RoundRobinProfile(
            id: "codex-round-robin",
            provider: .codex,
            includedAuthProfileIDs: ["work.json", "personal.json"]
        )

        let models = try await viewModel.codexModels(forRoundRobinProfile: profile)

        XCTAssertEqual(models, [first])
    }

    func testCodexModelsForProviderUsesCommandProfileModelPrefix() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "ccwork", modelPrefix: "codex-work"),
            AppConfig.OAuthCommandProfile(id: "codex-personal", provider: .codex, authProfileID: "codex-personal.json", commandName: "ccpersonal", modelPrefix: "codex-personal")
        ]
        let modelClient = StubProxyModelClient(modelsByPrefix: [
            "codex-work": ["gpt-5.6"],
            "codex-personal": ["gpt-5.5"]
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
                AuthProfile(fileName: "codex-personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        let models = try await viewModel.codexModels(for: ProviderRowState.ID(rawValue: "codex-work"))

        XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.6")])
        XCTAssertEqual(modelClient.prefixRequests, [PrefixModelRequest(port: viewModel.config.port, prefix: "codex-work")])
    }

    func testCodexModelsForRoundRobinProfileUsesCommonModelsAcrossSelectedAccounts() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "ccwork", modelPrefix: "codex-work"),
            AppConfig.OAuthCommandProfile(id: "codex-personal", provider: .codex, authProfileID: "codex-personal.json", commandName: "ccpersonal", modelPrefix: "codex-personal")
        ]
        let modelClient = StubProxyModelClient(modelsByPrefix: [
            "codex-work": ["gpt-5.6", "gpt-5.5"],
            "codex-personal": ["gpt-5.5"]
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex-work.json", type: .codex, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-work"),
                AuthProfile(fileName: "codex-personal.json", type: .codex, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-personal")
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let profile = AppConfig.RoundRobinProfile(
            id: "codex-default",
            provider: .codex,
            isEnabled: true,
            commandName: "ccodex",
            includedAuthProfileIDs: ["codex-work.json", "codex-personal.json"]
        )

        let models = try await viewModel.codexModels(forRoundRobinProfile: profile)

        XCTAssertEqual(models, [CodexModelOption(id: "gpt-5.5")])
        XCTAssertEqual(modelClient.prefixRequests, [
            PrefixModelRequest(port: viewModel.config.port, prefix: "codex-work"),
            PrefixModelRequest(port: viewModel.config.port, prefix: "codex-personal")
        ])
    }

    func testLatestBaseCodexModelUsesFirstScopedModelWhenTerraIsUnavailable() async {
        let modelClient = StubProxyModelClient(models: ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo"])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        await viewModel.loadCodexModels()

        XCTAssertEqual(viewModel.latestBaseCodexModel, "gpt-4o-mini")
    }

    func testSetServerEnabledStartsAndStopsServer() async {
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.setServerEnabled(true)
        await viewModel.setServerEnabled(false)

        XCTAssertEqual(proxyService.ports, [viewModel.config.port])
        XCTAssertEqual(proxyService.stopCount, 1)
    }

    func testServerToggleEntersStartingStateImmediately() async {
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let task = Task { await viewModel.setServerEnabled(true) }
        await Task.yield()

        XCTAssertEqual(viewModel.serverControlState, .starting)

        await task.value
        XCTAssertEqual(viewModel.serverControlState, .running)
    }

    func testServerToggleEntersStoppingStateImmediately() async {
        let proxyService = StubProxyServiceStarter(stopDelayNanoseconds: 50_000_000)
        let httpClient = SequencedHTTPClient(results: [
            .success(Data("{}".utf8)),
            .failure(URLError(.cannotConnectToHost))
        ])
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient, timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        await viewModel.refresh()

        let task = Task { await viewModel.setServerEnabled(false) }
        await Task.yield()

        XCTAssertEqual(viewModel.serverControlState, .stopping)

        await task.value
        XCTAssertEqual(viewModel.serverControlState, .stopped)
    }

    func testStartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testStartServerRetriesStatusUntilServerBecomesReady() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ])),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(httpClient.requestCount, 2)
        XCTAssertEqual(viewModel.serverStatus.severity, DiagnosticSeverity.ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, DiagnosticSeverity.ready)
    }

    func testStopServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.stopServer()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testRestartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.restartServer()

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testRestartServerRetriesStatusUntilServerBecomesReady() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ])),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.restartServer()

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(httpClient.requestCount, 2)
        XCTAssertEqual(viewModel.serverStatus.severity, DiagnosticSeverity.ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, DiagnosticSeverity.ready)
    }

    func testStartServerFailureUpdatesServerAndCodexCardStatus() async {
        var config = AppConfig.default
        config.commands.ccodex = "ccodex"
        let proxyService = StubProxyServiceStarter(error: ProxyServiceError.missingBinary("test"))
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: []))
        )

        await viewModel.startServer()

        let snapshot = MenuBarStatusSnapshot(serverStatus: viewModel.serverStatus, providers: viewModel.providerRows)
        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "Failed to start CLIProxyAPI")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isErrored, true)
        XCTAssertEqual(snapshot.statusLabel, "Error")
        XCTAssertEqual(snapshot.indicatorState, .error)
        XCTAssertEqual(snapshot.erroredCount, 1)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .error)
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testLifecycleActionInProgressPreventsOverlappingActions() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        viewModel.isServerActionInProgress = true
        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [])
        XCTAssertTrue(viewModel.isServerActionInProgress)
    }

    func testEnablingSubscriptionUsageCreatesMissingKeyPersistsConfigAndRestartsReadyProxy() async throws {
        let config = AppConfig.default
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        try viewModel.saveSubscriptionUsageEnabled(true)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertTrue(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? false)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testEnablingSubscriptionUsagePreservesExistingManagementKey() async throws {
        let config = AppConfig.default
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        try viewModel.saveSubscriptionUsageEnabled(true)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertTrue(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? false)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testDisablingSubscriptionUsageDeletesKeyPersistsDisabledConfigAndRestartsProxy() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        try viewModel.saveSubscriptionUsageEnabled(false)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? true)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails() {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(
                config: config,
                saveError: NSError(domain: "SubscriptionUsage", code: 1)
            ),
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(false))

        XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 0)
    }

    func testResetAllSettingsPreservesIndependentCodexAPISettings() {
        var config = AppConfig.default
        config.codexAPI = .init(
            codex: AppConfig.Codex(
                opus: .init(model: "gpt-5.6", reasoning: .xhigh, contextWindow: .context1m),
                sonnet: .init(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
                haiku: .init(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
            ),
            nickname: "OpenAI Work",
            dangerousPermissionsEnabled: true
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        viewModel.resetAllSettings()

        XCTAssertEqual(viewModel.config.codexAPI, config.codexAPI)
    }

    func testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails() {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(
                config: config,
                saveError: NSError(domain: "SubscriptionUsage", code: 1)
            ),
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        viewModel.resetAllSettings()

        XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Reset failed:") == true)
    }

    func testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails() {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        keyStore.deleteError = NSError(domain: "SubscriptionUsage", code: 2)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(false))

        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? true)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 1)
    }

    func testStartApplicationRefreshesUsageWhenProxyIsAlreadyReadyWithoutDashboard() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )

        await viewModel.startApplication()

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCallCount, 1)
    }

    func testPrepareSubscriptionUsageRepairsEnabledConfigWithMissingKeyBeforeFirstRefresh() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        await viewModel.prepareSubscriptionUsage()
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertTrue(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testPrepareSubscriptionUsageRemovesStaleKeyAndRestartsReadyProxyWhenUsageIsDisabled() async {
        let config = AppConfig.default
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        await viewModel.prepareSubscriptionUsage()

        XCTAssertEqual(keyStore.createCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testResetAllSettingsDeletesManagementKeyWhenUsageWasEnabled() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        viewModel.resetAllSettings()
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? true)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.settingsMessage, "Settings reset to defaults.")
    }

    func testKeyCreationFailureLeavesSubscriptionUsageDisabled() {
        let config = AppConfig.default
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble()
        keyStore.createError = NSError(domain: "SubscriptionUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Key setup failed"])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertTrue(configStore.savedConfigs.isEmpty)
    }

    func testSubscriptionUsageConfigSaveFailureDeletesOnlyNewlyCreatedKey() {
        let config = AppConfig.default
        let configStore = StubConfigStore(config: config, saveError: NSError(domain: "SubscriptionUsage", code: 1))
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
    }

    func testSubscriptionUsageConfigSaveFailurePreservesPreexistingKey() {
        let config = AppConfig.default
        let configStore = StubConfigStore(config: config, saveError: NSError(domain: "SubscriptionUsage", code: 1))
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter()
        )

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageEnabled(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
    }

    func testRestartFailureKeepsDisabledUsageConfigAndDeletedKey() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxyService = StubProxyServiceStarter(error: NSError(domain: "SubscriptionUsage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Restart failed"]))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        try viewModel.saveSubscriptionUsageEnabled(false)
        await waitForRestart(proxyService)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.config.subscriptionUsage.isEnabled)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.isEnabled ?? true)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertEqual(viewModel.serverStatus.title, "Failed to restart CLIProxyAPI")
    }

    func testMenuRefreshDoesNotStartSubscriptionUsageFetch() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )

        await viewModel.refresh()

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCallCount, 0)
    }

    func testRefreshAfterServerStopsMarksUsageStaleRetriesAndRecovers() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let initialUsage = availableUsageState(for: profile)
        let initialSnapshot = try! XCTUnwrap(initialUsage.snapshot)
        let recoveredUsage = AccountSubscriptionUsageState.available(
            SubscriptionUsageSnapshot(
                profileID: profile.id,
                provider: profile.type,
                windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 120)
            )
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialUsage], fetchedAt: Date(timeIntervalSince1970: 0)),
            SubscriptionUsageReport(statesByProfileID: [profile.id: .unavailable(.proxyUnavailable)], fetchedAt: Date(timeIntervalSince1970: 60)),
            SubscriptionUsageReport(statesByProfileID: [profile.id: recoveredUsage], fetchedAt: Date(timeIntervalSince1970: 120))
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let stoppedHealthClient = ProxyHealthClient(
            httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [profile]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: stoppedHealthClient,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()
        await viewModel.refreshSubscriptionUsage()

        await viewModel.refresh()
        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(initialSnapshot, .proxyUnavailable))
        let fetchCallCountAfterFailure = await quotaClient.fetchCallCount()
        let delaysAfterFailure = await sleeper.delays()
        XCTAssertEqual(fetchCallCountAfterFailure, 2)
        XCTAssertEqual(delaysAfterFailure, [300_000_000_000, 60_000_000_000])
        XCTAssertFalse(viewModel.canRefreshSubscriptionUsage)

        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], recoveredUsage)
        let fetchCallCountAfterRecovery = await quotaClient.fetchCallCount()
        let delaysAfterRecovery = await sleeper.delays()
        XCTAssertEqual(fetchCallCountAfterRecovery, 3)
        XCTAssertEqual(delaysAfterRecovery, [300_000_000_000, 60_000_000_000, 300_000_000_000])
    }

    func testStartingReadyProxyStartsInitialSubscriptionUsageFetch() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )

        await viewModel.startServer()

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCallCount, 1)
    }

    func testForcedSubscriptionUsageRefreshRunsAfterInFlightRefresh() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        let firstRefresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        let secondRefresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await Task.yield()

        let fetchesBeforeFirstResolution = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchesBeforeFirstResolution, 1)

        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await firstRefresh.value
        await secondRefresh.value

        let totalFetches = await quotaClient.fetchCallCount()
        XCTAssertEqual(totalFetches, 2)
    }

    func testAutomaticUsageRefreshKeepsExistingUsageUntilSuccessfulReplacement() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let refreshedState: AccountSubscriptionUsageState = .available(
            SubscriptionUsageSnapshot(
                profileID: profile.id,
                provider: .claude,
                windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 30, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 60)
            )
        )
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], initialState)

        await quotaClient.resolveAll(with: SubscriptionUsageReport(
            statesByProfileID: [profile.id: refreshedState],
            fetchedAt: Date(timeIntervalSince1970: 60)
        ))
        await refresh.value

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], refreshedState)
    }

    func testRemovingExplicitAccountDuringUsageRefreshCannotRestoreStateOrCache() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork"
            )
        ]
        let profile = AuthProfile(
            fileName: "claude-work.json",
            type: .claude,
            email: "work@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let initialState = availableUsageState(for: profile)
        let snapshot = try! XCTUnwrap(initialState.snapshot)
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [
            .init(statesByProfileID: [profile.id: initialState], fetchedAt: snapshot.fetchedAt)
        ])
        let cache = SubscriptionUsageSnapshotCacheDouble()
        let authStore = StubAuthProfileStore(profiles: [profile], supportsIDDelete: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            authProfileStore: authStore,
            quotaClient: quotaClient,
            subscriptionUsageSnapshotCache: cache
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        XCTAssertEqual(cache.load(), [profile.id: snapshot])

        let refresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        viewModel.removeProvider(ProviderRowState.ID(rawValue: "claude-work"))
        await quotaClient.resolveAll(with: .init(
            statesByProfileID: [profile.id: .unavailable(.transientFailure)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        ))
        await refresh.value

        XCTAssertNil(viewModel.subscriptionUsageStates[profile.id])
        XCTAssertNil(cache.load()[profile.id])
    }

    func testRemovingAccountDuringColdAutomaticRefreshImmediatelyRestartsRemainingAccount() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex-work.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: claude.id, commandName: "ccwork"),
            .init(id: "codex-work", provider: .codex, authProfileID: codex.id, commandName: "codexwork")
        ]
        let authStore = StubAuthProfileStore(profiles: [claude, codex], supportsIDDelete: true)
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            authProfileStore: authStore,
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        viewModel.removeProvider(.init(rawValue: "claude-work"))
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .loading)

        await quotaClient.resolveAll(with: availableUsageReport(for: codex))
        await refresh.value
        await waitForUsageState(viewModel, profileID: codex.id, expected: availableUsageState(for: codex))

        XCTAssertNil(viewModel.subscriptionUsageStates[claude.id])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], availableUsageState(for: codex))
    }

    func testNotFoundRemovalDuringUsageRefreshImmediatelyRestartsCurrentAccount() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: profile.id, commandName: "ccwork")
        ]
        let authStore = StubAuthProfileStore(profiles: [profile], supportsIDDelete: false)
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            authProfileStore: authStore,
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        viewModel.removeProvider(.init(rawValue: "claude-work"))
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[profile.id], [profile.id]])
        XCTAssertEqual(viewModel.settingsMessage, "Claude OAuth auth file was not found.")

        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await refresh.value
        await waitForUsageState(viewModel, profileID: profile.id, expected: availableUsageState(for: profile))
    }

    func testQueuedForcedUsageRefreshSurvivesRemovalAndIncludesRemainingTerminalProfile() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex-work.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: claude.id, commandName: "ccwork"),
            .init(id: "codex-work", provider: .codex, authProfileID: codex.id, commandName: "codexwork")
        ]
        let initialReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: .unavailable(.credentialExpired)
            ],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let authStore = StubAuthProfileStore(profiles: [claude, codex], supportsIDDelete: true)
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [initialReport])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            authProfileStore: authStore,
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let automaticRefresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        await viewModel.refreshSubscriptionUsage(force: true)
        viewModel.removeProvider(.init(rawValue: "claude-work"))
        await waitForUsageFetches(quotaClient, expectedCount: 3)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [claude.id], [codex.id]])

        await quotaClient.resolveAll(with: availableUsageReport(for: codex))
        await automaticRefresh.value
        await waitForUsageState(viewModel, profileID: codex.id, expected: availableUsageState(for: codex))
        XCTAssertNil(viewModel.subscriptionUsageStates[claude.id])
    }

    func testActiveForcedUsageRefreshRemovalRestartsWithForceForRemainingTerminalProfile() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex-work.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: claude.id, commandName: "ccwork"),
            .init(id: "codex-work", provider: .codex, authProfileID: codex.id, commandName: "codexwork")
        ]
        let initialReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: .unavailable(.credentialExpired)
            ],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let authStore = StubAuthProfileStore(profiles: [claude, codex], supportsIDDelete: true)
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [initialReport])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            authProfileStore: authStore,
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let forcedRefresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        viewModel.removeProvider(.init(rawValue: "claude-work"))
        await waitForUsageFetches(quotaClient, expectedCount: 3)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [claude.id, codex.id], [codex.id]])

        await quotaClient.resolveAll(with: availableUsageReport(for: codex))
        await forcedRefresh.value
        await waitForUsageState(viewModel, profileID: codex.id, expected: availableUsageState(for: codex))
        XCTAssertNil(viewModel.subscriptionUsageStates[claude.id])
    }

    func testAutomaticUsageRefreshKeepsSnapshotAndMarksTransientFailureStale() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0)),
            SubscriptionUsageReport(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(
            viewModel.subscriptionUsageStates[profile.id],
            .stale(try! XCTUnwrap(initialState.snapshot), .transientFailure)
        )
    }

    func testStaleUsageRefreshBecomesAvailableAfterSuccessfulReplacement() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let refreshedSnapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .claude,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 120)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0)),
            .init(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60)),
            .init(statesByProfileID: [profile.id: .available(refreshedSnapshot)], fetchedAt: Date(timeIntervalSince1970: 120))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .available(refreshedSnapshot))
        XCTAssertEqual(viewModel.lastSuccessfulSubscriptionUsageRefreshAt, refreshedSnapshot.fetchedAt)
    }

    func testStaleUsageRefreshRetainsSnapshotAndUpdatesIssue() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let snapshot = try! XCTUnwrap(initialState.snapshot)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0)),
            .init(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60)),
            .init(statesByProfileID: [profile.id: .unavailable(.credentialExpired)], fetchedAt: Date(timeIntervalSince1970: 120))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(snapshot, .credentialExpired))
        XCTAssertEqual(viewModel.lastSuccessfulSubscriptionUsageRefreshAt, snapshot.fetchedAt)
    }

    func testAutomaticUsageRefreshKeepsSnapshotAndCacheAfterTerminalFailure() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0)),
            SubscriptionUsageReport(statesByProfileID: [profile.id: .unavailable(.credentialExpired)], fetchedAt: Date(timeIntervalSince1970: 60))
        ])
        let cache = SubscriptionUsageSnapshotCacheDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSnapshotCache: cache
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()

        let snapshot = try! XCTUnwrap(initialState.snapshot)
        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(snapshot, .credentialExpired))
        XCTAssertEqual(cache.load(), [profile.id: snapshot])
    }

    func testInitializationRestoresLastSuccessfulUsageBeforeNextRefresh() {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let snapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .claude,
            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            subscriptionUsageSnapshotCache: SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        )

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .available(snapshot))
        XCTAssertEqual(viewModel.lastSuccessfulSubscriptionUsageRefreshAt, snapshot.fetchedAt)
    }

    func testManualUsageRefreshKeepsExistingUsageUntilSuccessfulReplacement() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState: AccountSubscriptionUsageState = .available(
            SubscriptionUsageSnapshot(
                profileID: profile.id,
                provider: .claude,
                windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 25, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let refreshedState: AccountSubscriptionUsageState = .available(
            SubscriptionUsageSnapshot(
                profileID: profile.id,
                provider: .claude,
                windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 30, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 60)
            )
        )
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let reload = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], initialState)

        await quotaClient.resolveAll(with: SubscriptionUsageReport(
            statesByProfileID: [profile.id: refreshedState],
            fetchedAt: Date(timeIntervalSince1970: 60)
        ))
        await reload.value

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], refreshedState)
    }

    func testManualUsageRefreshKeepsSnapshotAndMarksFailureStale() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(statesByProfileID: [profile.id: initialState], fetchedAt: Date(timeIntervalSince1970: 0)),
            SubscriptionUsageReport(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage(force: true)

        XCTAssertEqual(
            viewModel.subscriptionUsageStates[profile.id],
            .stale(try! XCTUnwrap(initialState.snapshot), .transientFailure)
        )
    }

    func testManualUsageRefreshWaitsForAutomaticRefreshThenRetriesNonRetriableProfile() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: .unavailable(.schemaMismatch),
                codex.id: availableUsageState(for: codex)
            ],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [initialReport])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let automaticRefresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        let manualRefresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await Task.yield()

        await quotaClient.resolveAll(with: availableUsageReport(for: codex))
        await waitForUsageFetches(quotaClient, expectedCount: 3)
        await quotaClient.resolveAll(with: SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: availableUsageState(for: codex)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        ))
        await automaticRefresh.value
        await manualRefresh.value

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [codex.id], [claude.id, codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[claude.id], availableUsageState(for: claude))
    }

    func testSuccessfulUsageRefreshSchedulesFiveMinutePoll() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await waitForUsageSleeps(sleeper, expectedCount: 1)

        let delays = await sleeper.delays()
        XCTAssertEqual(delays, [300_000_000_000])
    }

    func testTransientStaleUsageRefreshUpdatesIssueAndDoublesRetryDelay() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let snapshot = try! XCTUnwrap(initialState.snapshot)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(statesByProfileID: [profile.id: initialState], fetchedAt: snapshot.fetchedAt),
            .init(statesByProfileID: [profile.id: .unavailable(.transientFailure)], fetchedAt: Date(timeIntervalSince1970: 60)),
            .init(statesByProfileID: [profile.id: .unavailable(.proxyUnavailable)], fetchedAt: Date(timeIntervalSince1970: 120))
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()
        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(snapshot, .transientFailure))
        await viewModel.refreshSubscriptionUsage()

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .stale(snapshot, .proxyUnavailable))
        let delays = await sleeper.delays()
        XCTAssertEqual(Array(delays.suffix(2)), [60_000_000_000, 120_000_000_000])
    }

    func testManualUsageRefreshRetriesSchemaMismatchProfileAndRestoresFiveMinutePolling() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: .unavailable(.schemaMismatch),
                codex.id: availableUsageState(for: codex)
            ],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let refreshedReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: availableUsageState(for: codex)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [initialReport, refreshedReport])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await waitForUsageSleeps(sleeper, expectedCount: 1)
        await viewModel.refreshSubscriptionUsage(force: true)
        await waitForUsageSleeps(sleeper, expectedCount: 2)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        let delays = await sleeper.delays()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [claude.id, codex.id]])
        XCTAssertEqual(delays, [300_000_000_000, 300_000_000_000])
        XCTAssertEqual(viewModel.subscriptionUsageStates[claude.id], availableUsageState(for: claude))
    }

    func testUsageRefreshReportsManualReloadAvailabilityAndProgress() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient
        )

        XCTAssertFalse(viewModel.canRefreshSubscriptionUsage)
        viewModel.serverStatus = readyStatus()
        XCTAssertTrue(viewModel.canRefreshSubscriptionUsage)
        XCTAssertFalse(viewModel.isSubscriptionUsageRefreshInProgress)

        let refresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        XCTAssertTrue(viewModel.isSubscriptionUsageRefreshInProgress)

        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await refresh.value
        XCTAssertFalse(viewModel.isSubscriptionUsageRefreshInProgress)
    }

    func testTerminalStaleProfileIsExcludedAutomaticallyAndForceRefreshRecoversIt() async {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let claude = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialClaudeState = availableUsageState(for: claude)
        let initialClaudeSnapshot = try! XCTUnwrap(initialClaudeState.snapshot)
        let recoveredClaudeSnapshot = SubscriptionUsageSnapshot(
            profileID: claude.id,
            provider: .claude,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 120)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(statesByProfileID: [claude.id: initialClaudeState, codex.id: availableUsageState(for: codex)], fetchedAt: Date(timeIntervalSince1970: 0)),
            .init(statesByProfileID: [claude.id: .unavailable(.credentialExpired), codex.id: availableUsageState(for: codex)], fetchedAt: Date(timeIntervalSince1970: 60)),
            .init(statesByProfileID: [codex.id: availableUsageState(for: codex)], fetchedAt: Date(timeIntervalSince1970: 90)),
            .init(statesByProfileID: [claude.id: .available(recoveredClaudeSnapshot), codex.id: availableUsageState(for: codex)], fetchedAt: Date(timeIntervalSince1970: 120))
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [claude, codex],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage()
        XCTAssertEqual(viewModel.subscriptionUsageStates[claude.id], .stale(initialClaudeSnapshot, .credentialExpired))
        await viewModel.refreshSubscriptionUsage()
        await viewModel.refreshSubscriptionUsage(force: true)

        let requestedProfileIDs = await quotaClient.requestedProfileIDs()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [claude.id, codex.id], [codex.id], [claude.id, codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[claude.id], .available(recoveredClaudeSnapshot))
    }

    func testDisablingSubscriptionUsageInvalidatesInFlightRefreshResult() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.isEnabled = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        try viewModel.saveSubscriptionUsageEnabled(false)
        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await refresh.value

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .disabled)
    }

    func testInstallOrUpdateCPMRefreshesStatusAfterSuccessfulInstall() async {
        let cpm = CPMInstallationDouble(
            status: .notInstalled,
            statusAfterInstall: .installedCurrent(version: "0.1.13")
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            cpmInstallationService: cpm
        )

        await viewModel.installOrUpdateCPM()

        XCTAssertEqual(cpm.actions, [.install])
        XCTAssertEqual(viewModel.cpmInstallationStatus, .installedCurrent(version: "0.1.13"))
        XCTAssertEqual(viewModel.settingsMessage, "cpm installed.")
    }

    func testRemoveCPMShowsServiceErrorWithoutChangingStatus() async {
        let cpm = CPMInstallationDouble(status: .unmanaged, removeError: .unmanagedTarget)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            cpmInstallationService: cpm
        )

        await viewModel.removeCPM()

        XCTAssertEqual(cpm.actions, [.remove])
        XCTAssertEqual(viewModel.cpmInstallationStatus, .unmanaged)
        XCTAssertEqual(viewModel.settingsMessage, "The existing /usr/local/bin/cpm was not installed by CLIProxyManager.")
    }

    private func subscriptionUsageViewModel(
        config: AppConfig,
        configStore: StubConfigStore,
        keyStore: SubscriptionUsageManagementKeyDouble,
        proxyService: StubProxyServiceStarter,
        profiles: [AuthProfile] = [],
        authProfileStore: (any AuthProfileManaging)? = nil,
        quotaClient: any SubscriptionQuotaFetching = StubSubscriptionQuotaClient(),
        subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching = SubscriptionUsageSnapshotCacheDouble(),
        subscriptionUsageSleep: @escaping @Sendable (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) -> DashboardViewModel {
        DashboardViewModel(
            config: config,
            configStore: configStore,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authProfileStore ?? StubAuthProfileStore(profiles: profiles),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: keyStore,
            subscriptionUsageSnapshotCache: subscriptionUsageSnapshotCache,
            subscriptionUsageSleep: subscriptionUsageSleep
        )
    }

    private func readyStatus() -> DiagnosticStatus {
        DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready")
    }

    private func availableUsageState(for profile: AuthProfile) -> AccountSubscriptionUsageState {
        .available(
            SubscriptionUsageSnapshot(
                profileID: profile.id,
                provider: profile.type,
                windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    private func availableUsageReport(for profile: AuthProfile) -> SubscriptionUsageReport {
        SubscriptionUsageReport(
            statesByProfileID: [profile.id: availableUsageState(for: profile)],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func waitForUsageFetches(_ quotaClient: SuspendedSubscriptionQuotaClient, expectedCount: Int) async {
        for _ in 0..<100 {
            if await quotaClient.fetchCallCount() >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Expected subscription usage fetch.")
    }

    private func waitForUsageSleeps(_ sleeper: SubscriptionUsageSleepRecorder, expectedCount: Int) async {
        for _ in 0..<100 {
            if await sleeper.delays().count >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Expected subscription usage polling delay.")
    }

    private func waitForUsageState(
        _ viewModel: DashboardViewModel,
        profileID: String,
        expected: AccountSubscriptionUsageState
    ) async {
        for _ in 0..<100 {
            if viewModel.subscriptionUsageStates[profileID] == expected { return }
            await Task.yield()
        }
        XCTFail("Expected subscription usage state \(expected).")
    }

    private func waitForRestart(_ proxyService: StubProxyServiceStarter, expectedCount: Int = 1) async {
        for _ in 0..<100 {
            if proxyService.restartPorts.count >= expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail("Expected proxy restart.")
    }

    private func connectedClaudeConnector() -> ClaudeConnector {
        ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ], count: 4).flatMap { $0 }))
    }
}

@MainActor
final class DashboardAccountOrderingTests: XCTestCase {
    func testProviderRowsApplyStoredOrderAcrossOAuthAndAPIKeyAccounts() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "claude-work", authProfileID: "claude.json", provider: .claude),
            commandProfile(id: "codex-work", authProfileID: "codex.json", provider: .codex)
        ]
        config.accountOrder = ["codex-api", "claude-work", "claude-api", "codex-work"]
        let secrets = InMemorySecretStore()
        try secrets.set("claude-key", for: .claudeAPIKey)
        try secrets.set("codex-key", for: .codexAPIKey)

        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("claude.json", type: .claude), profile("codex.json", type: .codex)],
            secretStore: secrets
        )

        XCTAssertEqual(
            viewModel.providerRows.map(\.id.rawValue),
            ["codex-api", "claude-work", "claude-api", "codex-work"]
        )
    }

    func testProviderRowsNormalizeMissingDuplicateAndNewAccountIDs() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "claude-work", authProfileID: "claude.json", provider: .claude),
            commandProfile(id: "codex-work", authProfileID: "codex.json", provider: .codex)
        ]
        config.accountOrder = ["missing", "codex-work", "codex-work"]

        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("claude.json", type: .claude), profile("codex.json", type: .codex)]
        )

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["codex-work", "claude-work"])
        XCTAssertEqual(viewModel.config.accountOrder, ["codex-work", "claude-work"])
    }

    func testMoveAccountPersistsNewOrderWithoutChangingOtherConfig() {
        let config = threeAccountConfig()
        let store = StubConfigStore(config: config)
        let viewModel = makeViewModel(
            config: config,
            profiles: threeProfiles(),
            configStore: store
        )

        viewModel.moveAccount("c", before: "a")

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["c", "a", "b"])
        XCTAssertEqual(viewModel.config.accountOrder, ["c", "a", "b"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["c", "a", "b"])
        XCTAssertEqual(store.savedConfigs.last?.port, config.port)
    }

    func testMoveUpAndDownRespectBoundaries() {
        let config = threeAccountConfig()
        let viewModel = makeViewModel(config: config, profiles: threeProfiles())

        XCTAssertFalse(viewModel.canMoveAccountUp("a"))
        XCTAssertFalse(viewModel.canMoveAccountDown("c"))
        XCTAssertTrue(viewModel.canMoveAccountUp("b"))
        XCTAssertTrue(viewModel.canMoveAccountDown("b"))

        viewModel.moveAccountUp("b")
        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["b", "a", "c"])

        viewModel.moveAccountDown("a")
        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["b", "c", "a"])
    }

    func testMoveAccountRollsBackWhenSavingFails() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
            commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
        ]
        let store = StubConfigStore(
            config: config,
            saveError: NSError(
                domain: "AccountOrder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Disk full"]
            )
        )
        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)],
            configStore: store
        )
        let originalOrder = viewModel.providerRows.map(\.id.rawValue)
        let originalConfigOrder = viewModel.config.accountOrder

        viewModel.moveAccount("b", before: "a")

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), originalOrder)
        XCTAssertEqual(viewModel.config.accountOrder, originalConfigOrder)
        XCTAssertEqual(viewModel.settingsMessage, "Account order could not be saved: Disk full")
    }

    func testNoOpMovesDoNotSave() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
            commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
        ]
        let store = StubConfigStore(config: config)
        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)],
            configStore: store
        )

        viewModel.moveAccount("a", before: "a")
        viewModel.moveAccountUp("a")
        viewModel.moveAccountDown("b")

        XCTAssertTrue(store.savedConfigs.isEmpty)
    }

    func testNewAccountIsAppendedWithoutChangingExistingRelativeOrder() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
            commandProfile(id: "b", authProfileID: "b.json", provider: .codex)
        ]
        config.accountOrder = ["b", "a"]
        let authStore = StubAuthProfileStore(
            profiles: [profile("a.json", type: .claude), profile("b.json", type: .codex)]
        )
        let viewModel = makeViewModel(
            config: config,
            profiles: [],
            authProfileStore: authStore
        )
        authStore.nextProfiles = [
            profile("a.json", type: .claude),
            profile("b.json", type: .codex),
            profile("c.json", type: .claude)
        ]

        viewModel.refreshProfiles()

        XCTAssertEqual(Array(viewModel.providerRows.map(\.id.rawValue).prefix(2)), ["b", "a"])
        XCTAssertEqual(viewModel.providerRows.last?.authProfileID, "c.json")
    }

    func testDeletingAccountRemovesItsIDAndPreservesSurvivorOrder() {
        var config = threeAccountConfig()
        config.accountOrder = ["c", "b", "a"]
        let store = StubConfigStore(config: config)
        let authStore = StubAuthProfileStore(profiles: threeProfiles(), supportsIDDelete: true)
        let viewModel = makeViewModel(
            config: config,
            profiles: [],
            configStore: store,
            authProfileStore: authStore
        )

        viewModel.removeProvider("b")

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["c", "a"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["c", "a"])
    }

    func testAPIKeyReRegistrationAppendsAfterSurvivingAccounts() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude)
        ]
        config.accountOrder = ["claude-api", "a"]
        let store = StubConfigStore(config: config)
        let secrets = InMemorySecretStore()
        try secrets.set("old-key", for: .claudeAPIKey)
        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("a.json", type: .claude)],
            configStore: store,
            secretStore: secrets
        )

        viewModel.removeAPIProvider(.claudeAPI)
        XCTAssertEqual(viewModel.config.accountOrder, ["a"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["a"])

        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            nickname: "API",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["a", "claude-api"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["a", "claude-api"])
    }

    private func threeAccountConfig() -> AppConfig {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude),
            commandProfile(id: "b", authProfileID: "b.json", provider: .codex),
            commandProfile(id: "c", authProfileID: "c.json", provider: .claude)
        ]
        return config
    }

    private func threeProfiles() -> [AuthProfile] {
        [
            profile("a.json", type: .claude),
            profile("b.json", type: .codex),
            profile("c.json", type: .claude)
        ]
    }

    private func profile(_ id: String, type: AuthProfileType) -> AuthProfile {
        AuthProfile(
            fileName: id,
            type: type,
            email: "\(id)@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
    }

    private func commandProfile(
        id: String,
        authProfileID: String,
        provider: AuthProfileType
    ) -> AppConfig.OAuthCommandProfile {
        AppConfig.OAuthCommandProfile(
            id: id,
            provider: provider,
            authProfileID: authProfileID,
            commandName: "cmd\(id)",
            nickname: id,
            isEnabled: true
        )
    }

    private func makeViewModel(
        config: AppConfig,
        profiles: [AuthProfile],
        configStore: StubConfigStore? = nil,
        authProfileStore: (any AuthProfileManaging)? = nil,
        secretStore: any SecretStore = InMemorySecretStore()
    ) -> DashboardViewModel {
        DashboardViewModel(
            config: config,
            configStore: configStore ?? StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authProfileStore ?? StubAuthProfileStore(profiles: profiles),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )
    }

    private func connectedClaudeConnector() -> ClaudeConnector {
        ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ], count: 4).flatMap { $0 }))
    }
}

private final class CPMInstallationDouble: CPMInstallationManaging {
    enum Action: Equatable {
        case install
        case remove
    }

    private var currentStatus: CPMInstallationStatus
    private let statusAfterInstall: CPMInstallationStatus?
    private let statusAfterRemove: CPMInstallationStatus?
    private let installError: CPMInstallationError?
    private let removeError: CPMInstallationError?
    private(set) var actions: [Action] = []

    init(
        status: CPMInstallationStatus,
        statusAfterInstall: CPMInstallationStatus? = nil,
        statusAfterRemove: CPMInstallationStatus? = nil,
        installError: CPMInstallationError? = nil,
        removeError: CPMInstallationError? = nil
    ) {
        currentStatus = status
        self.statusAfterInstall = statusAfterInstall
        self.statusAfterRemove = statusAfterRemove
        self.installError = installError
        self.removeError = removeError
    }

    func status() -> CPMInstallationStatus { currentStatus }

    func installOrUpdate() async throws {
        actions.append(.install)
        if let installError { throw installError }
        if let statusAfterInstall { currentStatus = statusAfterInstall }
    }

    func remove() async throws {
        actions.append(.remove)
        if let removeError { throw removeError }
        if let statusAfterRemove { currentStatus = statusAfterRemove }
    }
}

private struct StubSubscriptionQuotaClient: SubscriptionQuotaFetching {
    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: Date())
    }
}

private actor RecordingSubscriptionQuotaClient: SubscriptionQuotaFetching {
    private var reports: [SubscriptionUsageReport]
    private var callCount = 0
    private var profileIDs: [[String]] = []

    init(reports: [SubscriptionUsageReport]) {
        self.reports = reports
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        callCount += 1
        profileIDs.append(profiles.map(\.id))
        return reports.removeFirst()
    }

    func fetchCallCount() -> Int { callCount }
    func requestedProfileIDs() -> [[String]] { profileIDs }
}

private actor SuspendedSubscriptionQuotaClient: SubscriptionQuotaFetching {
    private var reportsBeforeSuspension: [SubscriptionUsageReport]
    private var continuations: [CheckedContinuation<SubscriptionUsageReport, Never>] = []
    private var callCount = 0
    private var profileIDs: [[String]] = []

    init(reportsBeforeSuspension: [SubscriptionUsageReport] = []) {
        self.reportsBeforeSuspension = reportsBeforeSuspension
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        callCount += 1
        profileIDs.append(profiles.map(\.id))
        if !reportsBeforeSuspension.isEmpty {
            return reportsBeforeSuspension.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func fetchCallCount() -> Int { callCount }
    func requestedProfileIDs() -> [[String]] { profileIDs }

    func resolveAll(with report: SubscriptionUsageReport) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: report)
        }
    }
}

private actor SubscriptionUsageSleepRecorder {
    private var recordedDelays: [UInt64] = []

    func sleep(_ delay: UInt64) async throws {
        recordedDelays.append(delay)
        throw CancellationError()
    }

    func delays() -> [UInt64] { recordedDelays }
}

private final class SubscriptionUsageSnapshotCacheDouble: SubscriptionUsageSnapshotCaching, @unchecked Sendable {
    private var snapshots: [String: SubscriptionUsageSnapshot]

    init(snapshots: [String: SubscriptionUsageSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func load() -> [String: SubscriptionUsageSnapshot] { snapshots }
    func save(_ snapshots: [String: SubscriptionUsageSnapshot]) throws { self.snapshots = snapshots }
    func clear() throws { snapshots = [:] }
}

private final class EmptyClaudeModelOptionsCache: ClaudeModelOptionsCaching, @unchecked Sendable {
    func load() -> [String: [ClaudeModelOption]] { [:] }
    func save(_: [String: [ClaudeModelOption]]) throws {}
}

private final class SubscriptionUsageManagementKeyDouble: SubscriptionUsageManagementKeyConfiguring, @unchecked Sendable {
    var isConfiguredValue: Bool
    var createCallCount = 0
    var deleteCallCount = 0
    var createError: Error?
    var deleteError: Error?

    init(isConfiguredValue: Bool = false) {
        self.isConfiguredValue = isConfiguredValue
    }

    func isConfigured() -> Bool {
        isConfiguredValue
    }

    func createManagementKeyIfNeeded() throws -> Bool {
        createCallCount += 1
        if let createError {
            throw createError
        }
        guard !isConfiguredValue else {
            return false
        }
        isConfiguredValue = true
        return true
    }

    func setManagementKey(_ value: String) throws {
        isConfiguredValue = !value.isEmpty
    }

    func deleteManagementKey() throws {
        deleteCallCount += 1
        if let deleteError {
            throw deleteError
        }
        isConfiguredValue = false
    }
}

private final class StubConfigStore: AppConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let saveError: Error?
    private(set) var savedConfigs: [AppConfig] = []
    var config: AppConfig

    init(config: AppConfig = .default, saveError: Error? = nil) {
        self.config = config
        self.saveError = saveError
    }

    func load() throws -> AppConfig {
        config
    }

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
    private(set) var installedScript: String?
    private(set) var installedFunctionNames: [String] = []
    private(set) var installCount = 0
    private(set) var validatedFunctionNames: [[String]] = []
    var installed = false

    init(validationError: Error? = nil, installError: Error? = nil) {
        self.validationError = validationError
        self.installError = installError
    }

    func install(functionScript: String, functionNames: [String]) throws {
        if let installError { throw installError }
        installedScript = functionScript
        installedFunctionNames = functionNames
        installCount += 1
        installed = true
    }

    func isInstalled() -> Bool {
        installed
    }

    func validateFunctionNames(_ names: [String]) throws {
        validatedFunctionNames.append(names)
        if let validationError { throw validationError }
    }

    func reset() {
        installedScript = nil
        installedFunctionNames = []
        installCount = 0
        installed = false
        validatedFunctionNames = []
    }
}

private struct PrefixModelRequest: Equatable {
    let port: Int
    let prefix: String
}

private final class StubProxyModelClient: ProxyModelListing, @unchecked Sendable {
    private let options: [CodexModelOption]
    private let optionsByPrefix: [String: [CodexModelOption]]
    private let claudeOptionsByPrefix: [String: [ClaudeModelOption]]
    private let lock = NSLock()
    private var _ports: [Int] = []
    private var _prefixRequests: [PrefixModelRequest] = []
    private var _claudePrefixRequests: [PrefixModelRequest] = []
    private var _codexBaseModelsCallCount = 0

    var ports: [Int] {
        lock.withLock { _ports }
    }

    var baseModelsCallCount: Int { 0 }

    var codexBaseModelsCallCount: Int {
        lock.withLock { _codexBaseModelsCallCount }
    }

    var prefixRequests: [PrefixModelRequest] {
        lock.withLock { _prefixRequests }
    }

    var claudePrefixRequests: [PrefixModelRequest] {
        lock.withLock { _claudePrefixRequests }
    }

    init(models: [String]) {
        options = models.map { CodexModelOption(id: $0) }
        optionsByPrefix = [:]
        claudeOptionsByPrefix = [:]
    }

    init(options: [CodexModelOption]) {
        self.options = options
        optionsByPrefix = [:]
        claudeOptionsByPrefix = [:]
    }

    init(modelsByPrefix: [String: [String]]) {
        options = []
        optionsByPrefix = modelsByPrefix.mapValues { $0.map { CodexModelOption(id: $0) } }
        claudeOptionsByPrefix = [:]
    }

    init(optionsByPrefix: [String: [CodexModelOption]]) {
        options = []
        self.optionsByPrefix = optionsByPrefix
        claudeOptionsByPrefix = [:]
    }

    init(claudeOptionsByPrefix: [String: [ClaudeModelOption]]) {
        options = []
        optionsByPrefix = [:]
        self.claudeOptionsByPrefix = claudeOptionsByPrefix
    }

    func codexModelOptions(port: Int) async throws -> [CodexModelOption] {
        lock.withLock {
            _ports.append(port)
            _codexBaseModelsCallCount += 1
        }
        return options
    }

    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
        lock.withLock {
            _prefixRequests.append(PrefixModelRequest(port: port, prefix: modelPrefix))
            _codexBaseModelsCallCount += 1
        }
        return optionsByPrefix[modelPrefix] ?? options
    }

    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption] {
        lock.withLock {
            _claudePrefixRequests.append(PrefixModelRequest(port: port, prefix: modelPrefix))
        }
        return claudeOptionsByPrefix[modelPrefix] ?? []
    }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _profiles: [AuthProfile]
    private var _disabledUpdates: [DisabledUpdate] = []
    private var _disabledIDUpdates: [DisabledIDUpdate] = []
    private var _deletedIDs: [String] = []
    private var _deleteInvocations: [AuthProfileType] = []
    private let supportsIDDelete: Bool
    var nextProfiles: [AuthProfile]?

    var disabledUpdates: [DisabledUpdate] {
        lock.withLock { _disabledUpdates }
    }

    var disabledIDUpdates: [DisabledIDUpdate] {
        lock.withLock { _disabledIDUpdates }
    }

    var deletedIDs: [String] {
        lock.withLock { _deletedIDs }
    }

    var deleteInvocations: [AuthProfileType] {
        lock.withLock { _deleteInvocations }
    }

    init(profiles: [AuthProfile], supportsIDDelete: Bool = false) {
        self._profiles = profiles
        self.supportsIDDelete = supportsIDDelete
    }

    func profiles() throws -> [AuthProfile] {
        lock.withLock {
            if let nextProfiles {
                _profiles = nextProfiles
                self.nextProfiles = nil
            }
            return _profiles
        }
    }

    func delete(id: String) throws -> Bool {
        lock.withLock {
            guard supportsIDDelete,
                  _profiles.contains(where: { $0.id == id }) else {
                return false
            }
            _deletedIDs.append(id)
            _profiles.removeAll { $0.id == id }
            return true
        }
    }

    func delete(for type: AuthProfileType) throws -> Int {
        lock.withLock {
            _deleteInvocations.append(type)
            let count = _profiles.filter { $0.type == type }.count
            _profiles.removeAll { $0.type == type }
            return count
        }
    }

    func setDisabled(_ disabled: Bool, id: String) throws -> Bool {
        lock.withLock {
            guard let index = _profiles.firstIndex(where: { $0.id == id }) else { return false }
            _disabledIDUpdates.append(DisabledIDUpdate(id: id, disabled: disabled))
            let profile = _profiles[index]
            _profiles[index] = AuthProfile(
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
    }

    func setPrefix(_ prefix: String?, id: String) throws -> Bool {
        lock.withLock {
            guard let index = _profiles.firstIndex(where: { $0.id == id }) else { return false }
            let profile = _profiles[index]
            _profiles[index] = AuthProfile(
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
    }

    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int {
        lock.withLock {
            _disabledUpdates.append(DisabledUpdate(type: type, disabled: disabled))
            return _profiles.filter { $0.type == type }.count
        }
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

private final class StubOAuthLoginService: OAuthLoginStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [OAuthLoginProvider] = []
    var error: Error?

    var invocations: [OAuthLoginProvider] { lock.withLock { _invocations } }

    func login(provider: OAuthLoginProvider, port: Int) async throws {
        lock.withLock { _invocations.append(provider) }
        if let error { throw error }
    }
}

private final class SuspendedOAuthLoginService: OAuthLoginStarting, @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private var invocationCountContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var hasStarted = false
    private var hasCompleted = false
    private var _wasCancelled = false
    private var _invocationCount = 0
    private var _providers: [OAuthLoginProvider] = []

    var wasCancelled: Bool { lock.withLock { _wasCancelled } }
    var invocationCount: Int { lock.withLock { _invocationCount } }
    var providers: [OAuthLoginProvider] { lock.withLock { _providers } }

    func login(provider: OAuthLoginProvider, port: Int) async throws {
        await markStarted(provider)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasCompleted {
                    lock.unlock()
                    continuation.resume()
                } else {
                    completionContinuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            self._wasCancelled = true
            let continuation = self.completionContinuation
            self.completionContinuation = nil
            self.lock.unlock()
            continuation?.resume()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasStarted {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuation = continuation
                lock.unlock()
            }
        }
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if _invocationCount >= expectedCount {
                lock.unlock()
                continuation.resume()
            } else {
                invocationCountContinuations.append((expectedCount, continuation))
                lock.unlock()
            }
        }
    }

    func complete() {
        lock.lock()
        hasCompleted = true
        let continuation = completionContinuation
        completionContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func markStarted(_ provider: OAuthLoginProvider) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            _invocationCount += 1
            _providers.append(provider)
            hasStarted = true
            let waitingContinuation = startedContinuation
            startedContinuation = nil
            let readyContinuations = invocationCountContinuations.filter { _invocationCount >= $0.0 }.map(\.1)
            invocationCountContinuations.removeAll { _invocationCount >= $0.0 }
            lock.unlock()
            waitingContinuation?.resume()
            readyContinuations.forEach { $0.resume() }
            continuation.resume()
        }
    }
}

private final class DeferredCancellationOAuthLoginService: OAuthLoginStarting, @unchecked Sendable {
    private final class Invocation: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func login(provider: OAuthLoginProvider, port: Int) async throws {
        let invocation = Invocation()
        record(invocation)

        await withCheckedContinuation { continuation in
            invocation.lock.lock()
            if invocation.isReleased {
                invocation.lock.unlock()
                continuation.resume()
            } else {
                invocation.continuation = continuation
                invocation.lock.unlock()
            }
        }
        try Task.checkCancellation()
    }

    func waitForInvocationCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if invocations.count >= expectedCount {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((expectedCount, continuation))
                lock.unlock()
            }
        }
    }

    private func record(_ invocation: Invocation) {
        lock.lock()
        invocations.append(invocation)
        let count = invocations.count
        let readyWaiters = waiters.filter { count >= $0.0 }.map(\.1)
        waiters.removeAll { count >= $0.0 }
        lock.unlock()
        readyWaiters.forEach { $0.resume() }
    }

    func releaseInvocation(at index: Int) {
        lock.lock()
        let invocation = invocations[index]
        lock.unlock()

        invocation.lock.lock()
        invocation.isReleased = true
        let continuation = invocation.continuation
        invocation.continuation = nil
        invocation.lock.unlock()
        continuation?.resume()
    }
}

private struct StubHTTPClient: HTTPClient {
    let result: Result<Data, Error>

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try result.get()
    }
}

private final class SequencedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var _requestCount = 0

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try lock.withLock {
            _requestCount += 1
            return try results.removeFirst().get()
        }
    }
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

private final class StubProxyServiceStarter: ProxyServiceControlling, @unchecked Sendable {
    private let error: Error?
    private let startDelayNanoseconds: UInt64
    private let stopDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var _ports: [Int] = []
    private var _restartPorts: [Int] = []
    private var _stopCount = 0

    var ports: [Int] {
        lock.withLock { _ports }
    }

    var restartPorts: [Int] {
        lock.withLock { _restartPorts }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    init(error: Error? = nil, startDelayNanoseconds: UInt64 = 0, stopDelayNanoseconds: UInt64 = 0) {
        self.error = error
        self.startDelayNanoseconds = startDelayNanoseconds
        self.stopDelayNanoseconds = stopDelayNanoseconds
    }

    func start(port: Int) async throws {
        lock.withLock { _ports.append(port) }
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        if let error {
            throw error
        }
    }

    func stop() async throws {
        lock.withLock { _stopCount += 1 }
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        if let error {
            throw error
        }
    }

    func restart(port: Int) async throws {
        lock.withLock { _restartPorts.append(port) }
        if let error {
            throw error
        }
    }
}

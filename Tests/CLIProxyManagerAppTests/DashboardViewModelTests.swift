import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class DashboardViewModelRefreshTests: XCTestCase {
    func testRefreshUpdatesClaudeAndCodexCardsByCommandAndExcludesClaudeAPICard() async {
        let config = AppConfig(
            port: 9444,
            claudeAPI: AppConfig.ClaudeAPI(commandName: "api-local"),
            startAtLogin: false,
            showDockIcon: true,
            showMenuBarIcon: true,
            oauthCommandProfiles: [
                AppConfig.OAuthCommandProfile(
                    id: "claude",
                    provider: .claude,
                    authProfileID: "claude.json",
                    commandName: "claude-local",
                    modelPrefix: "claude-account"
                ),
                AppConfig.OAuthCommandProfile(
                    id: "codex",
                    provider: .codex,
                    authProfileID: "codex.json",
                    commandName: "codex-local",
                    codex: AppConfig.Codex(
                        opus: AppConfig.CodexRole(model: "test-opus", reasoning: .auto),
                        sonnet: AppConfig.CodexRole(model: "test-sonnet", reasoning: .auto),
                        haiku: AppConfig.CodexRole(model: "test-haiku", reasoning: .auto)
                    ),
                    modelPrefix: "codex-account"
                )
            ]
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
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccmcodex",
                dangerousPermissionsEnabled: true,
                codex: .default
            )
        ]
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccmcodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
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

    func testProviderRowDefaultsToShowingInUsageOverlay() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "cc",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        XCTAssertTrue(row.showsInUsageOverlay)
    }

    func testProviderRowsReflectUsageOverlayHiddenAccountIDs() {
        var config = AppConfig.default
        config.usageOverlay.hiddenAccountIDs = [ProviderRowState.ID.codex.rawValue]
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

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.showsInUsageOverlay, false)
    }

    func testSetAccountVisibleInUsageOverlayPersistsHiddenIDAndUpdatesRow() throws {
        let store = StubConfigStore(config: .default)
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

        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

        XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, ["claude"])
        XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, ["claude"])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, false)

        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: true)

        XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
        XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, [])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
    }

    func testSetAccountVisibleInUsageOverlaySkipsUnknownAndUnchangedAccounts() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", modelPrefix: "claude-account")
        ]
        let store = StubConfigStore(config: config)
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

        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: true)
        try viewModel.setAccountVisibleInUsageOverlay("missing", isVisible: false)

        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSetAccountVisibleInUsageOverlayRollsBackWhenSaveFails() {
        let store = StubConfigStore(
            config: .default,
            saveError: NSError(
                domain: "UsageOverlayAccountVisibility",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Save failed"]
            )
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

        XCTAssertThrowsError(
            try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Usage HUD account visibility could not be saved: Save failed"
            )
        }
        XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.showsInUsageOverlay, true)
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testSetAccountVisibleInUsageOverlayDoesNotChangeUsageBackendLifecycle() throws {
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        let proxyService = StubProxyServiceStarter()
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionUsageKeyStore: keyStore,
            secretStore: InMemorySecretStore()
        )

        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

        XCTAssertEqual(proxyService.restartPorts, [])
        XCTAssertEqual(keyStore.createCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
    }

    func testSetAccountVisibleInUsageOverlayPreservesCachedSnapshot() throws {
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let snapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .claude,
            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 25, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            subscriptionUsageSnapshotCache: cache
        )

        try viewModel.setAccountVisibleInUsageOverlay(.claude, isVisible: false)

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .available(snapshot))
        XCTAssertEqual(cache.load(), [profile.id: snapshot])
    }

    func testProviderRowsReflectConfiguredAccountPrivacy() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: false, modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", accountDetailHidden: true, codex: .default, modelPrefix: "codex-account")
        ]
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: true, modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", accountDetailHidden: false, codex: .default, modelPrefix: "codex-account")
        ]
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

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.id == "claude" }?.accountDetailHidden, false)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.id == "codex" }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.id == "claude" }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.id == "codex" }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.accountDetailHidden, false)
    }

    func testToggleCodexAccountDetailVisibilityPersistsOnlyCodexPrivacy() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: false, modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", accountDetailHidden: true, codex: .default, modelPrefix: "codex-account")
        ]
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

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.id == "claude" }?.accountDetailHidden, false)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.id == "codex" }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.id == "claude" }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.id == "codex" }?.accountDetailHidden, false)
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: true, modelPrefix: "claude-account")
        ]
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
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.accountDetailHidden, true)
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

    func testFirstOAuthAccountStartsSubscriptionUsageRefreshWhenProxyIsReady() async {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let authStore = StubAuthProfileStore(profiles: [])
        authStore.nextProfiles = [profile]
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore()
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.connectProvider(.codex)

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCallCount, 1)
    }

    func testOAuthSourceCompletionHandsOffIndependentResetWithoutDuplicateRefresh() async {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let authStore = StubAuthProfileStore(profiles: [])
        authStore.nextProfiles = [profile]
        let usageReport = SubscriptionUsageReport(
            statesByProfileID: [profile.id: availableUsageState(for: profile)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let resetSnapshot = resetCreditSnapshot(
            profileID: profile.id,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReport: usageReport)
        let resetCache = CodexResetCreditsSnapshotCacheDouble()
        let sleeper = SubscriptionUsageSleepRecorder()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { clock.now() },
            secretStore: InMemorySecretStore(),
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) },
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        await viewModel.connectProvider(.codex)
        let didStartReset = await quotaClient.waitForResetRequests(expectedCount: 1)
        XCTAssertTrue(didStartReset)
        let didScheduleUsagePolling = await sleeper.waitForDelays(expectedCount: 1)
        XCTAssertTrue(didScheduleUsagePolling)
        let usageCountBeforeResetCompletion = await quotaClient.usageRequestCount()
        let delaysBeforeResetCompletion = await sleeper.delays()
        XCTAssertEqual(usageCountBeforeResetCompletion, 1)
        XCTAssertEqual(delaysBeforeResetCompletion, [300_000_000_000])

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [profile.id: .available(resetSnapshot)],
            resetCreditsAttemptedProfileIDs: [profile.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        for _ in 0..<1_000 {
            if viewModel.codexResetCreditsSnapshots[profile.id] == resetSnapshot { break }
            if await quotaClient.usageRequestCount() > 1 { break }
            await Task.yield()
        }

        let didReschedulePolling = await sleeper.waitForDelays(expectedCount: 2)
        XCTAssertTrue(didReschedulePolling)
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[profile.id], resetSnapshot)
        XCTAssertEqual(resetCache.load()[profile.id], resetSnapshot)
        let finalUsageCount = await quotaClient.usageRequestCount()
        let finalResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        let finalDelays = await sleeper.delays()
        XCTAssertEqual(finalUsageCount, 1)
        XCTAssertEqual(finalResetProfileIDSets, [[profile.id]])
        XCTAssertEqual(finalDelays, [300_000_000_000, 300_000_000_000])
    }

    func testOAuthCompletionWaitsForQueuedConfigurationRestartBeforeUsageRefresh() async {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let disabledProfile = AuthProfile(
            fileName: profile.fileName,
            type: profile.type,
            email: profile.email,
            accountID: profile.accountID,
            expired: profile.expired,
            disabled: true
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: profile.id,
                codex: AppConfig.Codex(
                    opus: .init(model: "gpt-5.6-terra", reasoning: .xhigh, fastModeEnabled: true),
                    sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
                    haiku: .init(model: "gpt-5.6-terra", reasoning: .low)
                ),
                isEnabled: false
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [disabledProfile])
        authStore.nextProfiles = [profile]
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            availableUsageReport(for: profile, resetCreditsDeferredProfileIDs: [profile.id])
        ])
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let login = Task { await viewModel.connectProvider(.codex) }
        let didQueueRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(didQueueRestart)

        let fetchCountBeforeRestart = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCountBeforeRestart, 0)

        proxyService.releaseRestart(1)
        await login.value
        let fetchCountAfterRestart = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCountAfterRestart, 1)
    }

    func testCancellingOAuthWhileConfigurationRestartIsPendingSkipsUsageRefresh() async {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let disabledProfile = AuthProfile(
            fileName: profile.fileName,
            type: profile.type,
            email: profile.email,
            accountID: profile.accountID,
            expired: profile.expired,
            disabled: true
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: profile.id,
                codex: AppConfig.Codex(
                    opus: .init(model: "gpt-5.6-terra", reasoning: .xhigh, fastModeEnabled: true),
                    sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
                    haiku: .init(model: "gpt-5.6-terra", reasoning: .low)
                ),
                isEnabled: false
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [disabledProfile])
        authStore.nextProfiles = [profile]
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            availableUsageReport(for: profile, resetCreditsDeferredProfileIDs: [profile.id])
        ])
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let login = Task { await viewModel.connectProvider(.codex) }
        let didQueueRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(didQueueRestart)

        login.cancel()
        proxyService.releaseRestart(1)
        await login.value

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCallCount, 0)
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth login was cancelled.")
    }

    func testOAuthCompletionQueuesRefreshAfterActiveSubscriptionRefresh() async {
        let claude = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let authStore = StubAuthProfileStore(profiles: [claude])
        let quotaClient = SuspendedSubscriptionQuotaClient()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore()
        )
        viewModel.serverStatus = readyStatus()
        Task { await viewModel.refreshSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)
        authStore.nextProfiles = [claude, codex]

        await viewModel.connectProvider(.codex)
        await quotaClient.resolveAll(with: availableUsageReport(for: claude))
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        let fetchCount = await quotaClient.fetchCallCount()
        let requestedUsageProfileIDSets = await quotaClient.requestedUsageProfileIDSets()
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(requestedUsageProfileIDSets.last, [claude.id, codex.id])
        let refreshedReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: availableUsageState(for: codex)
            ],
            resetCreditsDeferredProfileIDs: [codex.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        await quotaClient.resolveAll(with: refreshedReport)
        guard requestedUsageProfileIDSets.last == [claude.id, codex.id] else { return }
        await waitForUsageState(
            viewModel,
            profileID: codex.id,
            expected: availableUsageState(for: codex)
        )
    }

    func testOAuthDuringReadyWaitActionDrainsConfigurationRestartBeforeExactlyOneUsageRefresh() async {
        let fixture = activeRestartOAuthFixture()

        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)

        fixture.proxyService.releaseRestart(1)
        let reachedSecondRestart = await fixture.proxyService.reachesRestartCount(2)
        let fetchCountBeforeSecondRestart = await fixture.quotaClient.fetchCallCount()
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertEqual(fetchCountBeforeSecondRestart, 0)

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value

        let fetchCount = await fixture.quotaClient.fetchCallCount()
        let resetProfileIDSets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(fixture.proxyService.restartPorts.count, 2)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(resetProfileIDSets, [[fixture.profile.id]])
    }

    func testOAuthDuringReadyWaitActionSkipsUsageAndResetWhenConfigurationRestartFails() async {
        let restartFailure = NSError(
            domain: "ConfigurationRestart",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Restart failed"]
        )
        let fixture = activeRestartOAuthFixture(restartErrors: [nil, restartFailure])

        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)

        fixture.proxyService.releaseRestart(1)
        let reachedSecondRestart = await fixture.proxyService.reachesRestartCount(2)
        let fetchCountBeforeSecondRestart = await fixture.quotaClient.fetchCallCount()
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertEqual(fetchCountBeforeSecondRestart, 0)

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value

        let failedRestartFetchCount = await fixture.quotaClient.fetchCallCount()
        let failedRestartDelays = await fixture.sleeper.delays()
        XCTAssertEqual(failedRestartFetchCount, 0)
        XCTAssertEqual(failedRestartDelays, [])
        XCTAssertEqual(fixture.viewModel.serverStatus.severity, .error)

        await fixture.viewModel.restartServer()

        let recoveryFetchCount = await fixture.quotaClient.fetchCallCount()
        let resetProfileIDSets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(recoveryFetchCount, 1)
        XCTAssertEqual(resetProfileIDSets, [[fixture.profile.id]])
    }

    func testCancellingOAuthDuringReadyWaitActionResumesExactlyOneActionRefresh() async {
        let fixture = activeRestartOAuthFixture()

        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)

        fixture.proxyService.releaseRestart(1)
        let reachedSecondRestart = await fixture.proxyService.reachesRestartCount(2)
        let fetchCountBeforeSecondRestart = await fixture.quotaClient.fetchCallCount()
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertEqual(fetchCountBeforeSecondRestart, 0)

        login.cancel()
        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value

        let fetchCount = await fixture.quotaClient.fetchCallCount()
        let resetProfileIDSets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(resetProfileIDSets, [[fixture.profile.id]])
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth login was cancelled.")
    }

    func testReplacementOAuthSessionOwnsDeferredRefreshAfterActiveConfigurationRestart() async {
        let fixture = activeRestartOAuthFixture()

        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await waitForOAuthReconciliation(fixture.authStore)

        fixture.proxyService.releaseRestart(1)
        let reachedSecondRestart = await fixture.proxyService.reachesRestartCount(2)
        let fetchCountBeforeSecondRestart = await fixture.quotaClient.fetchCallCount()
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertEqual(fetchCountBeforeSecondRestart, 0)

        fixture.viewModel.cancelOAuthLogin()
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await waitForOAuthInvocations(fixture.oauthLoginService, expectedCount: 2)

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await waitForOAuthCompletion(fixture.viewModel)

        let fetchCount = await fixture.quotaClient.fetchCallCount()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(fixture.viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth connection was updated.")
    }

    func testLateOAuthRestartPrecedesChangedProfileRefreshAfterActionUsageSuspends() async {
        let fixture = await lateActionRefreshOAuthFixture()
        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.proxyService.releaseRestart(1)
        let didSuspendActionUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        XCTAssertTrue(didSuspendActionUsage)

        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)
        let usageBeforeActionResolution = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeActionResolution = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(usageBeforeActionResolution, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsBeforeActionResolution, [])

        await fixture.quotaClient.releaseActionUsage()
        let reachedConfigurationRestart = await fixture.proxyService.reachesRestartCount(2)
        let usageBeforeConfigurationRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeConfigurationRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(reachedConfigurationRestart)
        XCTAssertEqual(usageBeforeConfigurationRestart, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsBeforeConfigurationRestart, [])

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value
        let didRequestFinalReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)

        let usageProfileIDSets = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetProfileIDSets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertTrue(didRequestFinalReset)
        XCTAssertEqual(
            usageProfileIDSets,
            [[fixture.claude.id], [fixture.claude.id], [fixture.claude.id, fixture.codex.id]]
        )
        XCTAssertEqual(resetProfileIDSets, [[fixture.codex.id]])
        XCTAssertEqual(collectorUpdates.count, 1)
        XCTAssertEqual(fixture.viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth connection was updated.")
    }

    func testLateOAuthRestartFailurePreservesErrorAndSkipsChangedProfileRefresh() async {
        let restartFailure = NSError(
            domain: "LateConfigurationRestart",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Restart failed"]
        )
        let fixture = await lateActionRefreshOAuthFixture(restartErrors: [nil, restartFailure])
        let baselineDelays = await fixture.sleeper.delays()
        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.proxyService.releaseRestart(1)
        let didSuspendActionUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        XCTAssertTrue(didSuspendActionUsage)

        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)
        await fixture.quotaClient.releaseActionUsage()
        let reachedConfigurationRestart = await fixture.proxyService.reachesRestartCount(2)
        let usageBeforeConfigurationRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeConfigurationRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(reachedConfigurationRestart)
        XCTAssertEqual(usageBeforeConfigurationRestart, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsBeforeConfigurationRestart, [])

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value

        let usageAfterFailure = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsAfterFailure = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorUpdatesAfterFailure = await fixture.collector.updateConfigurations()
        let delaysAfterFailure = await fixture.sleeper.delays()
        XCTAssertEqual(usageAfterFailure, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsAfterFailure, [])
        XCTAssertEqual(collectorUpdatesAfterFailure, [])
        XCTAssertEqual(delaysAfterFailure, baselineDelays)
        XCTAssertNil(fixture.viewModel.completedOAuthLoginProvider)
        XCTAssertEqual(
            fixture.viewModel.settingsMessage,
            "Fast mode settings were saved, but CLIProxyAPI could not restart: Restart failed"
        )
        XCTAssertEqual(fixture.viewModel.serverStatus.severity, .error)

        await fixture.viewModel.restartServer()
        let didRequestResetAfterRecovery = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        let resetProfileIDSetsAfterRecovery = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(didRequestResetAfterRecovery)
        XCTAssertEqual(resetProfileIDSetsAfterRecovery, [[fixture.codex.id]])
        XCTAssertNil(fixture.viewModel.completedOAuthLoginProvider)
    }

    func testCancellingLateOAuthSessionDrainsRestartAndResumesActionRefresh() async {
        let fixture = await lateActionRefreshOAuthFixture()
        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.proxyService.releaseRestart(1)
        let didSuspendActionUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        XCTAssertTrue(didSuspendActionUsage)

        let login = Task { await fixture.viewModel.connectProvider(.codex) }
        await waitForOAuthReconciliation(fixture.authStore)
        login.cancel()
        await fixture.quotaClient.releaseActionUsage()
        let reachedConfigurationRestart = await fixture.proxyService.reachesRestartCount(2)
        let usageBeforeConfigurationRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeConfigurationRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(reachedConfigurationRestart)
        XCTAssertEqual(usageBeforeConfigurationRestart, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsBeforeConfigurationRestart, [])

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await login.value
        let didResumeReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)

        let usageAfterCancellation = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsAfterCancellation = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertTrue(didResumeReset)
        XCTAssertEqual(
            usageAfterCancellation,
            [[fixture.claude.id], [fixture.claude.id], [fixture.claude.id, fixture.codex.id]]
        )
        XCTAssertEqual(resetsAfterCancellation, [[fixture.codex.id]])
        XCTAssertEqual(collectorUpdates.count, 1)
        XCTAssertNil(fixture.viewModel.completedOAuthLoginProvider)
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth login was cancelled.")
    }

    func testReplacementLateOAuthSessionOwnsExactlyOnceFinalRefresh() async {
        let fixture = await lateActionRefreshOAuthFixture()
        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.proxyService.releaseRestart(1)
        let didSuspendActionUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        XCTAssertTrue(didSuspendActionUsage)

        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await waitForOAuthReconciliation(fixture.authStore)
        fixture.viewModel.cancelOAuthLogin()
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await waitForOAuthInvocations(fixture.oauthLoginService, expectedCount: 2)

        await fixture.quotaClient.releaseActionUsage()
        let reachedConfigurationRestart = await fixture.proxyService.reachesRestartCount(2)
        let usageBeforeConfigurationRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeConfigurationRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(reachedConfigurationRestart)
        XCTAssertEqual(usageBeforeConfigurationRestart, [[fixture.claude.id], [fixture.claude.id]])
        XCTAssertEqual(resetsBeforeConfigurationRestart, [])

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await waitForOAuthCompletion(fixture.viewModel)
        let didRequestFinalReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)

        let usageProfileIDSets = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetProfileIDSets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertTrue(didRequestFinalReset)
        XCTAssertEqual(
            usageProfileIDSets,
            [[fixture.claude.id], [fixture.claude.id], [fixture.claude.id, fixture.codex.id]]
        )
        XCTAssertEqual(resetProfileIDSets, [[fixture.codex.id]])
        XCTAssertEqual(collectorUpdates.count, 1)
        XCTAssertEqual(fixture.viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth connection was updated.")
    }

    func testArmedPollWakeQueuesChangedProfilesDuringReconciledOAuthRestart() async {
        let oauth = SuspendedOAuthLoginService()
        let fixture = configurationWorkOAuthFixture(
            oauthLoginService: oauth,
            suspendedRestartCount: 1
        )
        await fixture.viewModel.refreshSubscriptionUsage()
        await fixture.sleeper.waitForSleeps(expectedCount: 1)

        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitUntilStarted()
        oauth.complete()
        await waitForOAuthReconciliation(fixture.authStore)
        let reachedRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedRestart)

        await fixture.sleeper.resumeNext()
        for _ in 0..<10 { await Task.yield() }

        let usageBeforeRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let delaysBeforeRestart = await fixture.sleeper.delays()
        XCTAssertEqual(usageBeforeRestart, [[fixture.claude.id]])
        XCTAssertEqual(resetsBeforeRestart, [])
        XCTAssertEqual(delaysBeforeRestart.count, 1)

        fixture.proxyService.releaseRestart(1)
        await waitForOAuthCompletion(fixture.viewModel)
        let didRefreshUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        let didRefreshReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        XCTAssertTrue(didRefreshUsage)
        XCTAssertTrue(didRefreshReset)

        let finalUsage = await fixture.quotaClient.requestedUsageProfileIDSets()
        let finalResets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(finalUsage, [[fixture.claude.id], [fixture.claude.id, fixture.codex.id]])
        XCTAssertEqual(finalResets, [[fixture.codex.id]])
    }

    func testForcedManualReloadQueuesPriorityDuringOAuthConfigurationWork() async {
        let oauth = SuspendedOAuthLoginService()
        let fixture = configurationWorkOAuthFixture(
            oauthLoginService: oauth,
            suspendedRestartCount: 1,
            initialUsageReport: SubscriptionUsageReport(
                statesByProfileID: ["claude-existing.json": .unavailable(.credentialExpired)],
                fetchedAt: Date(timeIntervalSince1970: 10)
            )
        )
        await fixture.viewModel.refreshSubscriptionUsage()

        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitUntilStarted()
        oauth.complete()
        await waitForOAuthReconciliation(fixture.authStore)
        let reachedRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedRestart)

        await fixture.viewModel.reloadSubscriptionUsage()

        let usageBeforeRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(usageBeforeRestart, [[fixture.claude.id]])
        XCTAssertEqual(resetsBeforeRestart, [])

        fixture.proxyService.releaseRestart(1)
        await waitForOAuthCompletion(fixture.viewModel)
        let didRefreshUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        let didRefreshReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        XCTAssertTrue(didRefreshUsage)
        XCTAssertTrue(didRefreshReset)

        let finalUsage = await fixture.quotaClient.requestedUsageProfileIDSets()
        let finalResets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(finalUsage, [[fixture.claude.id], [fixture.claude.id, fixture.codex.id]])
        XCTAssertEqual(finalResets, [[fixture.codex.id]])
    }

    func testConfigurationSupersessionBeforeClientDispatchCancelsStaleSplitWorkAndRequeuesForcedOnce() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldProfile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "old@example.com",
            accountID: "acct_old_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        let newProfile = AuthProfile(
            fileName: oldProfile.fileName,
            type: oldProfile.type,
            email: "new@example.com",
            accountID: "acct_new_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: oldProfile.id,
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [oldProfile])
        let quotaClient = DispatchControlledConcurrentSubscriptionQuotaClient(
            cancellationMode: .aware,
            suspendFirstUsage: true,
            suspendFirstReset: true
        )
        let proxyService = ContinuationProxyService()
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            oldProfile.id: resetCreditSnapshot(profileID: oldProfile.id, fetchedAt: now)
        ])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { now },
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let reload = Task { await viewModel.reloadSubscriptionUsage() }
        await quotaClient.waitForUsageEntries(1)
        await quotaClient.waitForResetEntries(1)

        authStore.nextProfiles = [newProfile]
        viewModel.refreshProfiles()
        var updatedCodex = config.oauthCommandProfiles[0].codex!
        updatedCodex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: updatedCodex)
        await proxyService.waitForRestart(1)

        quotaClient.releaseFirstUsageDispatch()
        quotaClient.releaseFirstResetDispatch()
        await quotaClient.waitForUsageCompletions(1)
        await quotaClient.waitForResetCompletions(1)

        let staleUsageDispatches = await quotaClient.actualUsageDispatches()
        let staleResetDispatches = await quotaClient.actualResetDispatches()
        XCTAssertEqual(staleUsageDispatches, [])
        XCTAssertEqual(staleResetDispatches, [])

        await proxyService.resolveRestart(1)
        await quotaClient.waitForActualUsage(1)
        await quotaClient.waitForActualReset(1)
        await reload.value

        let usageDispatches = await quotaClient.actualUsageDispatches()
        let resetDispatches = await quotaClient.actualResetDispatches()
        XCTAssertEqual(usageDispatches.count, 1)
        XCTAssertEqual(resetDispatches.count, 1)
        XCTAssertEqual(usageDispatches[0].profiles, [newProfile])
        XCTAssertEqual(resetDispatches[0].profiles, [newProfile])
        XCTAssertEqual(usageDispatches[0].usageProfileIDs, [newProfile.id])
        XCTAssertEqual(resetDispatches[0].resetCreditsProfileIDs, [newProfile.id])
    }

    func testCancellationResistantStaleResetAttemptCannotSuppressStableGenerationReset() async throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let oldProfile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "old@example.com",
            accountID: "acct_old_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        let newProfile = AuthProfile(
            fileName: oldProfile.fileName,
            type: oldProfile.type,
            email: "new@example.com",
            accountID: "acct_new_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        let staleSnapshot = resetCreditSnapshot(
            profileID: oldProfile.id,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let stableSnapshot = resetCreditSnapshot(
            profileID: newProfile.id,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: oldProfile.id,
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [oldProfile])
        let quotaClient = DispatchControlledConcurrentSubscriptionQuotaClient(
            cancellationMode: .resistant,
            suspendFirstReset: true,
            resetReports: [
                SubscriptionUsageReport(
                    statesByProfileID: [:],
                    resetCreditsOutcomesByProfileID: [oldProfile.id: .available(staleSnapshot)],
                    resetCreditsAttemptedProfileIDs: [oldProfile.id],
                    fetchedAt: staleSnapshot.fetchedAt
                ),
                SubscriptionUsageReport(
                    statesByProfileID: [:],
                    resetCreditsOutcomesByProfileID: [newProfile.id: .available(stableSnapshot)],
                    resetCreditsAttemptedProfileIDs: [newProfile.id],
                    fetchedAt: stableSnapshot.fetchedAt
                )
            ]
        )
        let proxyService = ContinuationProxyService()
        let resetCache = CodexResetCreditsSnapshotCacheDouble()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { now },
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await quotaClient.waitForResetEntries(1)

        authStore.nextProfiles = [newProfile]
        viewModel.refreshProfiles()
        var updatedCodex = config.oauthCommandProfiles[0].codex!
        updatedCodex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: updatedCodex)
        await proxyService.waitForRestart(1)

        quotaClient.releaseFirstResetDispatch()
        await quotaClient.waitForResetCompletions(1)
        let staleReportWasDiscarded = viewModel.codexResetCreditsSnapshots.isEmpty
            && resetCache.storedSnapshots().isEmpty
        XCTAssertTrue(staleReportWasDiscarded)

        await proxyService.resolveRestart(1)
        guard staleReportWasDiscarded else {
            await refresh.value
            return
        }

        await quotaClient.waitForActualReset(2)
        await refresh.value
        let resetDispatches = await quotaClient.actualResetDispatches()
        XCTAssertEqual(resetDispatches.count, 2)
        XCTAssertEqual(resetDispatches[0].profiles, [oldProfile])
        XCTAssertEqual(resetDispatches[1].profiles, [newProfile])
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[newProfile.id], stableSnapshot)
        XCTAssertEqual(resetCache.storedSnapshots()[newProfile.id], stableSnapshot)
    }

    func testLateOAuthReconciliationObservesFailedActionAndRecoversOnOneExplicitRestart() async {
        let restartFailure = NSError(
            domain: "LateActionFailure",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Restart failed"]
        )
        let oauth = SuspendedOAuthLoginService()
        let fixture = configurationWorkOAuthFixture(
            oauthLoginService: oauth,
            restartErrors: [restartFailure, nil],
            suspendedRestartCount: 2
        )
        await fixture.viewModel.prepareUsage()
        await fixture.collector.resetUpdates()
        let baselineDelays = await fixture.sleeper.delays()

        let failedAction = Task { await fixture.viewModel.restartServer() }
        let reachedFailedRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFailedRestart)
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitUntilStarted()

        fixture.proxyService.releaseRestart(1)
        await failedAction.value
        XCTAssertEqual(fixture.viewModel.serverStatus.severity, .error)
        XCTAssertEqual(fixture.viewModel.serverStatus.message, "Restart failed")

        oauth.complete()
        await waitForOAuthCompletion(fixture.viewModel)

        let usageAfterFailure = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsAfterFailure = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorAfterFailure = await fixture.collector.updateConfigurations()
        let delaysAfterFailure = await fixture.sleeper.delays()
        XCTAssertNil(fixture.viewModel.completedOAuthLoginProvider)
        XCTAssertNotEqual(fixture.viewModel.settingsMessage, "Codex OAuth connection was updated.")
        XCTAssertEqual(usageAfterFailure, [[fixture.claude.id]])
        XCTAssertEqual(resetsAfterFailure, [])
        XCTAssertEqual(collectorAfterFailure, [])
        XCTAssertEqual(delaysAfterFailure, baselineDelays)
        XCTAssertEqual(fixture.viewModel.serverStatus.message, "Restart failed")

        let recovery = Task { await fixture.viewModel.restartServer() }
        let reachedRecoveryRestart = await fixture.proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedRecoveryRestart)
        fixture.proxyService.releaseRestart(2)
        await recovery.value
        let didRefreshUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        let didRefreshReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)
        XCTAssertTrue(didRefreshUsage)
        XCTAssertTrue(didRefreshReset)

        let finalUsage = await fixture.quotaClient.requestedUsageProfileIDSets()
        let finalResets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let finalCollectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertEqual(fixture.proxyService.restartPorts.count, 2)
        XCTAssertEqual(finalUsage, [[fixture.claude.id], [fixture.claude.id, fixture.codex.id]])
        XCTAssertEqual(finalResets, [[fixture.codex.id]])
        XCTAssertEqual(finalCollectorUpdates.count, 1)
        XCTAssertNil(fixture.viewModel.completedOAuthLoginProvider)
    }

    func testLateOAuthObservesTerminalSuccessAfterSupersededRestartFailureInSameDrain() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: profile.id,
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [profile])
        let oauth = SuspendedOAuthLoginService()
        let quotaClient = DispatchControlledConcurrentSubscriptionQuotaClient(
            cancellationMode: .aware
        )
        let proxyService = ContinuationProxyService()
        let collector = APIUsageCollectorDouble()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauth,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            codexResetCreditsSnapshotCache: CodexResetCreditsSnapshotCacheDouble(snapshots: [
                profile.id: resetCreditSnapshot(profileID: profile.id, fetchedAt: now)
            ]),
            codexResetCreditsNow: { now },
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running
        await viewModel.prepareUsage()
        await quotaClient.resetRecords()
        await collector.resetUpdates()

        let action = Task { await viewModel.restartServer() }
        await proxyService.waitForRestart(1)
        let login = Task { await viewModel.connectProvider(.codex) }
        await oauth.waitUntilStarted()

        var firstGeneration = config.oauthCommandProfiles[0].codex!
        firstGeneration.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: firstGeneration)
        await proxyService.resolveRestart(1)
        await proxyService.waitForRestart(2)

        var secondGeneration = firstGeneration
        secondGeneration.sonnet = .init(
            model: "gpt-5.6-sol",
            reasoning: .auto,
            fastModeEnabled: true
        )
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: secondGeneration)
        await proxyService.resolveRestart(2, errorMessage: "Intermediate restart failed")
        await proxyService.waitForRestart(3)

        oauth.complete()
        await authStore.waitForDisabledIDUpdateCount(1)
        await proxyService.resolveRestart(3)
        await action.value
        await login.value

        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertTrue(viewModel.serverControlState.isRunning)
        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth connection was updated.")
        XCTAssertEqual(oauth.invocationCount, 1)
        guard viewModel.completedOAuthLoginProvider == .codex else { return }

        await quotaClient.waitForActualUsage(1)
        await collector.waitForUpdateCount(1)
        let usageDispatches = await quotaClient.actualUsageDispatches()
        let collectorUpdates = await collector.updateConfigurations()
        XCTAssertEqual(usageDispatches.count, 1)
        XCTAssertEqual(usageDispatches[0].profiles, [profile])
        XCTAssertEqual(collectorUpdates.count, 1)
        let restartPorts = await proxyService.recordedRestartPorts()
        XCTAssertEqual(restartPorts.count, 3)
    }

    func testNewerDifferentReasonSuccessClearsSupersededFastFailureOwnership() async throws {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false,
            prefix: "codex-account"
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: profile.id,
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let quotaClient = DispatchControlledConcurrentSubscriptionQuotaClient(
            cancellationMode: .aware
        )
        let proxyService = ContinuationProxyService()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [profile]),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let action = Task { await viewModel.restartServer() }
        await proxyService.waitForRestart(1)
        var fastGeneration = config.oauthCommandProfiles[0].codex!
        fastGeneration.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: fastGeneration)
        await proxyService.resolveRestart(1)
        await proxyService.waitForRestart(2)

        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        await proxyService.resolveRestart(2, errorMessage: "Fast restart failed")
        await proxyService.waitForRestart(3)
        await proxyService.resolveRestart(3)
        await action.value

        let usageDispatches = await quotaClient.actualUsageDispatches()
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertTrue(viewModel.serverControlState.isRunning)
        XCTAssertNil(viewModel.settingsMessage)
        XCTAssertEqual(usageDispatches.count, 1)
        guard usageDispatches.count == 1 else { return }
        XCTAssertEqual(usageDispatches[0].profiles, [profile])
        let restartPorts = await proxyService.recordedRestartPorts()
        XCTAssertEqual(restartPorts.count, 3)
    }

    func testPreReconciliationOAuthDoesNotSuppressActionOrPollingAfterImmediateCancel() async {
        let oauth = DeferredCancellationOAuthLoginService()
        let fixture = configurationWorkOAuthFixture(oauthLoginService: oauth)
        await fixture.viewModel.prepareUsage()
        await fixture.collector.resetUpdates()
        await fixture.sleeper.waitForSleeps(expectedCount: 1)

        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitForInvocationCount(1)
        await fixture.viewModel.restartServer()
        let didRunActionUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)
        await fixture.sleeper.waitForSleeps(expectedCount: 2)
        XCTAssertTrue(didRunActionUsage)

        fixture.viewModel.cancelOAuthLogin()
        XCTAssertNil(fixture.viewModel.activeOAuthLoginProvider)
        XCTAssertFalse(fixture.viewModel.isProfileLoginInProgress)

        await fixture.sleeper.resumeNext()
        let didRunPollingUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 3)
        let collectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertTrue(didRunPollingUsage)
        XCTAssertEqual(collectorUpdates.count, 1)

        oauth.releaseInvocation(at: 0)
    }

    func testCancelledStaleOAuthTaskCannotReleaseReplacementReconciledOwnership() async {
        let oauth = DeferredCancellationOAuthLoginService()
        let fixture = configurationWorkOAuthFixture(
            oauthLoginService: oauth,
            suspendedRestartCount: 2
        )
        await fixture.viewModel.prepareUsage()
        await fixture.collector.resetUpdates()

        let serverAction = Task { await fixture.viewModel.restartServer() }
        let reachedFirstRestart = await fixture.proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitForInvocationCount(1)
        fixture.viewModel.cancelOAuthLogin()
        fixture.viewModel.startOAuthLogin(providerType: .codex)
        await oauth.waitForInvocationCount(2)

        oauth.releaseInvocation(at: 1)
        await waitForOAuthReconciliation(fixture.authStore)
        oauth.releaseInvocation(at: 0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.viewModel.activeOAuthLoginProvider, .codex)
        XCTAssertTrue(fixture.viewModel.isProfileLoginInProgress)

        fixture.proxyService.releaseRestart(1)
        let reachedSecondRestart = await fixture.proxyService.reachesRestartCount(2)
        let usageBeforeRestart = await fixture.quotaClient.requestedUsageProfileIDSets()
        let resetsBeforeRestart = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertEqual(usageBeforeRestart, [[fixture.claude.id]])
        XCTAssertEqual(resetsBeforeRestart, [])

        fixture.proxyService.releaseRestart(2)
        await serverAction.value
        await waitForOAuthCompletion(fixture.viewModel)
        let didRefreshUsage = await fixture.quotaClient.waitForUsageRequests(expectedCount: 2)
        let didRefreshReset = await fixture.quotaClient.waitForResetRequests(expectedCount: 1)
        await waitForAPIUsageUpdates(fixture.collector, expectedCount: 1)
        XCTAssertTrue(didRefreshUsage)
        XCTAssertTrue(didRefreshReset)

        let finalUsage = await fixture.quotaClient.requestedUsageProfileIDSets()
        let finalResets = await fixture.quotaClient.requestedResetCreditProfileIDSets()
        let collectorUpdates = await fixture.collector.updateConfigurations()
        XCTAssertEqual(finalUsage, [[fixture.claude.id], [fixture.claude.id, fixture.codex.id]])
        XCTAssertEqual(finalResets, [[fixture.codex.id]])
        XCTAssertEqual(collectorUpdates.count, 1)
        XCTAssertEqual(fixture.viewModel.completedOAuthLoginProvider, .codex)
        XCTAssertEqual(fixture.viewModel.settingsMessage, "Codex OAuth connection was updated.")
    }

    func testStartupPrunesStaleCommandProfileAndReinstallsShellWithoutIt() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "stale-codex",
                provider: .codex,
                authProfileID: "missing.json",
                commandName: "stale-command",
                codex: .default,
                modelPrefix: "codex-stale"
            )
        ]
        let store = StubConfigStore(config: config)
        let shellInstaller = StubShellInstaller()

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: shellInstaller,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(viewModel.config.oauthCommandProfiles.isEmpty)
        XCTAssertTrue(store.savedConfigs.last?.oauthCommandProfiles.isEmpty == true)
        XCTAssertFalse(shellInstaller.installedFunctionNames.contains("stale-command"))
        XCTAssertFalse(shellInstaller.installedScript?.contains("stale-command") == true)
    }

    func testAuthProfileLoadFailureDoesNotPrunePersistOrRewriteShellFunctions() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "kept-codex",
                provider: .codex,
                authProfileID: "kept.json",
                commandName: "kept-command",
                codex: .default
            )
        ]
        let store = StubConfigStore(config: config)
        let shellInstaller = StubShellInstaller()
        let authStore = ThrowingAuthProfileStore(error: CocoaError(.fileReadNoSuchFile))

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: shellInstaller,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.id), ["kept-codex"])
        XCTAssertTrue(store.savedConfigs.isEmpty)
        XCTAssertEqual(shellInstaller.installCount, 0)
    }

    func testConfigLoadFailureDoesNotPersistOrRewriteShellFunctions() {
        let store = StubConfigStore(
            config: .default,
            loadError: NSError(
                domain: "ConfigLoad",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Read failed"]
            )
        )
        let shellInstaller = StubShellInstaller()

        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: shellInstaller,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(
                    fileName: "claude.json",
                    type: .claude,
                    email: "account@example.com",
                    accountID: nil,
                    expired: nil,
                    disabled: false
                )
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(viewModel.config.oauthCommandProfiles.isEmpty)
        XCTAssertTrue(store.savedConfigs.isEmpty)
        XCTAssertEqual(shellInstaller.installCount, 0)
        XCTAssertEqual(viewModel.settingsMessage, "Config could not be loaded: Read failed")
    }

    func testFutureSchemaLoadKeepsDashboardConfigReadOnlyAcrossSavesAndRefresh() {
        let store = StubConfigStore(
            config: .default,
            loadError: AppConfigStoreError.unsupportedSchemaVersion(AppConfig.currentSchemaVersion + 1)
        )
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(
                    fileName: "claude.json",
                    type: .claude,
                    email: "account@example.com",
                    accountID: nil,
                    expired: nil,
                    disabled: false
                )
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        let message = "This config was created by a newer app version and is read-only here."

        XCTAssertThrowsError(try viewModel.savePort(18_888)) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite(message))
        }
        viewModel.refreshProfiles()

        XCTAssertTrue(store.savedConfigs.isEmpty)
        XCTAssertTrue(viewModel.config.oauthCommandProfiles.isEmpty)
    }

    func testMigrationSaveFailureKeepsInMemoryCanonicalConfigAndReportsError() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "stale-codex",
                provider: .codex,
                authProfileID: "missing.json",
                commandName: "stale-command",
                codex: .default
            )
        ]
        let store = StubConfigStore(
            config: config,
            saveError: CocoaError(.fileWriteUnknown)
        )
        let shellInstaller = StubShellInstaller()

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: shellInstaller,
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(viewModel.config.oauthCommandProfiles.isEmpty)
        XCTAssertEqual(store.config.oauthCommandProfiles.map(\.id), ["stale-codex"])
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Config migration failed:") == true)
        XCTAssertFalse(shellInstaller.installedFunctionNames.contains("stale-command"))
    }

    func testInitialCodexCredentialMigrationPreservesSettingsRoundRobinAndUsageCache() throws {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.6-terra", reasoning: .max, fastModeEnabled: true),
            sonnet: .init(model: "gpt-5.5", reasoning: .high),
            haiku: .init(model: "gpt-5.4", reasoning: .low)
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex-personal",
                provider: .codex,
                authProfileID: oldID,
                commandName: "ccpersonal",
                nickname: "Personal",
                accountDetailHidden: false,
                dangerousPermissionsEnabled: true,
                codex: codex,
                modelPrefix: "codex-personal",
                isEnabled: true
            )
        ]
        config.roundRobinProfiles = [
            .init(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccround",
                includedAuthProfileIDs: [oldID, newID, oldID],
                codex: codex
            )
        ]
        config.accountOrder = ["codex-personal", "codex-api"]
        let oldSnapshot = SubscriptionUsageSnapshot(
            profileID: oldID,
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 20, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        let newerSnapshot = SubscriptionUsageSnapshot(
            profileID: newID,
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 30, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 20)
        )
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [
            oldID: oldSnapshot,
            newID: newerSnapshot
        ])
        let oldReset = resetCreditSnapshot(profileID: oldID, fetchedAt: Date(timeIntervalSince1970: 10))
        let newReset = resetCreditSnapshot(profileID: newID, fetchedAt: Date(timeIntervalSince1970: 20))
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            oldID: oldReset,
            newID: newReset
        ])
        let authStore = MigratingAuthProfileStore(
            before: [AuthProfile(fileName: oldID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false, prefix: "codex-personal")],
            after: [AuthProfile(fileName: newID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false, prefix: "codex-personal")],
            migrations: [.init(oldID: oldID, newID: newID)]
        )
        let store = StubConfigStore(config: config)

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionUsageSnapshotCache: cache,
            codexResetCreditsSnapshotCache: resetCache,
            secretStore: InMemorySecretStore()
        )

        let migrated = try XCTUnwrap(store.savedConfigs.first)
        let profile = try XCTUnwrap(migrated.oauthCommandProfiles.first)
        XCTAssertEqual(profile.id, "codex-personal")
        XCTAssertEqual(profile.authProfileID, newID)
        XCTAssertEqual(profile.commandName, "ccpersonal")
        XCTAssertEqual(profile.nickname, "Personal")
        XCTAssertEqual(profile.accountDetailHidden, false)
        XCTAssertEqual(profile.dangerousPermissionsEnabled, true)
        XCTAssertEqual(profile.codex, codex)
        XCTAssertEqual(profile.modelPrefix, "codex-personal")
        XCTAssertEqual(profile.isEnabled, true)
        XCTAssertEqual(migrated.roundRobinProfiles.first?.includedAuthProfileIDs, [newID])
        XCTAssertEqual(migrated.accountOrder, ["codex-personal", "codex-api"])
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.authProfileID, newID)
        XCTAssertEqual(authStore.finalizedMigrations, [.init(oldID: oldID, newID: newID)])
        XCTAssertEqual(cache.load(), [newID: newerSnapshot])
        XCTAssertEqual(resetCache.load(), [newID: newReset])
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots, [newID: newReset])
    }

    func testLiveCodexCredentialMigrationUsesAuthoritativeMappingWhenConfigIsUnchanged() async throws {
        let oldID = "codex-old-user@example.com.json"
        let newID = "codex-new-user@example.com.json"
        let oldProfile = AuthProfile(
            fileName: oldID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let newProfile = AuthProfile(
            fileName: newID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let oldReset = resetCreditSnapshot(
            profileID: oldID,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let newReset = resetCreditSnapshot(
            profileID: newID,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(
                statesByProfileID: [
                    oldID: availableUsageState(for: oldProfile),
                    newID: availableUsageState(for: newProfile)
                ],
                resetCreditsOutcomesByProfileID: [
                    oldID: .available(oldReset),
                    newID: .available(newReset)
                ],
                fetchedAt: Date(timeIntervalSince1970: 1_000)
            )
        ])
        let authStore = LoginMigratingAuthProfileStore(
            initial: [oldProfile, newProfile],
            afterLogin: [newProfile],
            migration: .init(oldID: oldID, newID: newID)
        )
        let configStore = StubConfigStore(
            loadError: NSError(domain: "test", code: 1)
        )
        let resetCache = CodexResetCreditsSnapshotCacheDouble()
        let viewModel = DashboardViewModel(
            configStore: configStore,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { Date(timeIntervalSince1970: 1_000) },
            secretStore: InMemorySecretStore()
        )
        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await viewModel.prepareUsage()
        authStore.completeLogin()

        viewModel.refreshProfiles()

        let migrated = try XCTUnwrap(viewModel.codexResetCreditsSnapshots[newID])
        XCTAssertEqual(migrated.profileID, newID)
        XCTAssertEqual(migrated.fetchedAt, oldReset.fetchedAt)
        XCTAssertNil(viewModel.codexResetCreditsSnapshots[oldID])
        XCTAssertEqual(resetCache.load(), [newID: migrated])
    }

    func testLiveCodexCredentialMigrationKeepsAccountRowWhenPostFinalizeReloadsFail() throws {
        let oldID = "codex-old-user@example.com.json"
        let newID = "codex-new-user@example.com.json"
        let oldProfile = AuthProfile(
            fileName: oldID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let newProfile = AuthProfile(
            fileName: newID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "codex-personal", provider: .codex, authProfileID: oldID)
        ]
        let authStore = LoginMigratingAuthProfileStore(
            initial: [oldProfile],
            afterLogin: [newProfile],
            migration: .init(oldID: oldID, newID: newID),
            failReloadsAfterFinalization: true
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        XCTAssertNotNil(viewModel.providerRows.first { $0.id.rawValue == "codex-personal" })
        authStore.completeLogin()

        viewModel.refreshProfiles()

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.authProfileID, newID)
        let row = try XCTUnwrap(viewModel.providerRows.first { $0.id.rawValue == "codex-personal" })
        XCTAssertEqual(row.authProfileID, newID)
        XCTAssertTrue(row.isConnected)
    }

    func testLiveCodexCredentialMigrationPreservesLatestAttemptCollisionUsingAuthoritativeMapping() async {
        let oldID = "codex-old-user@example.com.json"
        let newID = "codex-new-user@example.com.json"
        let oldProfile = AuthProfile(
            fileName: oldID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let newProfile = AuthProfile(
            fileName: newID,
            type: .codex,
            email: "user@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "duplicate", provider: .codex, authProfileID: newID),
            .init(id: "duplicate", provider: .codex, authProfileID: oldID)
        ]
        let initialOldReset = resetCreditSnapshot(
            profileID: oldID,
            fetchedAt: Date(timeIntervalSince1970: 19_900)
        )
        let initialNewReset = resetCreditSnapshot(
            profileID: newID,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let refreshedNewReset = resetCreditSnapshot(
            profileID: newID,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let refreshedOldReset = resetCreditSnapshot(
            profileID: oldID,
            fetchedAt: Date(timeIntervalSince1970: 1_200)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(
                statesByProfileID: [
                    oldID: availableUsageState(for: oldProfile),
                    newID: availableUsageState(for: newProfile)
                ],
                resetCreditsOutcomesByProfileID: [newID: .available(refreshedNewReset)],
                resetCreditsAttemptedProfileIDs: [newID],
                fetchedAt: Date(timeIntervalSince1970: 20_000)
            ),
            .init(
                statesByProfileID: [
                    oldID: availableUsageState(for: oldProfile),
                    newID: availableUsageState(for: newProfile)
                ],
                resetCreditsOutcomesByProfileID: [oldID: .available(refreshedOldReset)],
                resetCreditsAttemptedProfileIDs: [oldID],
                fetchedAt: Date(timeIntervalSince1970: 30_750)
            ),
            .init(
                statesByProfileID: [newID: availableUsageState(for: newProfile)],
                fetchedAt: Date(timeIntervalSince1970: 31_000)
            )
        ])
        let authStore = LoginMigratingAuthProfileStore(
            initial: [oldProfile, newProfile],
            afterLogin: [newProfile],
            migration: .init(oldID: oldID, newID: newID)
        )
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            oldID: initialOldReset,
            newID: initialNewReset
        ])
        let now = MutableDateProvider(Date(timeIntervalSince1970: 20_000))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [oldProfile, newProfile],
            authProfileStore: authStore,
            quotaClient: quotaClient,
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { now.now() }
        )
        await viewModel.refreshSubscriptionUsage()
        now.set(Date(timeIntervalSince1970: 30_750))
        await viewModel.refreshSubscriptionUsage()
        authStore.completeLogin()
        viewModel.refreshProfiles()
        now.set(Date(timeIntervalSince1970: 31_000))

        await viewModel.refreshSubscriptionUsage()

        let requestedResetIDs = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetIDs, [Set([newID]), Set([oldID]), []])
    }

    func testInitialCodexCredentialMigrationRestoresConfigWhenFinalizationFails() {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-personal", provider: .codex, authProfileID: oldID, commandName: "ccpersonal")
        ]
        let originalSnapshot = SubscriptionUsageSnapshot(
            profileID: oldID,
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 20, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [oldID: originalSnapshot])
        let originalReset = resetCreditSnapshot(profileID: oldID, fetchedAt: Date(timeIntervalSince1970: 10))
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [oldID: originalReset])
        let authStore = MigratingAuthProfileStore(
            before: [AuthProfile(fileName: oldID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            after: [AuthProfile(fileName: newID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            migrations: [.init(oldID: oldID, newID: newID)],
            finalizeError: NSError(domain: "test", code: 1)
        )
        let store = StubConfigStore(config: config)

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            subscriptionUsageSnapshotCache: cache,
            codexResetCreditsSnapshotCache: resetCache,
            secretStore: InMemorySecretStore()
        )

        XCTAssertGreaterThanOrEqual(store.savedConfigs.count, 2)
        XCTAssertEqual(store.savedConfigs.first?.oauthCommandProfiles.first?.authProfileID, newID)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first?.authProfileID, oldID)
        XCTAssertEqual(store.config.oauthCommandProfiles.first?.authProfileID, oldID)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.authProfileID, oldID)
        XCTAssertEqual(cache.load(), [oldID: originalSnapshot])
        XCTAssertEqual(resetCache.load(), [oldID: originalReset])
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots, [oldID: originalReset])
        XCTAssertEqual(authStore.rolledBackMigrations, [.init(oldID: oldID, newID: newID)])
    }

    func testInitialCodexCredentialMigrationHandlesDuplicateCommandProfileIDs() {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "duplicate", provider: .codex, authProfileID: oldID),
            .init(id: "duplicate", provider: .codex, authProfileID: oldID)
        ]
        let authStore = MigratingAuthProfileStore(
            before: [AuthProfile(fileName: oldID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            after: [AuthProfile(fileName: newID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            migrations: [.init(oldID: oldID, newID: newID)]
        )

        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.map(\.authProfileID), [newID, newID])
    }

    func testInitialCodexCredentialMigrationRollsBackWhenConfigSaveFails() {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "codex-personal", provider: .codex, authProfileID: oldID, commandName: "ccpersonal")
        ]
        let authStore = MigratingAuthProfileStore(
            before: [AuthProfile(fileName: oldID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            after: [AuthProfile(fileName: newID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false)],
            migrations: [.init(oldID: oldID, newID: newID)]
        )
        let store = StubConfigStore(config: config, saveError: NSError(domain: "test", code: 1))

        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.authProfileID, oldID)
        XCTAssertEqual(authStore.rolledBackMigrations, [.init(oldID: oldID, newID: newID)])
        XCTAssertEqual(authStore.finalizedMigrations, [])
    }

    func testCodexCredentialMigrationHandlesDuplicateCommandProfileIDs() {
        var oldConfig = AppConfig.default
        oldConfig.oauthCommandProfiles = [
            .init(id: "duplicate", provider: .codex, authProfileID: "first.json"),
            .init(id: "duplicate", provider: .codex, authProfileID: "second.json")
        ]
        var newConfig = oldConfig
        newConfig.oauthCommandProfiles[0].authProfileID = "migrated.json"

        XCTAssertEqual(
            DashboardViewModel.authProfileIDMapping(from: oldConfig, to: newConfig),
            ["first.json": "migrated.json"]
        )
    }

    func testCodexCredentialMigrationKeepsNewestSnapshotOverLoadingState() {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        let snapshot = SubscriptionUsageSnapshot(
            profileID: newID,
            provider: .codex,
            windows: [.init(id: "primary", label: "Primary", usedPercent: 30, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 20)
        )
        var states: [String: AccountSubscriptionUsageState] = [:]
        states[newID] = .available(snapshot)
        states[oldID] = .loading

        let migrated = DashboardViewModel.remappingSubscriptionUsageStates(
            states,
            using: [oldID: newID]
        )

        XCTAssertEqual(migrated, [newID: .available(snapshot)])
    }

    func testReconnectMigratedCodexCredentialKeepsExistingCommandProfile() async {
        let oldID = "codex-user@example.com-pro.json"
        let newID = "codex-182d1cfd-user@example.com-pro.json"
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "codex-personal",
                provider: .codex,
                authProfileID: oldID,
                commandName: "ccpersonal",
                nickname: "Personal",
                modelPrefix: "codex-personal"
            )
        ]
        let authStore = LoginMigratingAuthProfileStore(
            initial: [AuthProfile(fileName: oldID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false, prefix: "codex-personal")],
            afterLogin: [AuthProfile(fileName: newID, type: .codex, email: "user@example.com", accountID: "acct_123", expired: nil, disabled: false, prefix: "codex-personal")],
            migration: .init(oldID: oldID, newID: newID)
        )
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore()
        )
        authStore.completeLogin()

        await viewModel.connectProvider(ProviderRowState.ID(rawValue: "codex-personal"))

        XCTAssertEqual(viewModel.config.oauthCommandProfiles.count, 1)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.id, "codex-personal")
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.authProfileID, newID)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.commandName, "ccpersonal")
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first?.nickname, "Personal")
        XCTAssertEqual(viewModel.completedOAuthLoginProvider, ProviderRowState.ID(rawValue: "codex-personal"))
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
        let authStore = StubAuthProfileStore(
            profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ],
            supportsIDDelete: true
        )
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

        XCTAssertEqual(authStore.deletedIDs, ["claude.json"])
        XCTAssertEqual(authStore.deleteInvocations, [])
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
        XCTAssertEqual(Set(viewModel.providerRows.map(\.authProfileID)), Set(["claude-work.json", "claude-personal.json"]))
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
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles, [])
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: false, modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", accountDetailHidden: false, codex: .default, modelPrefix: "codex-account")
        ]
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

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .claude }?.accountDetailHidden, true)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .codex }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.provider == .claude }?.accountDetailHidden, true)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.provider == .codex }?.accountDetailHidden, false)
    }

    func testRemoveProviderResetsOnlyRemovedCodexAccountPrivacy() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", accountDetailHidden: false, modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", accountDetailHidden: false, codex: .default, modelPrefix: "codex-account")
        ]
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

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .codex }?.accountDetailHidden, true)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.provider == .claude }?.accountDetailHidden, false)
        XCTAssertEqual(viewModel.config.oauthCommandProfiles.first { $0.provider == .codex }?.accountDetailHidden, true)
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc", modelPrefix: "claude-account"),
            AppConfig.OAuthCommandProfile(id: "codex", provider: .codex, authProfileID: "codex.json", commandName: "customcodex", codex: .default, modelPrefix: "codex-account")
        ]
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude", provider: .claude, authProfileID: "claude.json", commandName: "cc", modelPrefix: "claude-account")
        ]
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
        config.claudeAPI.commandName = "ccapi"
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

    func testSavingCodexFastModeRestartsReadyProxy() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        await viewModel.refresh()
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        await waitForRestart(proxyService)

        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testPendingUpdateReadinessFailureDoesNotReportSuccess() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost))),
                timeout: 0.1
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardPendingUpdateReadinessTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        let updateStore = DashboardUpdateBinaryStore()
        let updateService = CLIProxyAPIUpdateService(
            paths: ManagedPaths(rootDirectory: sandbox),
            checker: DashboardUpdateChecker(),
            store: updateStore
        )

        await viewModel.applyCLIProxyAPIPendingUpdate(using: updateService)

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("CLIProxyAPI update failed:") == true)
        XCTAssertNotEqual(viewModel.settingsMessage, "CLIProxyAPI binary updated. Restarting the app is not required.")
    }

    func testPendingUpdateWaitsForConfigurationRestartThenPerformsRequiredRestartBeforeSuccess() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 2)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        let reachedFirstRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardPendingUpdateTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        let updateStore = DashboardUpdateBinaryStore()
        let updateService = CLIProxyAPIUpdateService(
            paths: ManagedPaths(rootDirectory: sandbox),
            checker: DashboardUpdateChecker(),
            store: updateStore
        )
        let updateTask = Task { await viewModel.applyCLIProxyAPIPendingUpdate(using: updateService) }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(updateStore.applyPendingCallCount, 1)
        XCTAssertNil(viewModel.settingsMessage)
        XCTAssertEqual(proxyService.restartPorts, [config.port])

        proxyService.releaseRestart(1)
        let reachedSecondRestart = await proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedSecondRestart)
        XCTAssertNil(viewModel.settingsMessage)

        proxyService.releaseRestart(2)
        await updateTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port, config.port])
        XCTAssertEqual(viewModel.settingsMessage, "CLIProxyAPI binary updated. Restarting the app is not required.")
    }

    func testManualStopQueuedDuringConfigurationRestartRunsAfterRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        let reachedRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedRestart)

        let stopTask = Task { await viewModel.stopServer() }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(proxyService.stopCount, 0)
        proxyService.releaseRestart(1)
        await stopTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(proxyService.stopCount, 1)
    }

    func testManualRestartQueuedDuringConfigurationRestartRunsAfterRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        let reachedRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedRestart)

        let restartTask = Task { await viewModel.restartServer() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(proxyService.restartPorts, [config.port])

        proxyService.releaseRestart(1)
        await restartTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port, config.port])
    }

    func testStoppedProxyDoesNotRestartAfterFastModeSave() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector()
        )
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)

        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testSavingReasoningWithoutChangingFastSnapshotDoesNotRestartProxy() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector()
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.reasoning = .high

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        await Task.yield()

        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testFastAndAPIKeyChangesBeforeRestartTaskRunsCoalesceIntoOneRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        config.codexAPI.commandName = "ccodexapi"
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        try viewModel.saveCodexAPISettings(
            functionName: "ccodexapi",
            codex: config.codexAPI.codex,
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        await waitForRestart(proxyService)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testFastAndAPIKeyChangesDuringStartCoalesceIntoOneRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        config.codexAPI.commandName = "ccodexapi"
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        try await Task.sleep(nanoseconds: 10_000_000)
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        try viewModel.saveCodexAPISettings(
            functionName: "ccodexapi",
            codex: config.codexAPI.codex,
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        await startTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testFastChangeDuringRestartDrainsNextGeneration() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(
            suspendedRestartCount: 1,
            startDelayNanoseconds: 50_000_000
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        for _ in 0..<100 where !viewModel.isServerActionInProgress { await Task.yield() }
        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        let reachedFirstRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        proxyService.releaseRestart(1)
        let reachedSecondRestart = await proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedSecondRestart)
        await startTask.value

        XCTAssertEqual(proxyService.restartPorts, [config.port, config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testFastChangeDuringFailingAPIKeyRestartShowsFastFailureAndClearsPending() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(
            restartErrors: [
                NSError(domain: "APIKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key restart failed"]),
                NSError(domain: "FastMode", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fast restart failed"])
            ],
            suspendedRestartCount: 1,
            startDelayNanoseconds: 50_000_000
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )

        let startTask = Task { await viewModel.startServer() }
        for _ in 0..<100 where !viewModel.isServerActionInProgress { await Task.yield() }
        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        let reachedFirstRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        proxyService.releaseRestart(1)
        let reachedSecondRestart = await proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedSecondRestart)
        await startTask.value
        for _ in 0..<100 where viewModel.settingsMessage == nil { await Task.yield() }

        XCTAssertEqual(
            viewModel.settingsMessage,
            "Fast mode settings were saved, but CLIProxyAPI could not restart: Fast restart failed"
        )
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "Failed to restart CLIProxyAPI")
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, .error)
    }

    func testLaterSuccessfulFastGenerationClearsOwnedFailureMessage() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(
            restartErrors: [
                NSError(domain: "FastMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "First restart failed"]),
                nil
            ],
            suspendedRestartCount: 1
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        var firstGeneration = config.oauthCommandProfiles[0].codex!
        firstGeneration.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: firstGeneration)
        let reachedFirstRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)

        var secondGeneration = firstGeneration
        secondGeneration.sonnet = .init(
            model: "gpt-5.6-sol",
            reasoning: .auto,
            fastModeEnabled: true
        )
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: secondGeneration)
        await Task.yield()
        proxyService.releaseRestart(1)
        let reachedSecondRestart = await proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedSecondRestart)
        for _ in 0..<100 where viewModel.settingsMessage != nil { await Task.yield() }

        XCTAssertNil(viewModel.settingsMessage)
        XCTAssertEqual(proxyService.restartPorts, [config.port, config.port])
    }

    func testExplicitRecoveryRestartPreservesSameReasonChangeQueuedDuringAction() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(
            restartErrors: [
                NSError(domain: "FastMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "First restart failed"]),
                nil,
                nil
            ],
            suspendedRestartCount: 2
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        var firstGeneration = config.oauthCommandProfiles[0].codex!
        firstGeneration.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: firstGeneration)
        let reachedFailedRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFailedRestart)
        proxyService.releaseRestart(1)
        for _ in 0..<1_000 where viewModel.serverControlState != .error("First restart failed") {
            await Task.yield()
        }

        let recovery = Task { await viewModel.restartServer() }
        let reachedRecoveryRestart = await proxyService.reachesRestartCount(2)
        XCTAssertTrue(reachedRecoveryRestart)
        var secondGeneration = firstGeneration
        secondGeneration.sonnet = .init(
            model: "gpt-5.6-sol",
            reasoning: .auto,
            fastModeEnabled: true
        )
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: secondGeneration)

        proxyService.releaseRestart(2)
        let reachedQueuedRestart = await proxyService.reachesRestartCount(3)
        await recovery.value

        XCTAssertTrue(reachedQueuedRestart)
        XCTAssertEqual(proxyService.restartPorts, [config.port, config.port, config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testFastRestartReadinessFailureShowsSettingsMessage() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let healthClient = ProxyHealthClient(
            httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost))),
            timeout: 0.1
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: healthClient,
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        await waitForRestart(proxyService)
        let expectedMessage = "Fast mode settings were saved, but CLIProxyAPI could not restart: Could not connect to the server."
        await waitForSettingsMessage(viewModel, expected: expectedMessage)

        XCTAssertEqual(viewModel.settingsMessage, expectedMessage)
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "Failed to restart CLIProxyAPI")
    }

    func testFastRestartFailureKeepsSavedConfigAndShowsSettingsMessage() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let store = StubConfigStore(config: config)
        let proxyService = StubProxyServiceStarter(
            restartError: NSError(domain: "FastMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Restart failed"])
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true

        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        await waitForRestart(proxyService)
        for _ in 0..<20 where viewModel.settingsMessage == nil { await Task.yield() }

        XCTAssertTrue(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .codex }?.codex?.opus.fastModeEnabled == true)
        XCTAssertEqual(
            viewModel.settingsMessage,
            "Fast mode settings were saved, but CLIProxyAPI could not restart: Restart failed"
        )
    }

    func testSavingCodexAPISettingsWithoutKeyOrFastChangeDoesNotRestart() async throws {
        var config = AppConfig.default
        config.codexAPI.commandName = "ccodexapi"
        let proxyService = StubProxyServiceStarter()
        let secretStore = InMemorySecretStore(values: [.codexAPIKey: "existing-key"])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )
        viewModel.serverControlState = .running
        var codex = config.codexAPI.codex
        codex.opus.reasoning = .high

        try viewModel.saveCodexAPISettings(
            functionName: "ccodexapi",
            codex: codex,
            dangerousPermissionsEnabled: false,
            key: nil
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testAPIKeyReadFailurePreventsSecretConfigAndRestartMutation() async throws {
        var config = AppConfig.default
        config.claudeAPI.commandName = "ccapi"
        let configStore = StubConfigStore(config: config)
        let secretStore = RecordingSecretStore(
            getError: SecretStoreError.readFailed(SecretKey.claudeAPIKey.rawValue)
        )
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: configStore,
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )
        viewModel.serverControlState = .running

        XCTAssertThrowsError(
            try viewModel.saveClaudeAPISettings(
                functionName: "updated-ccapi",
                nickname: "Updated",
                dangerousPermissionsEnabled: false,
                key: "replacement-key"
            )
        ) { error in
            XCTAssertEqual(error as? SecretStoreError, .readFailed(SecretKey.claudeAPIKey.rawValue))
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(secretStore.setValues.isEmpty)
        XCTAssertTrue(secretStore.deleteKeys.isEmpty)
        XCTAssertTrue(configStore.savedConfigs.isEmpty)
        XCTAssertEqual(viewModel.config.claudeAPI.commandName, "ccapi")
        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testSavingClaudeAPISettingsWithoutKeyDoesNotRestart() async throws {
        var config = AppConfig.default
        config.claudeAPI.commandName = "ccapi"
        let proxyService = StubProxyServiceStarter()
        let secretStore = InMemorySecretStore(values: [.claudeAPIKey: "existing-key"])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: secretStore
        )
        viewModel.serverControlState = .running

        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            nickname: "Work",
            dangerousPermissionsEnabled: false,
            key: nil
        )
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testReasoningOnlySaveRejectsExistingManagedAliasCollision() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        config.oauthCommandProfiles[0].codex!.opus = .init(
            model: "gpt-5.6-sol-fast",
            reasoning: .high,
            fastModeEnabled: true
        )
        let proxyService = StubProxyServiceStarter()
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector()
        )
        viewModel.serverControlState = .running
        var updated = config.oauthCommandProfiles[0].codex!
        updated.opus.reasoning = .max

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "ccodex", codex: updated)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-fast"))
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(store.savedConfigs.isEmpty)
        XCTAssertEqual(proxyService.restartPorts, [])
    }

    func testFastAliasRecoverySaveSucceedsAndRequestsRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        config.oauthCommandProfiles[0].codex!.opus = .init(
            model: "gpt-5.6-sol-fast",
            reasoning: .high,
            fastModeEnabled: true
        )
        let store = StubConfigStore(config: config)
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running
        var repaired = config.oauthCommandProfiles[0].codex!
        repaired.opus.model = "gpt-5.6-sol"

        XCTAssertNoThrow(try viewModel.saveCodexSettings(functionName: "ccodex", codex: repaired))
        await waitForRestart(proxyService)

        XCTAssertEqual(store.savedConfigs.last?.oauthCommandProfiles.first { $0.provider == .codex }?.codex?.opus.model, "gpt-5.6-sol")
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testNewFastAliasCollisionThrows() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )
        var invalid = config.oauthCommandProfiles[0].codex!
        invalid.opus = .init(
            model: "gpt-5.6-sol-fast",
            reasoning: .high,
            fastModeEnabled: true
        )

        XCTAssertThrowsError(try viewModel.saveCodexSettings(functionName: "ccodex", codex: invalid)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-fast"))
        }
        XCTAssertTrue(store.savedConfigs.isEmpty)
    }

    func testSavingLogLevelUpdatesAppLoggerWithoutRestartWhenServerIsStopped() throws {
        let config = AppConfig.default
        let logger = RecordingAppLogger()
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            appLogger: logger
        )

        try viewModel.saveLogLevel(.debug)

        XCTAssertEqual(viewModel.config.logLevel, .debug)
        XCTAssertEqual(logger.minimumLevel, .debug)
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
    }

    func testSavingLogLevelRestartsRunningProxyAndAppliesDebugLevel() async throws {
        let config = AppConfig.default
        let logger = RecordingAppLogger()
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8))),
                timeout: 0.1
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            appLogger: logger,
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running

        try viewModel.saveLogLevel(.debug)
        await waitForRestart(proxyService)

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(logger.minimumLevel, .debug)
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testLogLevelRestartFailureReportsRequestedAndAppliedLevels() async throws {
        let config = AppConfig.default
        let logger = RecordingAppLogger()
        let proxyService = StubProxyServiceStarter(
            restartError: NSError(
                domain: "Logging",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Restart failed"]
            )
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            appLogger: logger,
            settingsMessageAutoClearDelayNanoseconds: 60_000_000_000
        )
        viewModel.serverControlState = .running

        try viewModel.saveLogLevel(.debug)
        await waitForRestart(proxyService)
        for _ in 0..<100 where viewModel.settingsMessage == nil { await Task.yield() }

        XCTAssertEqual(
            viewModel.settingsMessage,
            "Log level was saved as Debug. App logging now uses Debug, but CLIProxyAPI remains at Info because restart failed: Restart failed Use Restart Server to retry."
        )
        XCTAssertEqual(viewModel.config.logLevel, .debug)
        XCTAssertEqual(logger.minimumLevel, .debug)
    }

    func testUnrelatedSaveRejectsExistingManagedAliasCollision() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        config.oauthCommandProfiles[0].codex!.opus = .init(
            model: "gpt-5.6-sol-fast",
            reasoning: .high,
            fastModeEnabled: true
        )
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: store,
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertThrowsError(try viewModel.saveLogLevel(.debug)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-fast"))
        }
        XCTAssertTrue(store.savedConfigs.isEmpty)
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

    func testPrepareCodexAPIModelsUsesOnlyScopedDiscoveryWhenServerIsRunning() async {
        let expected = [
            CodexModelOption(
                id: "gpt-5.6-sol",
                supportedReasoning: [.low, .medium, .high, .xhigh, .max]
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
        viewModel.serverControlState = .running

        await viewModel.prepareCodexAPIModels()

        XCTAssertEqual(viewModel.availableCodexAPIModelOptions, expected)
        XCTAssertTrue(modelClient.ports.isEmpty)
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

    func testFastAndAPIKeyChangesDuringModelServerStartCoalesceIntoOneRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let modelClient = StubProxyModelClient(models: ["gpt-5.6-sol"])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let modelTask = Task { await viewModel.refreshCodexModels() }
        for _ in 0..<100 where !viewModel.isServerActionInProgress { await Task.yield() }
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )
        await modelTask.value
        await waitForRestart(proxyService)

        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testModelServerStartFailureClearsPendingConfigurationRestart() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(
            error: NSError(domain: "ModelStart", code: 1, userInfo: [NSLocalizedDescriptionKey: "Start failed"]),
            startDelayNanoseconds: 50_000_000
        )
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: StubProxyModelClient(models: ["gpt-5.6-sol"]),
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "initial-key"])
        )

        let modelTask = Task { await viewModel.refreshCodexModels() }
        for _ in 0..<100 where !viewModel.isServerActionInProgress { await Task.yield() }
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        await modelTask.value
        viewModel.serverControlState = .running
        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            nickname: "Updated",
            dangerousPermissionsEnabled: false,
            key: "recovery-key"
        )
        await waitForRestart(proxyService)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testRefreshCodexModelsWaitsForConfigurationRestartThenLoadsModels() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let modelClient = StubProxyModelClient(models: ["gpt-5.6-sol"])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            modelClient: modelClient,
            authProfileStore: codexAuthProfileStore(),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverControlState = .running
        var codex = config.oauthCommandProfiles[0].codex!
        codex.opus.fastModeEnabled = true
        try viewModel.saveCodexSettings(functionName: "ccodex", codex: codex)
        let reachedFirstRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(reachedFirstRestart)

        let refreshTask = Task { await viewModel.refreshCodexModels() }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(modelClient.ports, [])
        XCTAssertEqual(viewModel.availableCodexModels, [])

        proxyService.releaseRestart(1)
        await refreshTask.value

        XCTAssertEqual(modelClient.ports, [config.port])
        XCTAssertEqual(viewModel.availableCodexModels, ["gpt-5.6-sol"])
        XCTAssertEqual(viewModel.codexModelLoadingState, .idle)
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

    func testPreferredCodexDefaultModelUsesTerraCaseInsensitivelyThenFirstScopedModel() {
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
                CodexModelOption(id: "GPT-5.6-TERRA"),
                CodexModelOption(id: "gpt-5.5")
            ]),
            "GPT-5.6-TERRA"
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
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-work")
            ]),
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
                CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh, .max], defaultReasoning: .low, supportsFastMode: true, contextWindow: 400_000),
                CodexModelOption(id: "gpt-5.5", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium)
            ],
            "codex-personal": [
                CodexModelOption(id: "gpt-5.6-sol", supportedReasoning: [.low, .medium, .high, .xhigh], defaultReasoning: .medium, supportsFastMode: false, contextWindow: 372_000)
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
                defaultReasoning: .medium,
                supportsFastMode: false,
                contextWindow: 372_000
            )
        ])
    }

    func testRoundRobinCodexModelsDoNotTreatPartialContextMetadataAsAuthoritative() async throws {
        let modelClient = StubProxyModelClient(optionsByPrefix: [
            "codex-work": [CodexModelOption(id: "custom-model", contextWindow: 400_000)],
            "codex-personal": [CodexModelOption(id: "custom-model")]
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

        XCTAssertNil(try XCTUnwrap(models.first).contextWindow)
    }

    func testRoundRobinModelPrefixesUseRoutingPrefixFallback() {
        let authProfiles = [
            AuthProfile(fileName: "work.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: " auth-work "),
            AuthProfile(fileName: "personal.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "auth-personal")
        ]
        let commandProfiles = [
            AppConfig.OAuthCommandProfile(id: "work", provider: .codex, authProfileID: "work.json", modelPrefix: "   "),
            AppConfig.OAuthCommandProfile(id: "personal", provider: .codex, authProfileID: "personal.json", modelPrefix: "command-personal")
        ]
        let profile = AppConfig.RoundRobinProfile(
            id: "codex-round-robin",
            provider: .codex,
            includedAuthProfileIDs: ["work.json", "personal.json"]
        )

        XCTAssertEqual(
            DashboardViewModel.roundRobinModelPrefixes(
                for: profile,
                authProfiles: authProfiles,
                commandProfiles: commandProfiles
            ),
            ["auth-work", "command-personal"]
        )
    }

    func testRoundRobinCodexModelsMarkKnownEmptyReasoningIntersectionAuthoritatively() async throws {
        let modelClient = StubProxyModelClient(optionsByPrefix: [
            "codex-work": [CodexModelOption(id: "gpt-5.6", supportedReasoning: [.low])],
            "codex-personal": [CodexModelOption(id: "gpt-5.6", supportedReasoning: [.high])]
        ])
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "work", provider: .codex, authProfileID: "work.json", modelPrefix: "codex-work"),
            .init(id: "personal", provider: .codex, authProfileID: "personal.json", modelPrefix: "codex-personal")
        ]
        let viewModel = DashboardViewModel(
            config: config,
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
        let model = try XCTUnwrap(models.first)

        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(
                currentReasoning: .xhigh,
                model: model.id,
                options: [model]
            ),
            .auto
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .xhigh,
                model: model.id,
                options: [model]
            ),
            [.auto]
        )
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

        XCTAssertEqual(models, [
            CodexModelOption(
                id: "gpt-5.5",
                supportedReasoning: [],
                defaultReasoning: .auto
            )
        ])
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
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, .ready)
    }

    func testStartServerRetriesStatusUntilServerBecomesReady() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, DiagnosticSeverity.ready)
    }

    func testStopServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, .ready)
    }

    func testRestartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, .ready)
    }

    func testRestartServerRetriesStatusUntilServerBecomesReady() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: codexAuthProfileStore(),
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, DiagnosticSeverity.ready)
    }

    func testStartServerFailureUpdatesServerAndCodexCardStatus() async {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                commandName: "ccodex",
                codex: .default,
                modelPrefix: "codex-account"
            )
        ]
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
        XCTAssertEqual(viewModel.cards.first { $0.command == config.oauthCommandProfiles.first?.commandName }?.status.severity, .error)
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testLifecycleActionsRunSequentiallyWithoutOverlapping() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        let startTask = Task { await viewModel.startServer() }
        await waitForServerAction(viewModel)
        let stopTask = Task { await viewModel.stopServer() }
        await startTask.value
        await stopTask.value

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testEnablingHUDAsFirstConsumerCreatesKeyAndRestartsReadyProxy() async throws {
        let config = AppConfig.default
        let store = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxy = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(config: config, configStore: store, keyStore: keyStore, proxyService: proxy)
        await viewModel.refresh()

        try viewModel.saveUsageOverlay(.init(isVisible: true, alwaysOnTop: false, backgroundOpacity: 0.9))
        await waitForRestart(proxy)

        XCTAssertTrue(viewModel.config.usageOverlay.isVisible)
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(proxy.restartPorts, [config.port])
    }

    func testEnablingUsageDuringDelayedStartQueuesExactlyOneRestart() async throws {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService
        )

        let startTask = Task { await viewModel.startServer() }
        await waitForServerAction(viewModel)
        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await startTask.value

        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testDisablingUsageDuringDelayedStartQueuesExactlyOneRestart() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: proxyService
        )

        let startTask = Task { await viewModel.startServer() }
        await waitForServerAction(viewModel)
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await startTask.value

        XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testTurningOffMenuBarKeepsBackendWhenHUDIsVisible() throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.usageOverlay.isVisible = true
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxy = StubProxyServiceStarter()
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: ["saved": .init(
            profileID: "saved", provider: .codex, windows: [], fetchedAt: .distantPast
        )])
        let profile = AuthProfile(fileName: "saved", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        let viewModel = subscriptionUsageViewModel(
            config: config, configStore: StubConfigStore(config: config), keyStore: keyStore,
            proxyService: proxy, profiles: [profile], subscriptionUsageSnapshotCache: cache
        )

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)

        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(viewModel.config.usageOverlay.isVisible)
        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertTrue(proxy.restartPorts.isEmpty)
        XCTAssertFalse(cache.isEmpty)
    }

    func testTurningOffHUDKeepsBackendWhenMenuBarIsVisible() throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.usageOverlay.isVisible = true
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxy = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config, configStore: StubConfigStore(config: config), keyStore: keyStore, proxyService: proxy
        )

        try viewModel.saveUsageOverlay(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))

        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(viewModel.config.usageOverlay.isVisible)
        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(proxy.restartPorts.isEmpty)
    }

    func testDisablingCodexAccountRemovesItsResetCreditSnapshot() {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "codexwork")
        ]
        let profile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let snapshot = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 100))
        let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let authStore = StubAuthProfileStore(profiles: [profile])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            authProfileStore: authStore,
            codexResetCreditsSnapshotCache: cache
        )

        viewModel.setProviderEnabled(.init(rawValue: "codex-work"), enabled: false)

        XCTAssertNil(viewModel.codexResetCreditsSnapshots[profile.id])
        XCTAssertNil(cache.load()[profile.id])
    }

    func testDisablingCodexAccountCleansResetCreditStateWhenProfileReloadFails() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", commandName: "codexwork")
        ]
        let profile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let snapshot = resetCreditSnapshot(
            profileID: profile.id,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(
                statesByProfileID: [profile.id: availableUsageState(for: profile)],
                resetCreditsOutcomesByProfileID: [profile.id: .available(snapshot)],
                fetchedAt: Date(timeIntervalSince1970: 200)
            ),
            .init(
                statesByProfileID: [profile.id: availableUsageState(for: profile)],
                fetchedAt: Date(timeIntervalSince1970: 201)
            )
        ])
        let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let authStore = ReloadFailingAfterDisableAuthProfileStore(profile: profile)
        let now = MutableDateProvider(Date(timeIntervalSince1970: 200))
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            authProfileStore: authStore,
            quotaClient: quotaClient,
            codexResetCreditsSnapshotCache: cache,
            codexResetCreditsNow: { now.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        await viewModel.refreshSubscriptionUsage(force: true)

        viewModel.setProviderEnabled(.init(rawValue: "codex-work"), enabled: false)

        XCTAssertNil(viewModel.codexResetCreditsSnapshots[profile.id])
        XCTAssertNil(cache.load()[profile.id])

        authStore.recoverProfileReloads()
        viewModel.setProviderEnabled(.init(rawValue: "codex-work"), enabled: true)
        now.set(Date(timeIntervalSince1970: 201))
        await viewModel.refreshSubscriptionUsage()
        await waitForUsageFetches(quotaClient, expectedCount: 2)

        let requestedResetIDs = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetIDs, [Set([profile.id]), Set([profile.id])])
    }

    func testTurningOffLastConsumerDeletesKeyClearsCacheAndRestarts() async throws {
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxy = StubProxyServiceStarter()
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: ["saved": .init(
            profileID: "saved", provider: .codex, windows: [], fetchedAt: .distantPast
        )])
        let profile = AuthProfile(
            fileName: "saved", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false
        )
        let resetCreditCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            profile.id: resetCreditSnapshot(profileID: profile.id, fetchedAt: .distantPast)
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config, configStore: StubConfigStore(config: config), keyStore: keyStore,
            proxyService: proxy, profiles: [profile], subscriptionUsageSnapshotCache: cache,
            codexResetCreditsSnapshotCache: resetCreditCache
        )
        await viewModel.refresh()

        try viewModel.saveUsageOverlay(.init(isVisible: false, alwaysOnTop: false, backgroundOpacity: 0.9))
        await waitForRestart(proxy)

        XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertTrue(resetCreditCache.isEmpty)
        XCTAssertTrue(viewModel.codexResetCreditsSnapshots.isEmpty)
        XCTAssertEqual(proxy.restartPorts, [config.port])
    }

    func testPrepareSubscriptionUsageRepairsHUDOnlyEnabledConfigWithMissingKey() async throws {
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxy = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config, configStore: StubConfigStore(config: config), keyStore: keyStore, proxyService: proxy
        )
        await viewModel.refresh()

        await viewModel.prepareUsage()
        await waitForRestart(proxy)

        XCTAssertTrue(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.createCallCount, 1)
    }

    func testResetAllSettingsDoesNotStopUninitializedAPICollectorWhenUsageWasDisabled() async {
        let config = AppConfig.default
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector
        )

        viewModel.resetAllSettings()

        let stopCount = await collector.stopCount()
        XCTAssertEqual(stopCount, 0)
    }

    func testResetAllSettingsTurnsOffBothUsageDisplaysAndDeletesKey() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.usageOverlay = .init(isVisible: true, alwaysOnTop: true, backgroundOpacity: 0.45)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        let proxy = StubProxyServiceStarter()
        let profile = AuthProfile(
            fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false
        )
        let resetCreditCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            profile.id: resetCreditSnapshot(profileID: profile.id, fetchedAt: .distantPast)
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxy,
            profiles: [profile],
            codexResetCreditsSnapshotCache: resetCreditCache
        )
        await viewModel.refresh()

        viewModel.resetAllSettings()
        await waitForRestart(proxy)

        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(viewModel.config.usageOverlay.isVisible)
        XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertTrue(resetCreditCache.isEmpty)
        XCTAssertTrue(viewModel.codexResetCreditsSnapshots.isEmpty)
    }

    func testResetAllSettingsRestartsRunningServerWhenPortReturnsToDefaultWithoutUsageKey() async {
        var config = AppConfig.default
        config.port = 18_888
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxy = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxy
        )
        await viewModel.refresh()

        viewModel.resetAllSettings()
        await waitForRestart(proxy)

        XCTAssertEqual(viewModel.config.port, AppConfig.default.port)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertEqual(proxy.restartPorts, [AppConfig.default.port])
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

        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? false)
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

        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? false)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testDisablingSubscriptionUsageDeletesKeyPersistsDisabledConfigAndRestartsProxy() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? true)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails() {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageMenuBarVisible(false))

        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 0)
    }

    func testResetAllSettingsPreservesIndependentCodexAPISettings() {
        var config = AppConfig.default
        config.codexAPI = .init(
            codex: AppConfig.Codex(
                opus: .init(model: "gpt-5.6", reasoning: .xhigh),
                sonnet: .init(model: "gpt-5.6", reasoning: .medium),
                haiku: .init(model: "gpt-5.6-mini", reasoning: .low)
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
        config.subscriptionUsage.showInMenuBar = true
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

        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(viewModel.settingsMessage?.hasPrefix("Reset failed:") == true)
    }

    func testDisablingLastUsageConsumerFinishesCleanupAndRestartWhenKeyDeletionFails() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        let snapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .codex,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let configStore = StubConfigStore(config: config)
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        keyStore.deleteError = NSError(domain: "SubscriptionUsage", code: 2)
        let proxyService = StubProxyServiceStarter()
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: configStore,
            keyStore: keyStore,
            proxyService: proxyService,
            profiles: [profile],
            subscriptionUsageSnapshotCache: cache
        )
        await viewModel.refresh()

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageMenuBarVisible(false))
        await waitForRestart(proxyService)

        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? true)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .disabled)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(viewModel.lastSuccessfulSubscriptionUsageRefreshAt)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
    }

    func testResetAllSettingsFinishesHUDOnlyCleanupWhenKeyDeletionFails() async {
        var config = AppConfig.default
        config.showDockIcon = false
        config.appearance = .dark
        config.usageOverlay.isVisible = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false)
        let snapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .codex,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let keyStore = SubscriptionUsageManagementKeyDouble(isConfiguredValue: true)
        keyStore.deleteError = NSError(
            domain: "SubscriptionUsage",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Key cleanup failed"]
        )
        let proxyService = StubProxyServiceStarter()
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let appearance = RecordingAppAppearanceService()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxyService,
            profiles: [profile],
            subscriptionUsageSnapshotCache: cache,
            appAppearanceService: appearance
        )
        await viewModel.refresh()

        viewModel.resetAllSettings()
        await waitForRestart(proxyService)

        XCTAssertFalse(viewModel.config.isSubscriptionUsageEnabled)
        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .disabled)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(viewModel.lastSuccessfulSubscriptionUsageRefreshAt)
        XCTAssertEqual(appearance.showDockIconValues.last, AppConfig.default.showDockIcon)
        XCTAssertEqual(appearance.appearanceValues.last, AppConfig.default.appearance)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.settingsMessage, "Reset failed: Key cleanup failed")
    }

    func testStartApplicationRefreshesUsageWhenProxyIsAlreadyReadyWithoutDashboard() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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

    func testStartApplicationRestartsRunningServerAfterBundledBinaryChanges() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let reconciler = BundledProxyReconcilerDouble(
            result: .installed(
                previousVersion: CLIProxyAPIVersion("7.2.72"),
                newVersion: CLIProxyAPIVersion("7.2.91")!
            )
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            bundledProxyReconciler: reconciler
        )

        await viewModel.startApplication()

        XCTAssertEqual(reconciler.callCount, 1)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertTrue(proxyService.reconcilePorts.isEmpty)
        XCTAssertTrue(proxyService.ports.isEmpty)
    }

    func testStartApplicationDoesNotRestartWhenBundledBinaryIsUnchanged() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let reconciler = BundledProxyReconcilerDouble(
            result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!)
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            bundledProxyReconciler: reconciler
        )

        await viewModel.startApplication()

        XCTAssertEqual(reconciler.callCount, 1)
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
        XCTAssertEqual(proxyService.reconcilePorts, [config.port])
    }

    func testStartApplicationReconcilesLegacyRunningProxyConfiguration() async {
        var config = AppConfig.default
        config.autostartServer = true
        let proxyService = StubProxyServiceStarter(reconcileResult: true)
        let reconciler = BundledProxyReconcilerDouble(
            result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!)
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            bundledProxyReconciler: reconciler
        )

        await viewModel.startApplication()

        XCTAssertEqual(proxyService.reconcilePorts, [config.port])
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
        XCTAssertTrue(proxyService.ports.isEmpty)
    }

    func testStartApplicationReportsLocalOnlyReconciliationFailureWithRecoveryAction() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter(
            reconcileError: ProxyServiceError.restartFailed(
                stage: .processLaunch,
                rollbackSucceeded: true
            )
        )
        let reconciler = BundledProxyReconcilerDouble(
            result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!)
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            bundledProxyReconciler: reconciler
        )

        await viewModel.startApplication()

        XCTAssertEqual(proxyService.reconcilePorts, [config.port])
        XCTAssertTrue(viewModel.settingsMessage?.contains("Local-only proxy configuration could not be applied") == true)
        XCTAssertTrue(viewModel.settingsMessage?.contains("Retry Restart Server") == true)
    }

    func testStartApplicationDoesNotRestartStoppedServerAfterBundledBinaryChanges() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let reconciler = BundledProxyReconcilerDouble(
            result: .installed(
                previousVersion: CLIProxyAPIVersion("7.2.72"),
                newVersion: CLIProxyAPIVersion("7.2.91")!
            )
        )
        let healthClient = ProxyHealthClient(
            httpClient: StubHTTPClient(result: .failure(HTTPClientError.timedOut)),
            timeout: 0.01
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            proxyHealthClient: healthClient,
            bundledProxyReconciler: reconciler,
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.startApplication()

        XCTAssertEqual(reconciler.callCount, 1)
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
        XCTAssertEqual(proxyService.reconcilePorts, [config.port])
        XCTAssertTrue(proxyService.ports.isEmpty)
    }

    func testStartApplicationKeepsRunningAfterBundledReconciliationFailure() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let reconciler = BundledProxyReconcilerDouble(error: CocoaError(.fileReadCorruptFile))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            bundledProxyReconciler: reconciler
        )

        await viewModel.startApplication()

        XCTAssertEqual(reconciler.callCount, 1)
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
        XCTAssertEqual(proxyService.reconcilePorts, [config.port])
        XCTAssertTrue(viewModel.settingsMessage?.contains("Bundled CLIProxyAPI update failed") == true)
    }

    func testTerminationCancelsOwnedLaunchDuringSuspendedHealthCheck() async {
        let config = AppConfig.default
        let healthClient = CancellableProxyHealthClientDouble(
            resumedStatus: DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Stopped",
                message: ""
            )
        )
        let proxyService = StubProxyServiceStarter()
        let collector = CancellableLifecycleAPIUsageCollectorDouble(onStop: {})
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            proxyHealthClient: healthClient,
            apiUsageCollector: collector
        )

        let launch = viewModel.beginApplicationLaunch()
        await healthClient.waitUntilSuspended()
        try? await viewModel.prepareForTermination()
        await launch.value

        XCTAssertTrue(proxyService.ports.isEmpty)
        XCTAssertTrue(proxyService.restartPorts.isEmpty)
        let calls = await collector.calls()
        XCTAssertEqual(calls.last, .stop(.applicationTermination))
    }

    func testTerminationCancelsOwnedLaunchDuringUsageRepairRestart() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let proxyService = StubProxyServiceStarter(suspendedRestartCount: 1)
        let collector = CancellableLifecycleAPIUsageCollectorDouble(onStop: {})
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            apiUsageCollector: collector
        )

        let launch = viewModel.beginApplicationLaunch()
        let didReachRestart = await proxyService.reachesRestartCount(1)
        XCTAssertTrue(didReachRestart)
        try? await viewModel.prepareForTermination()
        await launch.value

        XCTAssertEqual(proxyService.restartPorts.count, 1)
        let calls = await collector.calls()
        XCTAssertFalse(calls.contains(.start))
        XCTAssertEqual(calls.last, .stop(.applicationTermination))
    }

    func testTerminationCancelsOwnedLaunchDuringAutostartWithoutAdditionalStart() async {
        var config = AppConfig.default
        config.autostartServer = true
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: .max)
        let collector = CancellableLifecycleAPIUsageCollectorDouble(onStop: {})
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: proxyService,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost)))
            ),
            apiUsageCollector: collector
        )

        let launch = viewModel.beginApplicationLaunch()
        for _ in 0..<1_000 where proxyService.ports.isEmpty { await Task.yield() }
        let startsAtTermination = proxyService.ports.count
        try? await viewModel.prepareForTermination()
        await launch.value

        XCTAssertEqual(startsAtTermination, 1)
        XCTAssertEqual(proxyService.ports.count, startsAtTermination)
        let calls = await collector.calls()
        XCTAssertEqual(calls.last, .stop(.applicationTermination))
    }

    func testPrepareSubscriptionUsageRepairsEnabledConfigWithMissingKeyBeforeFirstRefresh() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let keyStore = SubscriptionUsageManagementKeyDouble()
        let proxyService = StubProxyServiceStarter()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: keyStore,
            proxyService: proxyService
        )
        await viewModel.refresh()

        await viewModel.prepareUsage()
        await waitForRestart(proxyService)

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertTrue(viewModel.config.subscriptionUsage.showInMenuBar)
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

        await viewModel.prepareUsage()

        XCTAssertEqual(keyStore.createCallCount, 0)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testResetAllSettingsDeletesManagementKeyWhenUsageWasEnabled() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? true)
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

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageMenuBarVisible(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
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

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageMenuBarVisible(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 1)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
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

        XCTAssertThrowsError(try viewModel.saveSubscriptionUsageMenuBarVisible(true))

        XCTAssertEqual(keyStore.createCallCount, 1)
        XCTAssertEqual(keyStore.deleteCallCount, 0)
        XCTAssertTrue(keyStore.isConfigured())
        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
    }

    func testRestartFailureKeepsDisabledUsageConfigAndDeletedKey() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await waitForRestart(proxyService)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(configStore.savedConfigs.last?.subscriptionUsage.showInMenuBar ?? true)
        XCTAssertFalse(keyStore.isConfigured())
        XCTAssertEqual(viewModel.serverStatus.title, "Failed to restart CLIProxyAPI")
    }

    func testMenuRefreshDoesNotStartSubscriptionUsageFetch() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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

    func testResetCreditsAutomaticRefreshUsesThreeHourPerAccountThrottle() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let claude = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            availableUsageReport(for: codex, resetCreditsAttemptedProfileIDs: [codex.id]),
            availableUsageReport(for: codex),
            availableUsageReport(for: codex, resetCreditsAttemptedProfileIDs: [codex.id])
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex, claude],
            quotaClient: quota,
            codexResetCreditsNow: { clock.now() }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 100 + 10_799))
        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 100 + 10_800))
        await viewModel.refreshSubscriptionUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [], [codex.id]])
    }

    func testResetPreflightFailureUsesShortRetryAndDoesNotConsumeThreeHourThrottle() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: .unavailable(.schemaMismatch)],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.schemaMismatch)],
                fetchedAt: Date(timeIntervalSince1970: 100)
            ),
            SubscriptionUsageReport(
                statesByProfileID: [:],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 160)
            )
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )

        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 160))
        viewModel.serverStatus = readyStatus()
        await viewModel.refreshSubscriptionUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        let delays = await sleeper.delays()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [codex.id]])
        XCTAssertEqual(delays.first, 60_000_000_000)
    }

    func testTerminalUsageProfileStillRequestsDueResetCreditsWithoutRestartingUsagePolling() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let claude = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let resetSnapshot = resetCreditSnapshot(
            profileID: codex.id,
            fetchedAt: Date(timeIntervalSince1970: 100 + 10_800)
        )
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [
                    codex.id: .unavailable(.schemaMismatch),
                    claude.id: availableUsageState(for: claude)
                ],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 100)
            ),
            availableUsageReport(for: claude),
            SubscriptionUsageReport(
                statesByProfileID: [
                    codex.id: availableUsageState(for: codex),
                    claude.id: availableUsageState(for: claude)
                ],
                resetCreditsOutcomesByProfileID: [codex.id: .available(resetSnapshot)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 100 + 10_800)
            )
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex, claude],
            quotaClient: quota,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 100 + 10_799))
        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 100 + 10_800))
        await viewModel.refreshSubscriptionUsage()

        let requestedProfileIDs = await quota.requestedProfileIDs()
        let requestedUsageProfileIDSets = await quota.requestedUsageProfileIDSets()
        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        let pollingDelays = await sleeper.delays()
        XCTAssertEqual(
            requestedProfileIDs,
            [[codex.id, claude.id], [claude.id], [codex.id, claude.id]]
        )
        XCTAssertEqual(
            requestedUsageProfileIDSets,
            [[codex.id, claude.id], [claude.id], [claude.id]]
        )
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [], [codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .unavailable(.schemaMismatch))
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[codex.id], resetSnapshot)
        XCTAssertEqual(pollingDelays, [300_000_000_000, 1_000_000_000, 300_000_000_000])
    }

    func testEarlierResetCreditWakePreservesLaterUsageDeadline() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let initialState = availableUsageState(for: codex)
        let resetOnlyUsageState = AccountSubscriptionUsageState.available(
            SubscriptionUsageSnapshot(
                profileID: codex.id,
                provider: .codex,
                windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 90, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 10_900)
            )
        )
        let refreshedState = AccountSubscriptionUsageState.available(
            SubscriptionUsageSnapshot(
                profileID: codex.id,
                provider: .codex,
                windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 11_140)
            )
        )
        let cachedResetSnapshot = resetCreditSnapshot(
            profileID: codex.id,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let refreshedResetSnapshot = resetCreditSnapshot(
            profileID: codex.id,
            fetchedAt: Date(timeIntervalSince1970: 10_900)
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 10_840))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: initialState],
                fetchedAt: Date(timeIntervalSince1970: 10_840)
            ),
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: resetOnlyUsageState],
                resetCreditsOutcomesByProfileID: [codex.id: .available(refreshedResetSnapshot)],
                fetchedAt: Date(timeIntervalSince1970: 10_900)
            ),
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: refreshedState],
                fetchedAt: Date(timeIntervalSince1970: 11_140)
            )
        ])
        let sleeper = SubscriptionUsageSleepGate()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsSnapshotCache: CodexResetCreditsSnapshotCacheDouble(
                snapshots: [codex.id: cachedResetSnapshot]
            ),
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await sleeper.waitForSleeps(expectedCount: 1)
        clock.set(Date(timeIntervalSince1970: 10_900))
        await sleeper.resumeNext()
        await waitForUsageFetches(quota, expectedCount: 2)
        await sleeper.waitForSleeps(expectedCount: 2)

        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], initialState)

        clock.set(Date(timeIntervalSince1970: 11_140))
        await sleeper.resumeNext()
        await waitForUsageFetches(quota, expectedCount: 3)
        await sleeper.waitForSleeps(expectedCount: 3)

        let requestedUsageProfileIDSets = await quota.requestedUsageProfileIDSets()
        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        let delays = await sleeper.delays()
        XCTAssertEqual(requestedUsageProfileIDSets, [[codex.id], [], [codex.id]])
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[], [codex.id], []])
        XCTAssertEqual(Array(delays.prefix(2)), [60_000_000_000, 240_000_000_000])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], refreshedState)
    }

    func testTerminalCodexOnlySchedulesResetCreditWakeAndUsesResetOnlyRequest() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: .unavailable(.schemaMismatch)],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 100)
            ),
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: availableUsageState(for: codex)],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 100 + 10_800)
            )
        ])
        let sleeper = SubscriptionUsageSleepGate()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        await sleeper.waitForSleeps(expectedCount: 1)
        clock.set(Date(timeIntervalSince1970: 100 + 10_800))
        await sleeper.resumeNext()
        await waitForUsageFetches(quota, expectedCount: 2)
        await sleeper.waitForSleeps(expectedCount: 2)

        let requestedUsageProfileIDSets = await quota.requestedUsageProfileIDSets()
        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        let delays = await sleeper.delays()
        XCTAssertEqual(requestedUsageProfileIDSets, [[codex.id], []])
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .unavailable(.schemaMismatch))
        XCTAssertEqual(delays, [10_800_000_000_000, 10_800_000_000_000])
    }

    func testReloadUsageAlwaysRequestsActiveCodexResetCredits() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            availableUsageReport(for: codex),
            availableUsageReport(for: codex)
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsNow: { clock.now() }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 200))
        await viewModel.reloadUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [codex.id]])
    }

    func testFreshRestoredResetCreditCacheSkipsFirstAutomaticRequest() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let snapshot = resetCreditSnapshot(profileID: codex.id, fetchedAt: Date(timeIntervalSince1970: 100))
        let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [codex.id: snapshot])
        let quota = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: codex)])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsSnapshotCache: cache,
            codexResetCreditsNow: { Date(timeIntervalSince1970: 100 + 10_799) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[]])
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[codex.id], snapshot)
    }

    func testFutureResetCreditCacheIsInvalidatedAndSchedulesBoundedRefresh() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let futureSnapshot = resetCreditSnapshot(
            profileID: codex.id,
            fetchedAt: Date(timeIntervalSince1970: 32_503_680_000)
        )
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: .unavailable(.schemaMismatch)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: now
            )
        ])
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsSnapshotCache: CodexResetCreditsSnapshotCacheDouble(
                snapshots: [codex.id: futureSnapshot]
            ),
            codexResetCreditsNow: { now },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        let delays = await sleeper.delays()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id]])
        XCTAssertEqual(delays, [10_800_000_000_000])
    }

    func testResetCreditFailureKeepsLastSuccessfulSnapshotAndCache() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let snapshot = resetCreditSnapshot(profileID: codex.id, fetchedAt: Date(timeIntervalSince1970: 100))
        let cache = CodexResetCreditsSnapshotCacheDouble(snapshots: [codex.id: snapshot])
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 11_000))
        let quota = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: availableUsageState(for: codex)],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                fetchedAt: Date(timeIntervalSince1970: 11_000)
            ),
            availableUsageReport(for: codex)
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quota,
            codexResetCreditsSnapshotCache: cache,
            codexResetCreditsNow: { clock.now() }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        clock.set(Date(timeIntervalSince1970: 11_001))
        await viewModel.refreshSubscriptionUsage()

        let requestedResetCreditProfileIDSets = await quota.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], []])
        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[codex.id], snapshot)
        XCTAssertEqual(cache.load()[codex.id], snapshot)
    }

    func testServerActionCompletionHandsOffIndependentResetWithoutDuplicateRefresh() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let usageReport = SubscriptionUsageReport(
            statesByProfileID: [profile.id: availableUsageState(for: profile)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let resetSnapshot = resetCreditSnapshot(
            profileID: profile.id,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReport: usageReport)
        let resetCache = CodexResetCreditsSnapshotCacheDouble()
        let sleeper = SubscriptionUsageSleepRecorder()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running

        let action = Task { await viewModel.restartServer() }
        let didStartReset = await quotaClient.waitForResetRequests(expectedCount: 1)
        XCTAssertTrue(didStartReset)
        await action.value
        let usageCountBeforeResetCompletion = await quotaClient.usageRequestCount()
        let delaysBeforeResetCompletion = await sleeper.delays()
        XCTAssertEqual(usageCountBeforeResetCompletion, 1)
        XCTAssertEqual(delaysBeforeResetCompletion, [300_000_000_000])

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [profile.id: .available(resetSnapshot)],
            resetCreditsAttemptedProfileIDs: [profile.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        for _ in 0..<1_000 {
            if viewModel.codexResetCreditsSnapshots[profile.id] == resetSnapshot { break }
            if await quotaClient.usageRequestCount() > 1 { break }
            await Task.yield()
        }

        XCTAssertEqual(viewModel.codexResetCreditsSnapshots[profile.id], resetSnapshot)
        XCTAssertEqual(resetCache.load()[profile.id], resetSnapshot)
        let finalUsageCount = await quotaClient.usageRequestCount()
        let finalResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        let finalDelays = await sleeper.delays()
        XCTAssertEqual(finalUsageCount, 1)
        XCTAssertEqual(finalResetProfileIDSets, [[profile.id]])
        XCTAssertEqual(finalDelays, [300_000_000_000, 300_000_000_000])
    }

    func testSlowResetCreditsPublishesAllUsageAndSchedulesPollBeforeResetCompletes() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let claude = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "claude@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let usageReport = SubscriptionUsageReport(
            statesByProfileID: [
                codex.id: availableUsageState(for: codex),
                claude.id: availableUsageState(for: claude)
            ],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReport: usageReport)
        let sleeper = SubscriptionUsageSleepRecorder()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex, claude],
            quotaClient: quotaClient,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        let refresh = Task { await viewModel.refreshSubscriptionUsage() }
        await quotaClient.waitForResetRequest()
        await waitForUsageSleeps(sleeper, expectedCount: 1)

        let delaysBeforeResetCompletion = await sleeper.delays()
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], availableUsageState(for: codex))
        XCTAssertEqual(viewModel.subscriptionUsageStates[claude.id], availableUsageState(for: claude))
        XCTAssertEqual(delaysBeforeResetCompletion, [300_000_000_000])

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
            resetCreditsAttemptedProfileIDs: [codex.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        await refresh.value
    }

    func testResetOnlyRetryWakeRearmsPreservedUsageDeadlineWhileResetRemainsSuspended() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let initialSnapshot = SubscriptionUsageSnapshot(
            profileID: codex.id,
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let polledSnapshot = SubscriptionUsageSnapshot(
            profileID: codex.id,
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 400)
        )
        let preflightFailure = SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(
            usageReports: [
                SubscriptionUsageReport(
                    statesByProfileID: [codex.id: .available(initialSnapshot)],
                    fetchedAt: initialSnapshot.fetchedAt
                ),
                SubscriptionUsageReport(
                    statesByProfileID: [codex.id: .available(polledSnapshot)],
                    fetchedAt: polledSnapshot.fetchedAt
                )
            ],
            resetReportsBeforeSuspension: [preflightFailure]
        )
        let sleeper = SubscriptionUsageSleepGate()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quotaClient,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let didScheduleResetRetry = await waitForUsagePollingDelay(
            sleeper,
            expected: 60_000_000_000
        )
        XCTAssertTrue(didScheduleResetRetry)
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(initialSnapshot))

        clock.set(Date(timeIntervalSince1970: 160))
        await sleeper.resumeNext()
        let didStartRetryReset = await quotaClient.waitForResetRequests(expectedCount: 2)
        XCTAssertTrue(didStartRetryReset)
        let didRearmUsageDeadline = await waitForUsagePollingDelay(
            sleeper,
            expected: 240_000_000_000
        )
        XCTAssertTrue(didRearmUsageDeadline)
        guard didRearmUsageDeadline else {
            await quotaClient.resolveReset(with: SubscriptionUsageReport(
                statesByProfileID: [:],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 160)
            ))
            return
        }

        clock.set(Date(timeIntervalSince1970: 400))
        await sleeper.resumeNext()
        let didPollUsage = await quotaClient.waitForUsageRequests(expectedCount: 2)
        let didScheduleNextUsage = await waitForUsagePollingDelay(
            sleeper,
            expected: 300_000_000_000
        )
        XCTAssertTrue(didPollUsage)
        XCTAssertTrue(didScheduleNextUsage)
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(polledSnapshot))

        let sleepCountBeforeLateReset = await sleeper.delays().count
        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
            resetCreditsAttemptedProfileIDs: [codex.id],
            fetchedAt: Date(timeIntervalSince1970: 160)
        ))
        await sleeper.waitForSleeps(expectedCount: sleepCountBeforeLateReset + 1)

        let delays = await sleeper.delays()
        XCTAssertEqual(delays.last, 300_000_000_000)
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(polledSnapshot))
    }

    func testPendingResetClaimDoesNotChurnAndPreservesUsageDeadlineWithForcedPriority() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let accountA = AuthProfile(
            fileName: "codex-a.json",
            type: .codex,
            email: "codex-a@example.com",
            accountID: "acct_a_example",
            expired: nil,
            disabled: false
        )
        let accountB = AuthProfile(
            fileName: "codex-b.json",
            type: .codex,
            email: "codex-b@example.com",
            accountID: "acct_b_example",
            expired: nil,
            disabled: false
        )
        let initialSnapshots = [accountA, accountB].reduce(into: [String: AccountSubscriptionUsageState]()) {
            $0[$1.id] = availableUsageState(for: $1)
        }
        let polledSnapshot = SubscriptionUsageSnapshot(
            profileID: accountB.id,
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 400)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReports: [
            SubscriptionUsageReport(
                statesByProfileID: initialSnapshots,
                fetchedAt: Date(timeIntervalSince1970: 100)
            ),
            SubscriptionUsageReport(
                statesByProfileID: [
                    accountA.id: availableUsageState(for: accountA),
                    accountB.id: .available(polledSnapshot)
                ],
                fetchedAt: polledSnapshot.fetchedAt
            )
        ])
        let sleeper = SubscriptionUsageSleepGate()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let accountBResetReference = Date(timeIntervalSince1970: 160 - (3 * 60 * 60))
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            accountB.id: resetCreditSnapshot(profileID: accountB.id, fetchedAt: accountBResetReference)
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [accountA, accountB],
            quotaClient: quotaClient,
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        let didStartAccountAReset = await quotaClient.waitForResetRequests(expectedCount: 1)
        let didScheduleAccountBDeadline = await waitForUsagePollingDelay(
            sleeper,
            expected: 60_000_000_000
        )
        XCTAssertTrue(didStartAccountAReset)
        XCTAssertTrue(didScheduleAccountBDeadline)
        let initialResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(initialResetProfileIDSets, [[accountA.id]])

        clock.set(Date(timeIntervalSince1970: 160))
        await sleeper.resumeNext()
        let didPreserveUsageDeadline = await waitForUsagePollingDelay(
            sleeper,
            expected: 240_000_000_000
        )
        XCTAssertTrue(didPreserveUsageDeadline)
        for _ in 0..<10 { await Task.yield() }
        let delaysWhileAccountAIsSuspended = await sleeper.delays()
        XCTAssertEqual(delaysWhileAccountAIsSuspended, [60_000_000_000, 240_000_000_000])
        XCTAssertFalse(delaysWhileAccountAIsSuspended.contains(0))
        let coalescedResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(coalescedResetProfileIDSets, [[accountA.id]])

        clock.set(Date(timeIntervalSince1970: 400))
        await sleeper.resumeNext()
        let didPollUsage = await quotaClient.waitForUsageRequests(expectedCount: 2)
        let didScheduleNextUsage = await waitForUsagePollingDelay(
            sleeper,
            expected: 300_000_000_000
        )
        XCTAssertTrue(didPollUsage)
        XCTAssertTrue(didScheduleNextUsage)
        XCTAssertEqual(viewModel.subscriptionUsageStates[accountB.id], .available(polledSnapshot))

        await viewModel.refreshSubscriptionUsage(force: true)
        let resetProfileIDSetsBeforeCompletion = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(resetProfileIDSetsBeforeCompletion, [[accountA.id]])

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsAttemptedProfileIDs: [accountA.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        let didStartForcedPendingReset = await quotaClient.waitForResetRequests(expectedCount: 2)
        XCTAssertTrue(didStartForcedPendingReset)
        let forcedResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(forcedResetProfileIDSets, [[accountA.id], [accountA.id, accountB.id]])

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsAttemptedProfileIDs: [accountA.id, accountB.id],
            fetchedAt: Date(timeIntervalSince1970: 400)
        ))
        for _ in 0..<10 { await Task.yield() }
        let finalResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(finalResetProfileIDSets.count, 2)
    }

    func testUsagePollRunsAtDeadlineWhileResetRemainsSuspended() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let codex = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let initialSnapshot = SubscriptionUsageSnapshot(
            profileID: codex.id,
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let polledSnapshot = SubscriptionUsageSnapshot(
            profileID: codex.id,
            provider: .codex,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 40, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 400)
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReports: [
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: .available(initialSnapshot)],
                fetchedAt: initialSnapshot.fetchedAt
            ),
            SubscriptionUsageReport(
                statesByProfileID: [codex.id: .available(polledSnapshot)],
                fetchedAt: polledSnapshot.fetchedAt
            )
        ])
        let sleeper = SubscriptionUsageSleepGate()
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 100))
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [codex],
            quotaClient: quotaClient,
            codexResetCreditsNow: { clock.now() },
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) }
        )
        viewModel.serverStatus = readyStatus()

        let initialRefresh = Task { await viewModel.refreshSubscriptionUsage() }
        await quotaClient.waitForResetRequest()
        await sleeper.waitForSleeps(expectedCount: 1)
        await initialRefresh.value
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(initialSnapshot))

        clock.set(Date(timeIntervalSince1970: 400))
        await sleeper.resumeNext()
        let didPollUsage = await quotaClient.waitForUsageRequests(expectedCount: 2)
        XCTAssertTrue(didPollUsage)
        guard didPollUsage else {
            await quotaClient.resolveReset(with: SubscriptionUsageReport(
                statesByProfileID: [:],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 100)
            ))
            return
        }
        await sleeper.waitForSleeps(expectedCount: 2)

        let usageRequestCount = await quotaClient.usageRequestCount()
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(polledSnapshot))
        XCTAssertEqual(usageRequestCount, 2)

        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
            resetCreditsAttemptedProfileIDs: [codex.id],
            fetchedAt: Date(timeIntervalSince1970: 100)
        ))
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .available(polledSnapshot))
    }

    func testRemovingAccountDuringSeparatedForcedResetRestartsRemainingResetWithForce() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let first = AuthProfile(
            fileName: "codex-first.json",
            type: .codex,
            email: "first@example.com",
            accountID: "acct_first",
            expired: nil,
            disabled: false
        )
        let second = AuthProfile(
            fileName: "codex-second.json",
            type: .codex,
            email: "second@example.com",
            accountID: "acct_second",
            expired: nil,
            disabled: false
        )
        config.oauthCommandProfiles = [
            .init(id: "codex-first", provider: .codex, authProfileID: first.id, commandName: "codexfirst"),
            .init(id: "codex-second", provider: .codex, authProfileID: second.id, commandName: "codexsecond")
        ]
        let now = Date(timeIntervalSince1970: 100)
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [
            first.id: resetCreditSnapshot(profileID: first.id, fetchedAt: now),
            second.id: resetCreditSnapshot(profileID: second.id, fetchedAt: now)
        ])
        let usageReport = SubscriptionUsageReport(
            statesByProfileID: [
                first.id: availableUsageState(for: first),
                second.id: availableUsageState(for: second)
            ],
            fetchedAt: now
        )
        let quotaClient = ResetSuspendingSubscriptionQuotaClient(usageReport: usageReport)
        let authStore = StubAuthProfileStore(profiles: [first, second], supportsIDDelete: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [first, second],
            authProfileStore: authStore,
            quotaClient: quotaClient,
            codexResetCreditsSnapshotCache: resetCache,
            codexResetCreditsNow: { now }
        )
        viewModel.serverStatus = readyStatus()

        let forcedRefresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        let didStartForcedReset = await quotaClient.waitForResetRequests(expectedCount: 1)
        XCTAssertTrue(didStartForcedReset)
        await forcedRefresh.value

        viewModel.removeProvider(.init(rawValue: "codex-first"))
        let didRestartRemainingReset = await quotaClient.waitForResetRequests(expectedCount: 2)
        let requestedResetProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        await quotaClient.resolveReset(with: SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsAttemptedProfileIDs: [first.id, second.id],
            fetchedAt: now
        ))

        XCTAssertTrue(didRestartRemainingReset)
        XCTAssertEqual(requestedResetProfileIDSets, [[first.id, second.id], [second.id]])
    }

    func testAutomaticUsageRefreshKeepsExistingUsageUntilSuccessfulReplacement() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "codexwork"
            )
        ]
        let profile = AuthProfile(
            fileName: "codex-work.json",
            type: .codex,
            email: "work@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let initialState = availableUsageState(for: profile)
        let snapshot = try! XCTUnwrap(initialState.snapshot)
        let initialReset = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 10))
        let refreshedReset = resetCreditSnapshot(profileID: profile.id, fetchedAt: Date(timeIntervalSince1970: 60))
        let quotaClient = SuspendedSubscriptionQuotaClient(reportsBeforeSuspension: [
            .init(
                statesByProfileID: [profile.id: initialState],
                resetCreditsOutcomesByProfileID: [profile.id: .available(initialReset)],
                fetchedAt: snapshot.fetchedAt
            )
        ])
        let cache = SubscriptionUsageSnapshotCacheDouble()
        let resetCache = CodexResetCreditsSnapshotCacheDouble(snapshots: [profile.id: initialReset])
        let authStore = StubAuthProfileStore(profiles: [profile], supportsIDDelete: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            authProfileStore: authStore,
            quotaClient: quotaClient,
            subscriptionUsageSnapshotCache: cache,
            codexResetCreditsSnapshotCache: resetCache
        )
        viewModel.serverStatus = readyStatus()

        await viewModel.refreshSubscriptionUsage()
        XCTAssertEqual(cache.load(), [profile.id: snapshot])
        XCTAssertEqual(resetCache.load(), [profile.id: initialReset])

        let refresh = Task { await viewModel.refreshSubscriptionUsage(force: true) }
        await waitForUsageFetches(quotaClient, expectedCount: 2)
        viewModel.removeProvider(ProviderRowState.ID(rawValue: "codex-work"))
        await quotaClient.resolveAll(with: .init(
            statesByProfileID: [profile.id: .unavailable(.transientFailure)],
            resetCreditsOutcomesByProfileID: [profile.id: .available(refreshedReset)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        ))
        await refresh.value

        XCTAssertNil(viewModel.subscriptionUsageStates[profile.id])
        XCTAssertNil(cache.load()[profile.id])
        XCTAssertNil(viewModel.codexResetCreditsSnapshots[profile.id])
        XCTAssertNil(resetCache.load()[profile.id])
    }

    func testRemovingAccountDuringColdAutomaticRefreshImmediatelyRestartsRemainingAccount() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        let requestedResetCreditProfileIDSets = await quotaClient.requestedResetCreditProfileIDSets()
        XCTAssertEqual(requestedProfileIDs, [[claude.id, codex.id], [codex.id]])
        XCTAssertEqual(requestedResetCreditProfileIDSets, [[codex.id], [codex.id]])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], .loading)

        await quotaClient.resolveAll(with: availableUsageReport(for: codex))
        await refresh.value
        await waitForUsageState(viewModel, profileID: codex.id, expected: availableUsageState(for: codex))

        XCTAssertNil(viewModel.subscriptionUsageStates[claude.id])
        XCTAssertEqual(viewModel.subscriptionUsageStates[codex.id], availableUsageState(for: codex))
    }

    func testNotFoundRemovalDuringUsageRefreshImmediatelyRestartsCurrentAccount() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            availableUsageReport(for: profile, resetCreditsDeferredProfileIDs: [profile.id])
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
        await waitForUsageSleeps(sleeper, expectedCount: 1)

        let delays = await sleeper.delays()
        XCTAssertEqual(delays, [300_000_000_000])
    }

    func testTransientStaleUsageRefreshUpdatesIssueAndDoublesRetryDelay() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialState = availableUsageState(for: profile)
        let snapshot = try! XCTUnwrap(initialState.snapshot)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            .init(
                statesByProfileID: [profile.id: initialState],
                resetCreditsDeferredProfileIDs: [profile.id],
                fetchedAt: snapshot.fetchedAt
            ),
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
        config.subscriptionUsage.showInMenuBar = true
        let claude = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let codex = AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
        let initialReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: .unavailable(.schemaMismatch),
                codex.id: availableUsageState(for: codex)
            ],
            resetCreditsDeferredProfileIDs: [codex.id],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        let refreshedReport = SubscriptionUsageReport(
            statesByProfileID: [
                claude.id: availableUsageState(for: claude),
                codex.id: availableUsageState(for: codex)
            ],
            resetCreditsDeferredProfileIDs: [codex.id],
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
        config.subscriptionUsage.showInMenuBar = true
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
        XCTAssertTrue(viewModel.canReloadSubscriptionUsage)
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

    func testManualUsageReloadRecoversAfterRefreshingStaleServerError() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let recoveredState = availableUsageState(for: profile)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [
            SubscriptionUsageReport(
                statesByProfileID: [profile.id: recoveredState],
                fetchedAt: Date(timeIntervalSince1970: 0)
            )
        ])
        let httpClient = SequencedHTTPClient(results: [.success(Data("{}".utf8))])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient, timeout: 0.1)
        )
        viewModel.serverStatus = DiagnosticStatus(
            severity: .error,
            title: "CLIProxyAPI Stale Error",
            message: "The previous health check failed."
        )

        XCTAssertFalse(viewModel.canRefreshSubscriptionUsage)
        XCTAssertTrue(viewModel.canReloadSubscriptionUsage)

        await viewModel.reloadSubscriptionUsage()

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(httpClient.requestCount, 1)
        XCTAssertEqual(fetchCallCount, 1)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], recoveredState)
    }

    func testManualUsageReloadSkipsQuotaFetchWhileServerIsStillUnavailable() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost))
        ])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quotaClient,
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient, timeout: 0.1)
        )
        viewModel.serverStatus = DiagnosticStatus(
            severity: .error,
            title: "CLIProxyAPI Stale Error",
            message: "The previous health check failed."
        )

        await viewModel.reloadSubscriptionUsage()

        let fetchCallCount = await quotaClient.fetchCallCount()
        XCTAssertEqual(httpClient.requestCount, 1)
        XCTAssertEqual(fetchCallCount, 0)
        XCTAssertEqual(viewModel.serverStatus.severity, .warning)
        XCTAssertFalse(viewModel.isSubscriptionUsageReloadActionInProgress)
    }

    func testManualUsageReloadReportsProgressAcrossHealthCheckAndQuotaFetch() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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

        let reload = Task { await viewModel.reloadSubscriptionUsage() }
        await waitForUsageFetches(quotaClient, expectedCount: 1)

        XCTAssertTrue(viewModel.isSubscriptionUsageReloadInProgress)
        XCTAssertTrue(viewModel.isSubscriptionUsageReloadActionInProgress)

        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await reload.value

        XCTAssertFalse(viewModel.isSubscriptionUsageReloadInProgress)
        XCTAssertFalse(viewModel.isSubscriptionUsageReloadActionInProgress)
    }

    func testTerminalStaleProfileIsExcludedAutomaticallyAndForceRefreshRecoversIt() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
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
        config.subscriptionUsage.showInMenuBar = true
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
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await quotaClient.resolveAll(with: availableUsageReport(for: profile))
        await refresh.value

        XCTAssertEqual(viewModel.subscriptionUsageStates[profile.id], .disabled)
    }

    func testAPIKeyRowsReceiveCostStateAndOAuthRowsKeepSubscriptionState() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(
            restoredReport: reportWithClaudeCost(
                cost: "1.25",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let secretStore = InMemorySecretStore(values: [.claudeAPIKey: "key"])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: secretStore
        )

        await viewModel.prepareUsage()

        let apiRow = try XCTUnwrap(viewModel.providerRows.first { $0.id == .claudeAPI })
        guard case let .apiCost(.available(snapshot)) = apiRow.usageState else {
            return XCTFail("Expected API cost")
        }
        XCTAssertEqual(snapshot.day.estimatedUSD, Decimal(string: "1.25"))
    }

    func testDisablingUsageClearsOAuthCacheButStopsAndPreservesAPILedger() async throws {
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "user@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let snapshot = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .claude,
            windows: [UsageWindow(id: "5h", label: "5h", usedPercent: 10, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let cache = SubscriptionUsageSnapshotCacheDouble(snapshots: [profile.id: snapshot])
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            subscriptionUsageSnapshotCache: cache,
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()

        let stopCount = await collector.stopCount()
        let deleteLedgerCount = await collector.deleteLedgerCount()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(deleteLedgerCount, 0)
    }

    func testPrepareUsageRefreshesOAuthOnceWhenMissingKeyRequiresRestart() async {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "user@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let report = availableUsageReport(for: profile)
        let quota = RecordingSubscriptionQuotaClient(reports: [report, report])
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quota
        )
        await viewModel.refresh()

        await viewModel.prepareUsage()

        let fetchCount = await quota.fetchCallCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testEnablingUsageWhileServerIsRunningStartsAPICollector() async throws {
        let config = AppConfig.default
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.refresh()

        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await collector.waitForStartCount(1)

        let startCount = await collector.startCount()
        XCTAssertEqual(startCount, 1)
    }

    func testRapidDisableThenEnableWaitsForStopBeforeRestartingCollector() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(suspendsStop: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()
        try viewModel.saveSubscriptionUsageMenuBarVisible(true)

        let startsBeforeStopCompletes = await collector.startCount()
        XCTAssertEqual(startsBeforeStopCompletes, 1)

        await collector.resumeStop()
        await collector.waitForStartCount(2)
        let finalStartCount = await collector.startCount()
        XCTAssertEqual(finalStartCount, 2)
    }

    func testReenablingUsageRestartsCollectorToClosePauseInterval() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        await viewModel.prepareUsage()
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()
        try viewModel.saveSubscriptionUsageMenuBarVisible(true)
        await collector.waitForStartCount(2)

        let startCount = await collector.startCount()
        XCTAssertEqual(startCount, 2)
    }

    func testDisablingUsageInvalidatesSuspendedAPIReloadResult() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let staleReport = reportWithClaudeCost(
            cost: "9.99",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let collector = APIUsageCollectorDouble(
            reloadReport: staleReport,
            suspendsReload: true
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        let reload = Task { await viewModel.reloadUsage() }
        await collector.waitUntilReloadSuspended()
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        collector.resumeReload()
        await reload.value
        await collector.waitForStop()

        XCTAssertTrue(viewModel.apiCostUsageStates.isEmpty)
        let apiRow = try XCTUnwrap(viewModel.providerRows.first { $0.id == .claudeAPI })
        XCTAssertEqual(apiRow.usageState, .apiCost(.disabled))
    }

    func testDisablingUsageIgnoresLateAPIUsageReportStreamValue() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let staleReport = reportWithClaudeCost(
            cost: "9.99",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let collector = APIUsageCollectorDouble(keepsReportStreamOpen: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()
        await collector.waitForReportSubscriber()

        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()
        await collector.emit(staleReport)
        await Task.yield()
        await collector.finishReports()

        XCTAssertTrue(viewModel.apiCostUsageStates.isEmpty)
        let apiRow = try XCTUnwrap(viewModel.providerRows.first { $0.id == .claudeAPI })
        XCTAssertEqual(apiRow.usageState, .apiCost(.disabled))
    }

    func testPortChangeIgnoresLateReportUntilCollectorUpdateCompletes() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let staleReport = reportWithClaudeCost(
            cost: "7.77",
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        let collector = APIUsageCollectorDouble(
            suspendsUpdate: true,
            keepsReportStreamOpen: true
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()
        await collector.waitForReportSubscriber()
        await collector.resetUpdates()

        try viewModel.savePort(19_001)
        await collector.waitUntilUpdateSuspended()
        await collector.emit(staleReport)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertTrue(viewModel.apiCostUsageStates.isEmpty)

        collector.resumeUpdate()
        try? await viewModel.prepareForTermination()
        await collector.finishReports()
    }

    func testStartAppliesReportPublishedBeforeLifecycleOperationReturns() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let restored = reportWithClaudeCost(
            cost: "1.00",
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: .init(generation: 1)
        )
        let started = reportWithClaudeCost(
            cost: "2.00",
            updatedAt: Date(timeIntervalSince1970: 200),
            identity: .init(generation: 2)
        )
        let collector = IdentityAPIUsageCollectorDouble(
            restoredReport: restored,
            startReport: started,
            updateReport: started,
            publishesBeforeReturning: true
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        await viewModel.prepareUsage()

        XCTAssertEqual(
            viewModel.apiCostUsageStates[ProviderRowState.ID.claudeAPI.rawValue],
            started.statesByProfileID[ProviderRowState.ID.claudeAPI.rawValue]
        )
    }

    func testUpdateAppliesImmediateAuthoritativeReportWithoutWaitingForPolling() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let started = reportWithClaudeCost(
            cost: "1.00",
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: .init(generation: 1)
        )
        let updated = reportWithClaudeCost(
            cost: "3.00",
            updatedAt: Date(timeIntervalSince1970: 300),
            identity: .init(generation: 2)
        )
        let collector = IdentityAPIUsageCollectorDouble(
            restoredReport: started,
            startReport: started,
            updateReport: updated,
            publishesBeforeReturning: true
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        await viewModel.prepareUsage()

        XCTAssertEqual(
            viewModel.apiCostUsageStates[ProviderRowState.ID.claudeAPI.rawValue],
            updated.statesByProfileID[ProviderRowState.ID.claudeAPI.rawValue]
        )
    }

    func testOldStreamIdentityCannotOverwriteAcceptedUpdateReport() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let oldReport = reportWithClaudeCost(
            cost: "1.00",
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: .init(generation: 1)
        )
        let updated = reportWithClaudeCost(
            cost: "4.00",
            updatedAt: Date(timeIntervalSince1970: 400),
            identity: .init(generation: 2)
        )
        let collector = IdentityAPIUsageCollectorDouble(
            restoredReport: oldReport,
            startReport: oldReport,
            updateReport: updated,
            publishesBeforeReturning: true
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()
        await collector.waitForReportSubscriber()
        await viewModel.prepareUsage()

        await collector.emit(oldReport)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(
            viewModel.apiCostUsageStates[ProviderRowState.ID.claudeAPI.rawValue],
            updated.statesByProfileID[ProviderRowState.ID.claudeAPI.rawValue]
        )
        await collector.finishReports()
    }

    func testConcurrentTerminationWaitersShareInFlightStopInsteadOfSecondReturningEarly() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(suspendsStop: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        let secondCompleted = TerminationCompletionFlag()

        let first = Task { try await viewModel.prepareForTermination() }
        await collector.waitForStop()
        let second = Task {
            try await viewModel.prepareForTermination()
            await secondCompleted.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }

        let completedBeforeResume = await secondCompleted.isCompleted()
        let stopCountBeforeResume = await collector.stopCount()
        XCTAssertFalse(completedBeforeResume)
        XCTAssertEqual(stopCountBeforeResume, 1)

        await collector.resumeStop()
        _ = await first.result
        _ = await second.result
        let completedAfterResume = await secondCompleted.isCompleted()
        let finalStopCount = await collector.stopCount()
        XCTAssertTrue(completedAfterResume)
        XCTAssertEqual(finalStopCount, 1)
    }

    func testCancelledTerminationRestartsCollectorAfterSuccessfulPreparation() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        try await viewModel.prepareForTermination()
        viewModel.cancelTerminationPreparation()
        await collector.waitForStartCount(2)

        let stopCount = await collector.stopCount()
        let startCount = await collector.startCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(startCount, 2)
    }

    func testCancelledTerminationBeforePreparationRestartsCollector() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        viewModel.beginTermination()
        viewModel.cancelTerminationPreparation()
        await collector.waitForStartCount(2)

        let stopCount = await collector.stopCount()
        let startCount = await collector.startCount()
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(startCount, 2)
    }

    func testCancelledTerminationRestartsCollectorAfterPreparationFailure() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(stopFailuresRemaining: 1)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        do {
            try await viewModel.prepareForTermination()
            XCTFail("Expected termination preparation to fail")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .persistenceFailure)
        }
        viewModel.cancelTerminationPreparation()
        await collector.waitForStartCount(2)

        let stopCount = await collector.stopCount()
        let startCount = await collector.startCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(startCount, 2)
    }

    func testTerminationFlushFailureCanRetryInsteadOfCachingSuccess() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(stopFailuresRemaining: 1)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        do {
            try await viewModel.prepareForTermination()
            XCTFail("Expected first termination flush to fail")
        } catch {
            XCTAssertEqual(error as? APIUsageLedgerStoreError, .persistenceFailure)
        }

        try await viewModel.prepareForTermination()
        let stopCount = await collector.stopCount()
        XCTAssertEqual(stopCount, 2)
    }

    func testTerminationInvalidatesQueuedAPIUsageUpdateBehindSuspendedReload() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble(suspendsReload: true)
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()
        viewModel.serverStatus = readyStatus()
        await collector.resetUpdates()

        let reload = Task { await viewModel.reloadUsage() }
        await collector.waitUntilReloadSuspended()
        try viewModel.savePort(19_001)
        let termination = Task { try? await viewModel.prepareForTermination() }
        for _ in 0..<100 { await Task.yield() }
        collector.resumeReload()
        await reload.value
        await termination.value

        let updateConfigurations = await collector.updateConfigurations()
        let stopReasons = await collector.stopReasons()
        XCTAssertEqual(updateConfigurations, [])
        XCTAssertEqual(stopReasons, [.applicationTermination])
    }

    func testTerminationCancelsActiveReloadAndStopsCollectorLast() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let stopExpectation = expectation(description: "collector stopped")
        let collector = CancellableLifecycleAPIUsageCollectorDouble {
            stopExpectation.fulfill()
        }
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()
        viewModel.serverStatus = readyStatus()

        let reload = Task { await viewModel.reloadUsage() }
        await collector.waitForReloadToSuspend()
        let termination = Task { try? await viewModel.prepareForTermination() }

        await fulfillment(of: [stopExpectation], timeout: 1)
        collector.releaseAll()
        await reload.value
        await termination.value

        let calls = await collector.calls()
        XCTAssertEqual(calls.last, .stop(.applicationTermination))
    }

    func testTerminationCancelsActiveUpdateAndStopsCollectorLast() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let stopExpectation = expectation(description: "collector stopped")
        let collector = CancellableLifecycleAPIUsageCollectorDouble {
            stopExpectation.fulfill()
        }
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.prepareUsage()

        try viewModel.savePort(19_001)
        await collector.waitForUpdateToSuspend()
        let termination = Task { try? await viewModel.prepareForTermination() }

        await fulfillment(of: [stopExpectation], timeout: 1)
        collector.releaseAll()
        await termination.value

        let calls = await collector.calls()
        XCTAssertEqual(calls.last, .stop(.applicationTermination))
    }

    func testTrackingDisableDoesNotTreatDisplayControlStateAsRuntimeCertainty() async throws {
        let cases: [ServerControlState] = [
            .stopped,
            .starting,
            .running,
            .stopping,
            .error("Health unavailable")
        ]

        for state in cases {
            var config = AppConfig.default
            config.subscriptionUsage.showInMenuBar = true
            let collector = APIUsageCollectorDouble()
            let viewModel = subscriptionUsageViewModel(
                config: config,
                configStore: StubConfigStore(config: config),
                keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
                proxyService: StubProxyServiceStarter(),
                apiUsageCollector: collector
            )
            viewModel.serverControlState = state

            try viewModel.saveSubscriptionUsageMenuBarVisible(false)
            await collector.waitForStop()

            let reasons = await collector.stopReasons()
            XCTAssertEqual(
                reasons,
                [.trackingDisabled(proxyCouldServeRequests: true)],
                "Display control state must not reduce runtime uncertainty for \(state)"
            )
        }
    }

    func testPassiveHealthTimeoutRemainsConservativeWhenUsageIsDisabled() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .failure(HTTPClientError.timedOut)),
                timeout: 0.01
            ),
            apiUsageCollector: collector
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.serverStatus.severity, .warning)
        XCTAssertEqual(viewModel.serverControlState, .stopped)
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()

        let stopReasons = await collector.stopReasons()
        XCTAssertEqual(
            stopReasons,
            [.trackingDisabled(proxyCouldServeRequests: true)]
        )
    }

    func testPassiveHealthConfirmedStoppedMarksTrackingPauseUnableToServe() async throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let collector = APIUsageCollectorDouble()
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .failure(URLError(.cannotConnectToHost))),
                timeout: 0.01
            ),
            apiUsageCollector: collector
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.serverStatus.title, "CLIProxyAPI Stopped")
        try viewModel.saveSubscriptionUsageMenuBarVisible(false)
        await collector.waitForStop()

        let stopReasons = await collector.stopReasons()
        XCTAssertEqual(
            stopReasons,
            [.trackingDisabled(proxyCouldServeRequests: false)]
        )
    }

    func testReloadUsageRefreshesQuotaAndImmediatelyDrainsAPIQueue() async {
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "user@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let quota = RecordingSubscriptionQuotaClient(reports: [availableUsageReport(for: profile)])
        let collector = APIUsageCollectorDouble(
            reloadReport: reportWithClaudeCost(cost: "0.42", updatedAt: Date())
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            quotaClient: quota,
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )
        await viewModel.refresh()

        await viewModel.reloadUsage()

        let quotaFetchCount = await quota.fetchCallCount()
        let collectorReloadCount = await collector.reloadCount()
        XCTAssertEqual(quotaFetchCount, 1)
        XCTAssertEqual(collectorReloadCount, 1)
        XCTAssertFalse(viewModel.isUsageReloadActionInProgress)
    }

    func testLastSuccessfulUsageRefreshUsesOldestVisibleSnapshot() async {
        let profile = AuthProfile(
            fileName: "claude.json",
            type: .claude,
            email: "user@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        let subscription = SubscriptionUsageSnapshot(
            profileID: profile.id,
            provider: .claude,
            windows: [UsageWindow(id: "5h", label: "5h", usedPercent: 10, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 200)
        )
        let collector = APIUsageCollectorDouble(
            restoredReport: reportWithClaudeCost(
                cost: "1.00",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let viewModel = subscriptionUsageViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            keyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            proxyService: StubProxyServiceStarter(),
            profiles: [profile],
            subscriptionUsageSnapshotCache: SubscriptionUsageSnapshotCacheDouble(
                snapshots: [profile.id: subscription]
            ),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "key"])
        )

        await viewModel.prepareUsage()

        XCTAssertEqual(
            viewModel.lastSuccessfulUsageRefreshAt,
            Date(timeIntervalSince1970: 100)
        )
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
        codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching = CodexResetCreditsSnapshotCacheDouble(),
        codexResetCreditsNow: @escaping @Sendable () -> Date = { Date() },
        appAppearanceService: (any AppAppearanceApplying)? = nil,
        proxyHealthClient: (any ProxyHealthChecking)? = nil,
        bundledProxyReconciler: any BundledProxyReconciling = BundledProxyReconcilerDouble(
            result: .unchanged(version: CLIProxyAPIVersion("7.2.91")!)
        ),
        apiUsageCollector: any APIUsageCollecting = APIUsageCollectorDouble(),
        secretStore: any SecretStore = InMemorySecretStore(),
        serverStatusRetryDelayNanoseconds: UInt64 = 500_000_000,
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
            proxyHealthClient: proxyHealthClient
                ?? ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            bundledProxyReconciler: bundledProxyReconciler,
            claudeConnector: connectedClaudeConnector(),
            appAppearanceService: appAppearanceService ?? RecordingAppAppearanceService(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: keyStore,
            subscriptionUsageSnapshotCache: subscriptionUsageSnapshotCache,
            codexResetCreditsSnapshotCache: codexResetCreditsSnapshotCache,
            codexResetCreditsNow: codexResetCreditsNow,
            apiUsageCollector: apiUsageCollector,
            secretStore: secretStore,
            subscriptionUsageSleep: subscriptionUsageSleep,
            serverStatusRetryDelayNanoseconds: serverStatusRetryDelayNanoseconds
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

    private func availableUsageReport(
        for profile: AuthProfile,
        resetCreditsAttemptedProfileIDs: Set<String> = [],
        resetCreditsDeferredProfileIDs: Set<String> = []
    ) -> SubscriptionUsageReport {
        SubscriptionUsageReport(
            statesByProfileID: [profile.id: availableUsageState(for: profile)],
            resetCreditsAttemptedProfileIDs: resetCreditsAttemptedProfileIDs,
            resetCreditsDeferredProfileIDs: resetCreditsDeferredProfileIDs,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func resetCreditSnapshot(
        profileID: String,
        fetchedAt: Date
    ) -> CodexResetCreditsSnapshot {
        CodexResetCreditsSnapshot(
            profileID: profileID,
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: 1,
            credits: [.init(
                title: "Full reset",
                status: "available",
                resetType: "full",
                expiresAt: fetchedAt.addingTimeInterval(86_400),
                grantedAt: fetchedAt
            )],
            fetchedAt: fetchedAt
        )
    }

    private func activeRestartOAuthFixture(
        restartErrors: [Error?] = []
    ) -> (
        profile: AuthProfile,
        authStore: StubAuthProfileStore,
        quotaClient: RecordingSubscriptionQuotaClient,
        proxyService: StubProxyServiceStarter,
        oauthLoginService: StubOAuthLoginService,
        sleeper: SubscriptionUsageSleepRecorder,
        viewModel: DashboardViewModel
    ) {
        let profile = AuthProfile(
            fileName: "codex.json",
            type: .codex,
            email: "codex@example.com",
            accountID: "acct_example",
            expired: nil,
            disabled: false
        )
        let disabledProfile = AuthProfile(
            fileName: profile.fileName,
            type: profile.type,
            email: profile.email,
            accountID: profile.accountID,
            expired: profile.expired,
            disabled: true
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: profile.id,
                codex: AppConfig.Codex(
                    opus: .init(model: "gpt-5.6-terra", reasoning: .xhigh, fastModeEnabled: true),
                    sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
                    haiku: .init(model: "gpt-5.6-terra", reasoning: .low)
                ),
                isEnabled: false
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [disabledProfile])
        authStore.nextProfiles = [profile]
        let report = availableUsageReport(
            for: profile,
            resetCreditsAttemptedProfileIDs: [profile.id]
        )
        let quotaClient = RecordingSubscriptionQuotaClient(reports: [report, report, report])
        let proxyService = StubProxyServiceStarter(
            restartErrors: restartErrors,
            suspendedRestartCount: 2
        )
        let oauthLoginService = StubOAuthLoginService()
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauthLoginService,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            secretStore: InMemorySecretStore(),
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) },
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running
        return (profile, authStore, quotaClient, proxyService, oauthLoginService, sleeper, viewModel)
    }

    private func lateActionRefreshOAuthFixture(
        restartErrors: [Error?] = []
    ) async -> (
        claude: AuthProfile,
        codex: AuthProfile,
        authStore: StubAuthProfileStore,
        quotaClient: LateOAuthSplitSubscriptionQuotaClient,
        proxyService: StubProxyServiceStarter,
        oauthLoginService: StubOAuthLoginService,
        collector: APIUsageCollectorDouble,
        sleeper: SubscriptionUsageSleepRecorder,
        viewModel: DashboardViewModel
    ) {
        let claude = AuthProfile(
            fileName: "claude-existing.json",
            type: .claude,
            email: "claude-existing@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let codex = AuthProfile(
            fileName: "codex-changed.json",
            type: .codex,
            email: "codex-changed@example.com",
            accountID: "acct_changed_example",
            expired: nil,
            disabled: false
        )
        let disabledCodex = AuthProfile(
            fileName: codex.fileName,
            type: codex.type,
            email: codex.email,
            accountID: codex.accountID,
            expired: codex.expired,
            disabled: true
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: codex.id,
                codex: AppConfig.Codex(
                    opus: .init(model: "gpt-5.6-terra", reasoning: .xhigh, fastModeEnabled: true),
                    sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
                    haiku: .init(model: "gpt-5.6-terra", reasoning: .low)
                ),
                isEnabled: false
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [claude, disabledCodex])
        authStore.nextProfiles = [claude, codex]
        let quotaClient = LateOAuthSplitSubscriptionQuotaClient(
            initialUsageReport: SubscriptionUsageReport(
                statesByProfileID: [claude.id: availableUsageState(for: claude)],
                fetchedAt: Date(timeIntervalSince1970: 10)
            ),
            actionUsageReport: SubscriptionUsageReport(
                statesByProfileID: [claude.id: .unavailable(.credentialExpired)],
                fetchedAt: Date(timeIntervalSince1970: 20)
            ),
            finalUsageReport: SubscriptionUsageReport(
                statesByProfileID: [
                    claude.id: availableUsageState(for: claude),
                    codex.id: availableUsageState(for: codex)
                ],
                fetchedAt: Date(timeIntervalSince1970: 30)
            ),
            resetReport: SubscriptionUsageReport(
                statesByProfileID: [:],
                resetCreditsOutcomesByProfileID: [codex.id: .unavailable(.transientFailure)],
                resetCreditsAttemptedProfileIDs: [codex.id],
                fetchedAt: Date(timeIntervalSince1970: 30)
            )
        )
        let proxyService = StubProxyServiceStarter(
            restartErrors: restartErrors,
            suspendedRestartCount: 2
        )
        let oauthLoginService = StubOAuthLoginService()
        let collector = APIUsageCollectorDouble()
        let sleeper = SubscriptionUsageSleepRecorder()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauthLoginService,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(),
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) },
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running
        await viewModel.prepareUsage()
        await collector.resetUpdates()
        return (
            claude,
            codex,
            authStore,
            quotaClient,
            proxyService,
            oauthLoginService,
            collector,
            sleeper,
            viewModel
        )
    }

    private func configurationWorkOAuthFixture(
        oauthLoginService: any OAuthLoginStarting,
        restartErrors: [Error?] = [],
        suspendedRestartCount: Int = 0,
        initialUsageReport: SubscriptionUsageReport? = nil
    ) -> (
        claude: AuthProfile,
        codex: AuthProfile,
        authStore: StubAuthProfileStore,
        quotaClient: ConfigurationGateSplitSubscriptionQuotaClient,
        proxyService: StubProxyServiceStarter,
        collector: APIUsageCollectorDouble,
        sleeper: SubscriptionUsageSleepGate,
        viewModel: DashboardViewModel
    ) {
        let claude = AuthProfile(
            fileName: "claude-existing.json",
            type: .claude,
            email: "claude-existing@example.com",
            accountID: nil,
            expired: nil,
            disabled: false
        )
        let codex = AuthProfile(
            fileName: "codex-changed.json",
            type: .codex,
            email: "codex-changed@example.com",
            accountID: "acct_changed_example",
            expired: nil,
            disabled: false
        )
        let disabledCodex = AuthProfile(
            fileName: codex.fileName,
            type: codex.type,
            email: codex.email,
            accountID: codex.accountID,
            expired: codex.expired,
            disabled: true
        )
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(
                id: "codex",
                provider: .codex,
                authProfileID: codex.id,
                codex: AppConfig.Codex(
                    opus: .init(model: "gpt-5.6-terra", reasoning: .xhigh, fastModeEnabled: true),
                    sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
                    haiku: .init(model: "gpt-5.6-terra", reasoning: .low)
                ),
                isEnabled: false
            )
        ]
        let authStore = StubAuthProfileStore(profiles: [claude, disabledCodex])
        authStore.nextProfiles = [claude, codex]
        let quotaClient = ConfigurationGateSplitSubscriptionQuotaClient(
            initialUsageReport: initialUsageReport
        )
        let proxyService = StubProxyServiceStarter(
            restartErrors: restartErrors,
            suspendedRestartCount: suspendedRestartCount
        )
        let collector = APIUsageCollectorDouble()
        let sleeper = SubscriptionUsageSleepGate()
        let viewModel = DashboardViewModel(
            config: config,
            configStore: StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authStore,
            oauthLoginService: oauthLoginService,
            proxyHealthClient: ProxyHealthClient(
                httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))
            ),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            subscriptionQuotaClient: quotaClient,
            subscriptionUsageKeyStore: SubscriptionUsageManagementKeyDouble(isConfiguredValue: true),
            apiUsageCollector: collector,
            secretStore: InMemorySecretStore(),
            subscriptionUsageSleep: { delay in try await sleeper.sleep(delay) },
            serverStatusRetryDelayNanoseconds: 0
        )
        viewModel.serverStatus = readyStatus()
        viewModel.serverControlState = .running
        return (
            claude,
            codex,
            authStore,
            quotaClient,
            proxyService,
            collector,
            sleeper,
            viewModel
        )
    }

    private func waitForOAuthReconciliation(_ authStore: StubAuthProfileStore) async {
        for _ in 0..<1_000 {
            if !authStore.disabledIDUpdates.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected OAuth reconciliation to update the auth profile.")
    }

    private func waitForOAuthInvocations(
        _ oauthLoginService: StubOAuthLoginService,
        expectedCount: Int
    ) async {
        for _ in 0..<1_000 {
            if oauthLoginService.invocations.count >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected OAuth login invocation.")
    }

    private func waitForOAuthCompletion(_ viewModel: DashboardViewModel) async {
        for _ in 0..<1_000 {
            if !viewModel.isProfileLoginInProgress { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected OAuth login completion.")
    }

    private func waitForAPIUsageUpdates(
        _ collector: APIUsageCollectorDouble,
        expectedCount: Int
    ) async {
        for _ in 0..<1_000 {
            if await collector.updateConfigurations().count >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected API usage collector update.")
    }

    private func waitForUsageFetches(
        _ quotaClient: SuspendedSubscriptionQuotaClient,
        expectedCount: Int
    ) async {
        for _ in 0..<100 {
            if await quotaClient.fetchCallCount() >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Expected subscription usage fetch.")
    }

    private func waitForUsageFetches(_ quotaClient: RecordingSubscriptionQuotaClient, expectedCount: Int) async {
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

    private func waitForUsagePollingDelay(
        _ sleeper: SubscriptionUsageSleepGate,
        expected: UInt64
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await sleeper.delays().last == expected { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await sleeper.delays().last == expected
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

    private func waitForServerAction(_ viewModel: DashboardViewModel) async {
        for _ in 0..<100 {
            if viewModel.isServerActionInProgress { return }
            await Task.yield()
        }
        XCTFail("Expected server action to start.")
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

    private func waitForSettingsMessage(
        _ viewModel: DashboardViewModel,
        expected: String
    ) async {
        for _ in 0..<1_000 {
            if viewModel.settingsMessage == expected {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected settings message: \(expected)")
    }

    private func codexAuthProfileStore() -> StubAuthProfileStore {
        StubAuthProfileStore(profiles: [
            AuthProfile(
                fileName: "codex.json",
                type: .codex,
                email: "codex@example.com",
                accountID: nil,
                expired: nil,
                disabled: false,
                prefix: "codex-account"
            )
        ])
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
        config.usageOverlay.hiddenAccountIDs = ["b", "c"]
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
        XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, ["c"])
        XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, ["c"])
    }

    func testPrivacyOnlySavePersistsAccountOrderAfterProviderRowsChange() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude)
        ]
        config.accountOrder = ["a"]
        let store = StubConfigStore(config: config)
        let secrets = InMemorySecretStore()
        let viewModel = makeViewModel(
            config: config,
            profiles: [profile("a.json", type: .claude)],
            configStore: store,
            secretStore: secrets
        )
        try secrets.set("new-key", for: .claudeAPIKey)

        viewModel.toggleAccountDetailVisibility("a")

        XCTAssertEqual(viewModel.config.accountOrder, ["a", "claude-api"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["a", "claude-api"])
    }

    func testAPIKeyReRegistrationAppendsAfterSurvivingAccounts() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            commandProfile(id: "a", authProfileID: "a.json", provider: .claude)
        ]
        config.accountOrder = ["claude-api", "a"]
        config.usageOverlay.hiddenAccountIDs = [ProviderRowState.ID.claudeAPI.rawValue]
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
        XCTAssertEqual(viewModel.config.usageOverlay.hiddenAccountIDs, [])
        XCTAssertEqual(store.savedConfigs.last?.usageOverlay.hiddenAccountIDs, [])

        try viewModel.saveClaudeAPISettings(
            functionName: "ccapi",
            nickname: "API",
            dangerousPermissionsEnabled: false,
            key: "new-key"
        )

        XCTAssertEqual(viewModel.providerRows.map(\.id.rawValue), ["a", "claude-api"])
        XCTAssertEqual(store.savedConfigs.last?.accountOrder, ["a", "claude-api"])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claudeAPI }?.showsInUsageOverlay, true)
    }

    func testRemovingMissingSecretAPIProfileStillRestartsProxy() async {
        var config = AppConfig.default
        config.apiKeyProfiles = [.legacy(provider: .claude)]
        let store = StubConfigStore(config: config)
        let proxyService = StubProxyServiceStarter()
        let viewModel = makeViewModel(
            config: config,
            profiles: [],
            configStore: store,
            proxyService: proxyService
        )
        viewModel.serverControlState = .running

        viewModel.removeAPIProvider(.claudeAPI)
        let didRestart = await proxyService.reachesRestartCount(1)

        XCTAssertTrue(didRestart)
        XCTAssertTrue(viewModel.config.apiKeyProfiles.isEmpty)
        XCTAssertEqual(store.savedConfigs.last?.apiKeyProfiles, [])
        XCTAssertEqual(proxyService.restartPorts, [config.port])
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
            codex: provider == .codex ? AppConfig.Codex.default : nil,
            modelPrefix: "\(provider.rawValue)-\(id)",
            isEnabled: true
        )
    }

    private func makeViewModel(
        config: AppConfig,
        profiles: [AuthProfile],
        configStore: StubConfigStore? = nil,
        authProfileStore: (any AuthProfileManaging)? = nil,
        secretStore: any SecretStore = InMemorySecretStore(),
        proxyService: StubProxyServiceStarter = StubProxyServiceStarter()
    ) -> DashboardViewModel {
        DashboardViewModel(
            config: config,
            configStore: configStore ?? StubConfigStore(config: config),
            shellInstaller: StubShellInstaller(),
            authProfileStore: authProfileStore ?? StubAuthProfileStore(profiles: profiles),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: proxyService,
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

private final class RecordingAppLogger: AppLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredLevel = LogLevel.info
    private var recordedEvents: [AppLogEvent] = []

    var minimumLevel: LogLevel {
        lock.withLock { configuredLevel }
    }

    var diagnostics: AppLogDiagnostics {
        .unavailable(reason: .notConfigured)
    }

    var events: [AppLogEvent] {
        lock.withLock { recordedEvents }
    }

    func configure(minimumLevel: LogLevel) {
        lock.withLock { configuredLevel = minimumLevel }
    }

    func record(_ event: AppLogEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}

private final class RecordingAppAppearanceService: AppAppearanceApplying, @unchecked Sendable {
    private(set) var showDockIconValues: [Bool] = []
    private(set) var appearanceValues: [AppearanceMode] = []

    func apply(showDockIcon: Bool) {
        showDockIconValues.append(showDockIcon)
    }

    func apply(appearance: AppearanceMode) {
        appearanceValues.append(appearance)
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

private actor TerminationCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor APIUsageCollectorDouble: APIUsageCollecting {
    private let restoredReport: APIUsageCollectionReport
    private let reloadReport: APIUsageCollectionReport
    private let suspendsReload: Bool
    private let suspendsUpdate: Bool
    private let suspendsStop: Bool
    private let keepsReportStreamOpen: Bool
    private var startCalls = 0
    private var reloadCalls = 0
    private var stopCalls = 0
    private var stopFailuresRemaining: Int
    private var updates: [APIUsageCollectorConfiguration] = []
    private var recordedStopReasons: [APIUsageCollectorStopReason] = []
    private var startWaiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var updateWaiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var reportSubscriberWaiters: [CheckedContinuation<Void, Never>] = []
    private var reportContinuation: AsyncStream<APIUsageCollectionReport>.Continuation?
    private var reportGeneration: UInt64 = 0
    private nonisolated let reloadGate = APIUsageReloadGate()
    private nonisolated let updateGate = APIUsageUpdateGate()
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(
        restoredReport: APIUsageCollectionReport = .init(
            statesByProfileID: [:],
            collectedAt: Date(timeIntervalSince1970: 0)
        ),
        reloadReport: APIUsageCollectionReport = .init(
            statesByProfileID: [:],
            collectedAt: Date(timeIntervalSince1970: 0)
        ),
        suspendsReload: Bool = false,
        suspendsUpdate: Bool = false,
        suspendsStop: Bool = false,
        stopFailuresRemaining: Int = 0,
        keepsReportStreamOpen: Bool = false
    ) {
        self.restoredReport = restoredReport
        self.reloadReport = reloadReport
        self.suspendsReload = suspendsReload
        self.suspendsUpdate = suspendsUpdate
        self.suspendsStop = suspendsStop
        self.stopFailuresRemaining = stopFailuresRemaining
        self.keepsReportStreamOpen = keepsReportStreamOpen
    }

    func reports() async -> AsyncStream<APIUsageCollectionReport> {
        guard keepsReportStreamOpen else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            reportContinuation = continuation
            let waiters = reportSubscriberWaiters
            reportSubscriberWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        identified(restoredReport)
    }

    func start(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        startCalls += 1
        let readyWaiters = startWaiters.filter { startCalls >= $0.expectedCount }
        startWaiters.removeAll { startCalls >= $0.expectedCount }
        readyWaiters.forEach { $0.continuation.resume() }
        return identified(restoredReport)
    }

    func update(
        configuration: APIUsageCollectorConfiguration
    ) async -> APIUsageCollectionReport {
        updates.append(configuration)
        let readyWaiters = updateWaiters.filter { updates.count >= $0.expectedCount }
        updateWaiters.removeAll { updates.count >= $0.expectedCount }
        readyWaiters.forEach { $0.continuation.resume() }
        if suspendsUpdate {
            await updateGate.wait()
        }
        return identified(restoredReport)
    }

    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        reloadCalls += 1
        let report = identified(reloadReport)
        guard suspendsReload else { return report }
        return await reloadGate.wait(returning: report)
    }

    private func identified(_ report: APIUsageCollectionReport) -> APIUsageCollectionReport {
        reportGeneration &+= 1
        return APIUsageCollectionReport(
            identity: .init(generation: reportGeneration),
            statesByProfileID: report.statesByProfileID,
            collectedAt: report.collectedAt
        )
    }

    func stop(reason: APIUsageCollectorStopReason, at: Date) async throws {
        stopCalls += 1
        recordedStopReasons.append(reason)
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendsStop {
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        if stopFailuresRemaining > 0 {
            stopFailuresRemaining -= 1
            throw APIUsageLedgerStoreError.persistenceFailure
        }
    }

    func emit(_ report: APIUsageCollectionReport) {
        reportContinuation?.yield(report)
    }

    func finishReports() {
        reportContinuation?.finish()
        reportContinuation = nil
    }

    nonisolated func waitUntilReloadSuspended() async {
        await reloadGate.waitUntilWaiting()
    }

    nonisolated func resumeReload() {
        reloadGate.resume()
    }

    nonisolated func waitUntilUpdateSuspended() async {
        await updateGate.waitUntilWaiting()
    }

    nonisolated func resumeUpdate() {
        updateGate.resume()
    }

    func resumeStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func startCount() -> Int { startCalls }
    func reloadCount() -> Int { reloadCalls }
    func stopCount() -> Int { stopCalls }
    func updateConfigurations() -> [APIUsageCollectorConfiguration] { updates }
    func resetUpdates() { updates.removeAll() }
    func stopReasons() -> [APIUsageCollectorStopReason] { recordedStopReasons }
    func deleteLedgerCount() -> Int { 0 }

    func waitForStartCount(_ expectedCount: Int) async {
        if startCalls >= expectedCount { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((expectedCount, continuation))
        }
    }

    func waitForUpdateCount(_ expectedCount: Int) async {
        if updates.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            updateWaiters.append((expectedCount, continuation))
        }
    }

    func waitForReportSubscriber() async {
        if reportContinuation != nil { return }
        await withCheckedContinuation { continuation in
            reportSubscriberWaiters.append(continuation)
        }
    }

    func waitForStop() async {
        if stopCalls > 0 { return }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }
}

private final class APIUsageReloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait(returning report: APIUsageCollectionReport) async -> APIUsageCollectionReport {
        await withCheckedContinuation { continuation in
            let observers = lock.withLock {
                self.continuation = continuation
                let observers = waitingObservers
                waitingObservers.removeAll()
                return observers
            }
            observers.forEach { $0.resume() }
        }
        return report
    }

    func waitUntilWaiting() async {
        if lock.withLock({ continuation != nil }) { return }
        await withCheckedContinuation { observer in
            let shouldResume = lock.withLock {
                if continuation != nil { return true }
                waitingObservers.append(observer)
                return false
            }
            if shouldResume { observer.resume() }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume()
    }
}

private final class APIUsageUpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let observers = lock.withLock {
                self.continuation = continuation
                let observers = waitingObservers
                waitingObservers.removeAll()
                return observers
            }
            observers.forEach { $0.resume() }
        }
    }

    func waitUntilWaiting() async {
        if lock.withLock({ continuation != nil }) { return }
        await withCheckedContinuation { observer in
            let shouldResume = lock.withLock {
                if continuation != nil { return true }
                waitingObservers.append(observer)
                return false
            }
            if shouldResume { observer.resume() }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume()
    }
}

private func reportWithClaudeCost(
    cost: String,
    updatedAt: Date,
    identity: APIUsageCollectorIdentity = .init(generation: 0)
) -> APIUsageCollectionReport {
    let day = APICostPeriodSnapshot(
        period: .day,
        estimatedUSD: Decimal(string: cost)!,
        totalTokens: 100,
        requestCount: 1,
        failedRequestCount: 0,
        pricedRequestCount: 1,
        unpricedRequestCount: 0,
        intervalStart: Date(timeIntervalSince1970: 0),
        intervalEnd: updatedAt,
        issues: []
    )
    let month = APICostPeriodSnapshot(
        period: .month,
        estimatedUSD: Decimal(string: cost)!,
        totalTokens: 100,
        requestCount: 1,
        failedRequestCount: 0,
        pricedRequestCount: 1,
        unpricedRequestCount: 0,
        intervalStart: Date(timeIntervalSince1970: 0),
        intervalEnd: updatedAt,
        issues: []
    )
    let snapshot = APICostSnapshot(
        profileID: "claude-api",
        provider: .claude,
        day: day,
        month: month,
        reportingTimeZoneID: "UTC",
        updatedAt: updatedAt
    )
    return .init(
        identity: identity,
        statesByProfileID: ["claude-api": .available(snapshot)],
        collectedAt: updatedAt
    )
}

private actor IdentityAPIUsageCollectorDouble: APIUsageCollecting {
    private let restoredReport: APIUsageCollectionReport
    private let startReport: APIUsageCollectionReport
    private let updateReport: APIUsageCollectionReport
    private let publishesBeforeReturning: Bool
    private var continuation: AsyncStream<APIUsageCollectionReport>.Continuation?
    private var subscriberWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        restoredReport: APIUsageCollectionReport,
        startReport: APIUsageCollectionReport,
        updateReport: APIUsageCollectionReport,
        publishesBeforeReturning: Bool
    ) {
        self.restoredReport = restoredReport
        self.startReport = startReport
        self.updateReport = updateReport
        self.publishesBeforeReturning = publishesBeforeReturning
    }

    func reports() async -> AsyncStream<APIUsageCollectionReport> {
        AsyncStream(bufferingPolicy: .bufferingNewest(10)) { continuation in
            self.continuation = continuation
            let waiters = subscriberWaiters
            subscriberWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        restoredReport
    }

    func start(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        if publishesBeforeReturning { continuation?.yield(startReport) }
        return startReport
    }

    func update(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        if publishesBeforeReturning { continuation?.yield(updateReport) }
        return updateReport
    }

    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        updateReport
    }

    func stop(reason: APIUsageCollectorStopReason, at: Date) async throws {}

    func emit(_ report: APIUsageCollectionReport) {
        continuation?.yield(report)
    }

    func finishReports() {
        continuation?.finish()
        continuation = nil
    }

    func waitForReportSubscriber() async {
        if continuation != nil { return }
        await withCheckedContinuation { subscriberWaiters.append($0) }
    }
}

private actor CancellableLifecycleAPIUsageCollectorDouble: APIUsageCollecting {
    enum Call: Equatable {
        case restore
        case start
        case update
        case reload
        case stop(APIUsageCollectorStopReason)
    }

    private let reloadGate = CancellableOperationGate()
    private let updateGate = CancellableOperationGate()
    private let onStop: @Sendable () -> Void
    private var recordedCalls: [Call] = []
    private var generation: UInt64 = 0

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func reports() async -> AsyncStream<APIUsageCollectionReport> {
        AsyncStream { $0.finish() }
    }

    func restore(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        recordedCalls.append(.restore)
        return nextReport()
    }

    func start(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        recordedCalls.append(.start)
        return nextReport()
    }

    func update(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        recordedCalls.append(.update)
        await updateGate.wait()
        return nextReport()
    }

    func reload(configuration: APIUsageCollectorConfiguration) async -> APIUsageCollectionReport {
        recordedCalls.append(.reload)
        await reloadGate.wait()
        return nextReport()
    }

    func stop(reason: APIUsageCollectorStopReason, at: Date) async throws {
        recordedCalls.append(.stop(reason))
        onStop()
    }

    nonisolated func waitForReloadToSuspend() async {
        await reloadGate.waitUntilWaiting()
    }

    nonisolated func waitForUpdateToSuspend() async {
        await updateGate.waitUntilWaiting()
    }

    nonisolated func releaseAll() {
        reloadGate.resume()
        updateGate.resume()
    }

    func calls() -> [Call] { recordedCalls }

    private func nextReport() -> APIUsageCollectionReport {
        generation &+= 1
        return APIUsageCollectionReport(
            identity: .init(generation: generation),
            statesByProfileID: [:],
            collectedAt: Date(timeIntervalSince1970: TimeInterval(generation))
        )
    }
}

private final class CancellableOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (shouldResume, observers) = lock.withLock {
                    if Task.isCancelled {
                        return (true, [CheckedContinuation<Void, Never>]())
                    }
                    self.continuation = continuation
                    let observers = waitingObservers
                    waitingObservers.removeAll()
                    return (false, observers)
                }
                observers.forEach { $0.resume() }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            self.resume()
        }
    }

    func waitUntilWaiting() async {
        if lock.withLock({ continuation != nil }) { return }
        await withCheckedContinuation { observer in
            let shouldResume = lock.withLock {
                if continuation != nil { return true }
                waitingObservers.append(observer)
                return false
            }
            if shouldResume { observer.resume() }
        }
    }

    func resume() {
        let continuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume()
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
    private var usageProfileIDSets: [Set<String>] = []
    private var resetCreditProfileIDSets: [Set<String>] = []

    init(reports: [SubscriptionUsageReport]) {
        self.reports = reports
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        callCount += 1
        profileIDs.append(profiles.map(\.id))
        usageProfileIDSets.append(usageProfileIDs)
        resetCreditProfileIDSets.append(resetCreditsProfileIDs)
        return reports.removeFirst()
    }

    func fetchCallCount() -> Int { callCount }
    func requestedProfileIDs() -> [[String]] { profileIDs }
    func requestedUsageProfileIDSets() -> [Set<String>] { usageProfileIDSets }
    func requestedResetCreditProfileIDSets() -> [Set<String>] { resetCreditProfileIDSets }
}

private final class SubscriptionDispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolution: Bool?

    func wait(cancellationAware: Bool) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let currentResolution = lock.withLock { () -> Bool? in
                    if let resolution = self.resolution { return resolution }
                    self.continuation = continuation
                    return nil
                }
                if let currentResolution {
                    continuation.resume(returning: currentResolution)
                }
            }
        } onCancel: {
            if cancellationAware {
                self.resolve(shouldDispatch: false)
            }
        }
    }

    func release() {
        resolve(shouldDispatch: true)
    }

    private func resolve(shouldDispatch: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard resolution == nil else { return nil }
            resolution = shouldDispatch
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: shouldDispatch)
    }
}

private actor DispatchControlledConcurrentSubscriptionQuotaClient: ConcurrentSubscriptionQuotaFetching {
    enum CancellationMode: Equatable {
        case aware
        case resistant
    }

    struct DispatchRecord: Equatable {
        let port: Int
        let profiles: [AuthProfile]
        let usageProfileIDs: Set<String>
        let resetCreditsProfileIDs: Set<String>
    }

    private let cancellationMode: CancellationMode
    private let suspendFirstUsage: Bool
    private let suspendFirstReset: Bool
    private let usageGate = SubscriptionDispatchGate()
    private let resetGate = SubscriptionDispatchGate()
    private var usageReports: [SubscriptionUsageReport]
    private var resetReports: [SubscriptionUsageReport]
    private var enteredUsage: [DispatchRecord] = []
    private var enteredReset: [DispatchRecord] = []
    private var actualUsage: [DispatchRecord] = []
    private var actualReset: [DispatchRecord] = []
    private var completedUsageCount = 0
    private var completedResetCount = 0
    private var usageEntryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resetEntryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var usageCompletionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resetCompletionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var actualUsageWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var actualResetWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        cancellationMode: CancellationMode,
        suspendFirstUsage: Bool = false,
        suspendFirstReset: Bool = false,
        usageReports: [SubscriptionUsageReport] = [],
        resetReports: [SubscriptionUsageReport] = []
    ) {
        self.cancellationMode = cancellationMode
        self.suspendFirstUsage = suspendFirstUsage
        self.suspendFirstReset = suspendFirstReset
        self.usageReports = usageReports
        self.resetReports = resetReports
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        let record = DispatchRecord(
            port: port,
            profiles: profiles,
            usageProfileIDs: usageProfileIDs,
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
        if !resetCreditsProfileIDs.isEmpty {
            enteredReset.append(record)
            resumeWaiters(&resetEntryWaiters, currentCount: enteredReset.count)
            let shouldSuspend = suspendFirstReset && enteredReset.count == 1
            if shouldSuspend {
                let shouldDispatch = await resetGate.wait(cancellationAware: cancellationMode == .aware)
                guard shouldDispatch else {
                    completedResetCount += 1
                    resumeWaiters(&resetCompletionWaiters, currentCount: completedResetCount)
                    return SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: Date())
                }
            }
            actualReset.append(record)
            resumeWaiters(&actualResetWaiters, currentCount: actualReset.count)
            let report = resetReports.isEmpty
                ? resetReport(for: record, ordinal: actualReset.count)
                : resetReports.removeFirst()
            completedResetCount += 1
            resumeWaiters(&resetCompletionWaiters, currentCount: completedResetCount)
            return report
        }

        enteredUsage.append(record)
        resumeWaiters(&usageEntryWaiters, currentCount: enteredUsage.count)
        let shouldSuspend = suspendFirstUsage && enteredUsage.count == 1
        if shouldSuspend {
            let shouldDispatch = await usageGate.wait(cancellationAware: cancellationMode == .aware)
            guard shouldDispatch else {
                completedUsageCount += 1
                resumeWaiters(&usageCompletionWaiters, currentCount: completedUsageCount)
                return SubscriptionUsageReport(statesByProfileID: [:], fetchedAt: Date())
            }
        }
        actualUsage.append(record)
        resumeWaiters(&actualUsageWaiters, currentCount: actualUsage.count)
        let report = usageReports.isEmpty
            ? usageReport(for: record, ordinal: actualUsage.count)
            : usageReports.removeFirst()
        completedUsageCount += 1
        resumeWaiters(&usageCompletionWaiters, currentCount: completedUsageCount)
        return report
    }

    func waitForUsageEntries(_ expectedCount: Int) async {
        if enteredUsage.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            usageEntryWaiters.append((expectedCount, continuation))
        }
    }

    func waitForResetEntries(_ expectedCount: Int) async {
        if enteredReset.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            resetEntryWaiters.append((expectedCount, continuation))
        }
    }

    func waitForUsageCompletions(_ expectedCount: Int) async {
        if completedUsageCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            usageCompletionWaiters.append((expectedCount, continuation))
        }
    }

    func waitForResetCompletions(_ expectedCount: Int) async {
        if completedResetCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            resetCompletionWaiters.append((expectedCount, continuation))
        }
    }

    func waitForActualUsage(_ expectedCount: Int) async {
        if actualUsage.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            actualUsageWaiters.append((expectedCount, continuation))
        }
    }

    func waitForActualReset(_ expectedCount: Int) async {
        if actualReset.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            actualResetWaiters.append((expectedCount, continuation))
        }
    }

    nonisolated func releaseFirstUsageDispatch() {
        usageGate.release()
    }

    nonisolated func releaseFirstResetDispatch() {
        resetGate.release()
    }

    func actualUsageDispatches() -> [DispatchRecord] { actualUsage }
    func actualResetDispatches() -> [DispatchRecord] { actualReset }

    func resetRecords() {
        enteredUsage.removeAll()
        enteredReset.removeAll()
        actualUsage.removeAll()
        actualReset.removeAll()
        completedUsageCount = 0
        completedResetCount = 0
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        currentCount: Int
    ) {
        let ready = waiters.filter { currentCount >= $0.0 }.map(\.1)
        waiters.removeAll { currentCount >= $0.0 }
        ready.forEach { $0.resume() }
    }

    private func usageReport(for record: DispatchRecord, ordinal: Int) -> SubscriptionUsageReport {
        let states: [String: AccountSubscriptionUsageState] = Dictionary(
            uniqueKeysWithValues: record.profiles.compactMap { profile -> (String, AccountSubscriptionUsageState)? in
            guard record.usageProfileIDs.contains(profile.id) else { return nil }
            return (
                profile.id,
                AccountSubscriptionUsageState.available(SubscriptionUsageSnapshot(
                    profileID: profile.id,
                    provider: profile.type,
                    windows: [UsageWindow(
                        id: "primary",
                        label: "Primary",
                        usedPercent: 25,
                        resetAt: nil
                    )],
                    fetchedAt: Date(timeIntervalSince1970: TimeInterval(100 + ordinal))
                ))
            )
        })
        return SubscriptionUsageReport(
            statesByProfileID: states,
            fetchedAt: Date(timeIntervalSince1970: TimeInterval(100 + ordinal))
        )
    }

    private func resetReport(for record: DispatchRecord, ordinal: Int) -> SubscriptionUsageReport {
        let fetchedAt = Date(timeIntervalSince1970: TimeInterval(200 + ordinal))
        let outcomes = Dictionary(uniqueKeysWithValues: record.resetCreditsProfileIDs.map { profileID in
            (
                profileID,
                CodexResetCreditsRefreshOutcome.available(CodexResetCreditsSnapshot(
                    profileID: profileID,
                    reportedAvailableCount: 1,
                    reportedTotalEarnedCount: 1,
                    credits: [],
                    fetchedAt: fetchedAt
                ))
            )
        })
        return SubscriptionUsageReport(
            statesByProfileID: [:],
            resetCreditsOutcomesByProfileID: outcomes,
            resetCreditsAttemptedProfileIDs: record.resetCreditsProfileIDs,
            fetchedAt: fetchedAt
        )
    }
}

private actor ConfigurationGateSplitSubscriptionQuotaClient: ConcurrentSubscriptionQuotaFetching {
    private var initialUsageReport: SubscriptionUsageReport?
    private var usageProfileIDSets: [Set<String>] = []
    private var resetCreditProfileIDSets: [Set<String>] = []

    init(initialUsageReport: SubscriptionUsageReport? = nil) {
        self.initialUsageReport = initialUsageReport
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        if !resetCreditsProfileIDs.isEmpty {
            resetCreditProfileIDSets.append(resetCreditsProfileIDs)
            return SubscriptionUsageReport(
                statesByProfileID: [:],
                resetCreditsOutcomesByProfileID: Dictionary(
                    uniqueKeysWithValues: resetCreditsProfileIDs.map {
                        ($0, .unavailable(.transientFailure))
                    }
                ),
                resetCreditsAttemptedProfileIDs: resetCreditsProfileIDs,
                fetchedAt: Date(timeIntervalSince1970: TimeInterval(resetCreditProfileIDSets.count))
            )
        }

        usageProfileIDSets.append(usageProfileIDs)
        if let initialUsageReport {
            self.initialUsageReport = nil
            return initialUsageReport
        }
        let states = Dictionary(
            uniqueKeysWithValues: profiles.compactMap { profile -> (String, AccountSubscriptionUsageState)? in
                guard usageProfileIDs.contains(profile.id) else { return nil }
                return (
                    profile.id,
                    .available(SubscriptionUsageSnapshot(
                        profileID: profile.id,
                        provider: profile.type,
                        windows: [
                            UsageWindow(
                                id: "primary",
                                label: "Primary",
                                usedPercent: 25,
                                resetAt: nil
                            )
                        ],
                        fetchedAt: Date(timeIntervalSince1970: TimeInterval(usageProfileIDSets.count))
                    ))
                )
            }
        )
        return SubscriptionUsageReport(
            statesByProfileID: states,
            fetchedAt: Date(timeIntervalSince1970: TimeInterval(usageProfileIDSets.count))
        )
    }

    func waitForUsageRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if usageProfileIDSets.count >= expectedCount { return true }
            await Task.yield()
        }
        return usageProfileIDSets.count >= expectedCount
    }

    func waitForResetRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if resetCreditProfileIDSets.count >= expectedCount { return true }
            await Task.yield()
        }
        return resetCreditProfileIDSets.count >= expectedCount
    }

    func requestedUsageProfileIDSets() -> [Set<String>] { usageProfileIDSets }
    func requestedResetCreditProfileIDSets() -> [Set<String>] { resetCreditProfileIDSets }
}

private actor ResetSuspendingSubscriptionQuotaClient: ConcurrentSubscriptionQuotaFetching {
    private var usageReports: [SubscriptionUsageReport]
    private var resetReportsBeforeSuspension: [SubscriptionUsageReport]
    private var usageRequests = 0
    private var resetContinuations: [CheckedContinuation<SubscriptionUsageReport, Never>] = []
    private var resetCreditProfileIDSets: [Set<String>] = []

    init(
        usageReport: SubscriptionUsageReport,
        resetReportsBeforeSuspension: [SubscriptionUsageReport] = []
    ) {
        self.usageReports = [usageReport]
        self.resetReportsBeforeSuspension = resetReportsBeforeSuspension
    }

    init(
        usageReports: [SubscriptionUsageReport],
        resetReportsBeforeSuspension: [SubscriptionUsageReport] = []
    ) {
        self.usageReports = usageReports
        self.resetReportsBeforeSuspension = resetReportsBeforeSuspension
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        guard !resetCreditsProfileIDs.isEmpty else {
            usageRequests += 1
            return usageReports.count > 1 ? usageReports.removeFirst() : usageReports[0]
        }
        resetCreditProfileIDSets.append(resetCreditsProfileIDs)
        if !resetReportsBeforeSuspension.isEmpty {
            return resetReportsBeforeSuspension.removeFirst()
        }
        return await withCheckedContinuation { resetContinuations.append($0) }
    }

    func waitForUsageRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if usageRequests >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return usageRequests >= expectedCount
    }

    func usageRequestCount() -> Int { usageRequests }

    func waitForResetRequest() async {
        _ = await waitForResetRequests(expectedCount: 1)
    }

    func waitForResetRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if resetCreditProfileIDSets.count >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return resetCreditProfileIDSets.count >= expectedCount
    }

    func requestedResetCreditProfileIDSets() -> [Set<String>] {
        resetCreditProfileIDSets
    }

    func resolveReset(with report: SubscriptionUsageReport) {
        let pending = resetContinuations
        resetContinuations.removeAll()
        pending.forEach { $0.resume(returning: report) }
    }
}

private actor LateOAuthSplitSubscriptionQuotaClient: ConcurrentSubscriptionQuotaFetching {
    private let initialUsageReport: SubscriptionUsageReport
    private let actionUsageReport: SubscriptionUsageReport
    private let finalUsageReport: SubscriptionUsageReport
    private let resetReport: SubscriptionUsageReport
    private var usageProfileIDSets: [Set<String>] = []
    private var resetCreditProfileIDSets: [Set<String>] = []
    private var actionUsageContinuation: CheckedContinuation<SubscriptionUsageReport, Never>?

    init(
        initialUsageReport: SubscriptionUsageReport,
        actionUsageReport: SubscriptionUsageReport,
        finalUsageReport: SubscriptionUsageReport,
        resetReport: SubscriptionUsageReport
    ) {
        self.initialUsageReport = initialUsageReport
        self.actionUsageReport = actionUsageReport
        self.finalUsageReport = finalUsageReport
        self.resetReport = resetReport
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        if !resetCreditsProfileIDs.isEmpty {
            resetCreditProfileIDSets.append(resetCreditsProfileIDs)
            return resetReport
        }

        usageProfileIDSets.append(usageProfileIDs)
        switch usageProfileIDSets.count {
        case 1:
            return initialUsageReport
        case 2:
            return await withCheckedContinuation { actionUsageContinuation = $0 }
        default:
            return finalUsageReport
        }
    }

    func waitForUsageRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if usageProfileIDSets.count >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return usageProfileIDSets.count >= expectedCount
    }

    func waitForResetRequests(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if resetCreditProfileIDSets.count >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return resetCreditProfileIDSets.count >= expectedCount
    }

    func releaseActionUsage() {
        actionUsageContinuation?.resume(returning: actionUsageReport)
        actionUsageContinuation = nil
    }

    func requestedUsageProfileIDSets() -> [Set<String>] { usageProfileIDSets }
    func requestedResetCreditProfileIDSets() -> [Set<String>] { resetCreditProfileIDSets }
}

private actor SuspendedSubscriptionQuotaClient: SubscriptionQuotaFetching {
    private var reportsBeforeSuspension: [SubscriptionUsageReport]
    private var continuations: [CheckedContinuation<SubscriptionUsageReport, Never>] = []
    private var callCount = 0
    private var profileIDs: [[String]] = []
    private var usageProfileIDSets: [Set<String>] = []
    private var resetCreditProfileIDSets: [Set<String>] = []

    init(reportsBeforeSuspension: [SubscriptionUsageReport] = []) {
        self.reportsBeforeSuspension = reportsBeforeSuspension
    }

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        await fetchUsage(port: port, profiles: profiles, resetCreditsProfileIDs: [])
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        await fetchUsage(
            port: port,
            profiles: profiles,
            usageProfileIDs: Set(profiles.map(\.id)),
            resetCreditsProfileIDs: resetCreditsProfileIDs
        )
    }

    func fetchUsage(
        port: Int,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>
    ) async -> SubscriptionUsageReport {
        callCount += 1
        profileIDs.append(profiles.map(\.id))
        usageProfileIDSets.append(usageProfileIDs)
        resetCreditProfileIDSets.append(resetCreditsProfileIDs)
        if !reportsBeforeSuspension.isEmpty {
            return reportsBeforeSuspension.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func fetchCallCount() -> Int { callCount }
    func requestedProfileIDs() -> [[String]] { profileIDs }
    func requestedUsageProfileIDSets() -> [Set<String>] { usageProfileIDSets }
    func requestedResetCreditProfileIDSets() -> [Set<String>] { resetCreditProfileIDSets }

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

    func waitForDelays(expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if recordedDelays.count >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return recordedDelays.count >= expectedCount
    }

    func delays() -> [UInt64] { recordedDelays }
}

private final class SubscriptionUsageSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: UInt64) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    recordedDelays.append(delay)
                    if Task.isCancelled { return true }
                    continuations.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            self.resumeAll()
        }
        try Task.checkCancellation()
    }

    func waitForSleeps(expectedCount: Int) async {
        for _ in 0..<1_000 {
            if lock.withLock({ recordedDelays.count >= expectedCount }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected subscription usage polling sleep.")
    }

    func resumeNext() async {
        let continuation = lock.withLock {
            continuations.isEmpty ? nil : continuations.removeFirst()
        }
        continuation?.resume()
    }

    func delays() async -> [UInt64] {
        lock.withLock { recordedDelays }
    }

    private func resumeAll() {
        let pending = lock.withLock {
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private final class MutableDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}

private final class CodexResetCreditsSnapshotCacheDouble: CodexResetCreditsSnapshotCaching, @unchecked Sendable {
    private var snapshots: [String: CodexResetCreditsSnapshot]

    init(snapshots: [String: CodexResetCreditsSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    var isEmpty: Bool { snapshots.isEmpty }
    func load() -> [String: CodexResetCreditsSnapshot] { snapshots }
    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws { self.snapshots = snapshots }
    func storedSnapshots() -> [String: CodexResetCreditsSnapshot] { snapshots }
    func clear() throws { snapshots = [:] }
}

private final class SubscriptionUsageSnapshotCacheDouble: SubscriptionUsageSnapshotCaching, @unchecked Sendable {
    private var snapshots: [String: SubscriptionUsageSnapshot]

    init(snapshots: [String: SubscriptionUsageSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    var isEmpty: Bool { snapshots.isEmpty }

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

private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private let getError: Error?
    private let lock = NSLock()
    private(set) var setValues: [(String, SecretKey)] = []
    private(set) var deleteKeys: [SecretKey] = []

    init(getError: Error? = nil) {
        self.getError = getError
    }

    func get(_ key: SecretKey) throws -> String {
        if let getError { throw getError }
        throw SecretStoreError.missingSecret(key.rawValue)
    }

    func set(_ value: String, for key: SecretKey) throws {
        lock.withLock { setValues.append((value, key)) }
    }

    func delete(_ key: SecretKey) throws {
        lock.withLock { deleteKeys.append(key) }
    }
}

private struct DashboardUpdateChecker: CLIProxyAPIUpdateChecking {
    func latestRelease() async throws -> CLIProxyAPIRelease {
        throw URLError(.unsupportedURL)
    }
}

private final class DashboardUpdateBinaryStore: CLIProxyAPIUpdateBinaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var applyPendingCallCount = 0

    func validatedCurrentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? {
        CLIProxyAPIVersion("7.2.42")
    }

    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {}

    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? { nil }

    func schedulePendingForNextStart() throws {}

    func applyPending() throws {
        lock.withLock { applyPendingCallCount += 1 }
    }
}

private final class StubConfigStore: AppConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadError: Error?
    private let saveError: Error?
    private(set) var savedConfigs: [AppConfig] = []
    var config: AppConfig

    init(
        config: AppConfig = .default,
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.config = config
        self.loadError = loadError
        self.saveError = saveError
    }

    func load() throws -> AppConfig {
        if let loadError {
            throw loadError
        }
        return config
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

private final class LoginMigratingAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let initial: [AuthProfile]
    private let afterLogin: [AuthProfile]
    private let migration: AuthProfileMigration
    private let failReloadsAfterFinalization: Bool
    private var loginCompleted = false
    private var migrationFinalized = false

    init(
        initial: [AuthProfile],
        afterLogin: [AuthProfile],
        migration: AuthProfileMigration,
        failReloadsAfterFinalization: Bool = false
    ) {
        self.initial = initial
        self.afterLogin = afterLogin
        self.migration = migration
        self.failReloadsAfterFinalization = failReloadsAfterFinalization
    }

    func completeLogin() {
        loginCompleted = true
    }

    func profiles() throws -> [AuthProfile] {
        if migrationFinalized && failReloadsAfterFinalization {
            throw NSError(domain: "test", code: 1)
        }
        return loginCompleted || migrationFinalized ? afterLogin : initial
    }

    func prepareCodexCredentialMigrations() throws -> [AuthProfileMigration] {
        loginCompleted && !migrationFinalized ? [migration] : []
    }

    func finalizeCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) throws {
        migrationFinalized = true
    }

    func setDisabled(_ disabled: Bool, id: String) throws -> Bool {
        afterLogin.contains { $0.id == id }
    }

    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int { 0 }
    func delete(for type: AuthProfileType) throws -> Int { 0 }
}

private final class MigratingAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let before: [AuthProfile]
    private let after: [AuthProfile]
    private let migrations: [AuthProfileMigration]
    private(set) var finalizedMigrations: [AuthProfileMigration] = []
    private(set) var rolledBackMigrations: [AuthProfileMigration] = []
    private var prepared = false
    private var finalized = false
    private var rolledBack = false

    private let finalizeError: Error?

    init(
        before: [AuthProfile],
        after: [AuthProfile],
        migrations: [AuthProfileMigration],
        finalizeError: Error? = nil
    ) {
        self.before = before
        self.after = after
        self.migrations = migrations
        self.finalizeError = finalizeError
    }

    func profiles() throws -> [AuthProfile] {
        finalized || (prepared && !rolledBack) ? after : before
    }

    func prepareCodexCredentialMigrations() throws -> [AuthProfileMigration] {
        prepared = true
        return migrations
    }

    func finalizeCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) throws {
        if let finalizeError { throw finalizeError }
        finalizedMigrations = migrations
        finalized = true
    }

    func rollbackCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) {
        rolledBackMigrations = migrations
        rolledBack = true
    }

    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int { 0 }
    func delete(for type: AuthProfileType) throws -> Int { 0 }
}

private struct ThrowingAuthProfileStore: AuthProfileManaging {
    let error: Error

    func profiles() throws -> [AuthProfile] { throw error }
    func setDisabled(_: Bool, for _: AuthProfileType) throws -> Int { throw error }
    func delete(for _: AuthProfileType) throws -> Int { throw error }
}

private final class ReloadFailingAfterDisableAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: AuthProfile
    private var profileReloadsFail = false

    init(profile: AuthProfile) {
        self.profile = profile
    }

    func recoverProfileReloads() {
        lock.withLock { profileReloadsFail = false }
    }

    func profiles() throws -> [AuthProfile] {
        try lock.withLock {
            if profileReloadsFail {
                throw NSError(domain: "test", code: 1)
            }
            return [profile]
        }
    }

    func setDisabled(_ disabled: Bool, id: String) throws -> Bool {
        lock.withLock {
            guard profile.id == id else { return false }
            profile = AuthProfile(
                fileName: profile.fileName,
                type: profile.type,
                email: profile.email,
                accountID: profile.accountID,
                expired: profile.expired,
                disabled: disabled,
                prefix: profile.prefix
            )
            profileReloadsFail = disabled
            return true
        }
    }

    func setPrefix(_ prefix: String?, id: String) throws -> Bool {
        lock.withLock {
            guard profile.id == id else { return false }
            profile = AuthProfile(
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

    func setDisabled(_: Bool, for _: AuthProfileType) throws -> Int { 0 }
    func delete(for _: AuthProfileType) throws -> Int { 0 }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _profiles: [AuthProfile]
    private var _disabledUpdates: [DisabledUpdate] = []
    private var _disabledIDUpdates: [DisabledIDUpdate] = []
    private var _deletedIDs: [String] = []
    private var _deleteInvocations: [AuthProfileType] = []
    private var disabledIDUpdateWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
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
        let result = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard let index = _profiles.firstIndex(where: { $0.id == id }) else {
                return (false, [])
            }
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
            let ready = disabledIDUpdateWaiters
                .filter { _disabledIDUpdates.count >= $0.0 }
                .map(\.1)
            disabledIDUpdateWaiters.removeAll { _disabledIDUpdates.count >= $0.0 }
            return (true, ready)
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    func waitForDisabledIDUpdateCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if _disabledIDUpdates.count >= expectedCount { return true }
                disabledIDUpdateWaiters.append((expectedCount, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
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

private final class CancellableProxyHealthClientDouble: ProxyHealthChecking, @unchecked Sendable {
    private let gate = CancellableOperationGate()
    private let resumedStatus: DiagnosticStatus
    private let lock = NSLock()
    private var callCount = 0

    init(resumedStatus: DiagnosticStatus) {
        self.resumedStatus = resumedStatus
    }

    func status(port: Int) async -> DiagnosticStatus {
        let shouldSuspend = lock.withLock {
            callCount += 1
            return callCount == 1
        }
        if shouldSuspend {
            await gate.wait()
        }
        return resumedStatus
    }

    func waitUntilSuspended() async {
        await gate.waitUntilWaiting()
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

private final class BundledProxyReconcilerDouble: BundledProxyReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private let result: BundledProxyReconciliationResult?
    private let error: Error?
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }

    init(result: BundledProxyReconciliationResult) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func reconcile() throws -> BundledProxyReconciliationResult {
        lock.withLock { _callCount += 1 }
        if let error { throw error }
        return result!
    }
}

private actor ContinuationProxyService: ProxyServiceControlling {
    private struct RestartFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private var ports: [Int] = []
    private var restartPorts: [Int] = []
    private var stopCount = 0
    private var restartContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var restartWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func start(port: Int) async throws {
        ports.append(port)
    }

    func stop() async throws {
        stopCount += 1
    }

    func restart(port: Int) async throws {
        restartPorts.append(port)
        let invocation = restartPorts.count
        let readyWaiters = restartWaiters.filter { invocation >= $0.0 }.map(\.1)
        restartWaiters.removeAll { invocation >= $0.0 }
        readyWaiters.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { continuation in
            restartContinuations[invocation] = continuation
        }
    }

    func waitForRestart(_ invocation: Int) async {
        if restartPorts.count >= invocation { return }
        await withCheckedContinuation { continuation in
            restartWaiters.append((invocation, continuation))
        }
    }

    func resolveRestart(_ invocation: Int, errorMessage: String? = nil) {
        guard let continuation = restartContinuations.removeValue(forKey: invocation) else { return }
        if let errorMessage {
            continuation.resume(throwing: RestartFailure(message: errorMessage))
        } else {
            continuation.resume()
        }
    }

    func recordedRestartPorts() -> [Int] { restartPorts }
    func recordedStopCount() -> Int { stopCount }
}

private final class StubProxyServiceStarter: ProxyServiceControlling, @unchecked Sendable {
    private let error: Error?
    private let restartError: Error?
    private var restartErrors: [Error?]
    private let suspendedRestartCount: Int
    private let startDelayNanoseconds: UInt64
    private let stopDelayNanoseconds: UInt64
    private let reconcileResult: Bool
    private let reconcileError: Error?
    private let lock = NSLock()
    private var _ports: [Int] = []
    private var _restartPorts: [Int] = []
    private var _reconcilePorts: [Int] = []
    private var _stopCount = 0
    private var releasedRestarts: Set<Int> = []

    var ports: [Int] {
        lock.withLock { _ports }
    }

    var restartPorts: [Int] {
        lock.withLock { _restartPorts }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    var reconcilePorts: [Int] {
        lock.withLock { _reconcilePorts }
    }

    init(
        error: Error? = nil,
        restartError: Error? = nil,
        restartErrors: [Error?] = [],
        suspendedRestartCount: Int = 0,
        startDelayNanoseconds: UInt64 = 0,
        stopDelayNanoseconds: UInt64 = 0,
        reconcileResult: Bool = false,
        reconcileError: Error? = nil
    ) {
        self.error = error
        self.restartError = restartError
        self.restartErrors = restartErrors
        self.suspendedRestartCount = suspendedRestartCount
        self.startDelayNanoseconds = startDelayNanoseconds
        self.stopDelayNanoseconds = stopDelayNanoseconds
        self.reconcileResult = reconcileResult
        self.reconcileError = reconcileError
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

    func reachesRestartCount(_ expectedCount: Int, attempts: Int = 1_000) async -> Bool {
        for _ in 0..<attempts {
            if restartPorts.count >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return restartPorts.count >= expectedCount
    }

    func releaseRestart(_ invocation: Int) {
        _ = lock.withLock { releasedRestarts.insert(invocation) }
    }

    private func waitForRestartRelease(_ invocation: Int) async throws {
        for _ in 0..<1_000 {
            if lock.withLock({ releasedRestarts.contains(invocation) }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(
            domain: "StubProxyServiceStarter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Restart \(invocation) was not released by its test."]
        )
    }

    func reconcileConfiguration(port: Int) async throws -> Bool {
        lock.withLock { _reconcilePorts.append(port) }
        if let reconcileError { throw reconcileError }
        return reconcileResult
    }

    func restart(port: Int) async throws {
        let invocation = lock.withLock { () -> Int in
            _restartPorts.append(port)
            return _restartPorts.count
        }
        if invocation <= suspendedRestartCount {
            try await waitForRestartRelease(invocation)
        }
        let invocationError = lock.withLock { () -> Error? in
            guard !restartErrors.isEmpty else { return nil }
            return restartErrors.removeFirst()
        }
        if let invocationError {
            throw invocationError
        }
        if let restartError {
            throw restartError
        }
        if let error {
            throw error
        }
    }
}

import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class DashboardViewModelRefreshTests: XCTestCase {
    func testRefreshUpdatesClaudeAndCodexCardsByCommandAndExcludesClaudeAPICard() async {
        let config = AppConfig(
            port: 9444,
            commands: AppConfig.Commands(cc: "claude-local", ccapi: "api-local", ccodex: "codex-local"),
            ccapi: AppConfig.ClaudeAPI(model: "test-claude"),
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
            title: "CLIProxyAPI 실행 중",
            message: "포트 9444에서 모델 목록을 불러올 수 있습니다."
        )
        let claudeStatus = DiagnosticStatus(
            severity: .ready,
            title: "Claude Code 연결됨",
            message: "로그인되어 있습니다."
        )
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.serverStatus, serverStatus)
        XCTAssertEqual(viewModel.cards.first { $0.command == "claude-local" }?.status, claudeStatus)
        XCTAssertFalse(viewModel.cards.contains { $0.command == "api-local" })
        XCTAssertEqual(viewModel.cards.first { $0.command == "codex-local" }?.status, serverStatus)
    }

    func testDefaultProviderRowsHideProfilesUntilAuthExists() {
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows, [])
    }

    func testAddProviderExplainsClaudeAPIIsHiddenFromDefaultProfiles() {
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.addProvider()

        XCTAssertEqual(viewModel.settingsMessage, "Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다.")
    }

    func testSettingsMessageCanBeClearedByToastTimer() {
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.addProvider()
        viewModel.clearSettingsMessage()

        XCTAssertNil(viewModel.settingsMessage)
    }

    func testSettingsMessageAutoClearsAfterDelay() async throws {
        let viewModel = DashboardViewModel(
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
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows, [])
        XCTAssertFalse(viewModel.cards.contains { $0.command == "ccapi" })
    }

    func testProviderRowsUseConfiguredCommandOnlyForSavedAuthSettings() {
        var config = AppConfig.default
        config.commands.ccodex = "ccmcodex"
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: config),
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.functionName, "ccmcodex")
    }

    func testProviderRowsShowOAuthProfileEmailsFromAppManagedAuthStore() {
        let profiles = [
            AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: profiles),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionTitle, "연결됨")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.connectionDetail, "claude@example.com")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionTitle, "연결됨")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
    }

    func testConnectProviderStartsBundledOAuthLoginAndRefreshesProfiles() async {
        let authStore = StubAuthProfileStore(profiles: [])
        let oauth = StubOAuthLoginService()
        let viewModel = DashboardViewModel(
            authProfileStore: authStore,
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]

        await viewModel.connectProvider(.codex)

        XCTAssertEqual(oauth.invocations, [.codex])
        XCTAssertEqual(authStore.disabledUpdates.map(\.type), [.codex])
        XCTAssertEqual(authStore.disabledUpdates.map(\.disabled), [false])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionDetail, "codex@example.com")
        XCTAssertFalse(viewModel.isProfileLoginInProgress)
        XCTAssertNil(viewModel.activeOAuthLoginProvider)
        XCTAssertEqual(viewModel.completedOAuthLoginProvider, .codex)
    }

    func testConnectProviderDoesNotInstallShellFunctionsBeforeInitialSettingsAreSaved() async {
        let installer = StubShellInstaller(validationError: ShellProfileInstallerError.functionNameConflicts(["cc"]))
        let authStore = StubAuthProfileStore(profiles: [])
        let viewModel = DashboardViewModel(
            shellInstaller: installer,
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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

    func testCancelOAuthLoginCancelsActiveProviderLogin() async throws {
        let authStore = StubAuthProfileStore(profiles: [])
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ]
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            authProfileStore: authStore,
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth 로그인을 취소했습니다.")
    }

    func testDirectConnectProviderDoesNotReenterActiveOAuthLoginForSameProvider() async throws {
        let oauth = SuspendedOAuthLoginService()
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
            authProfileStore: StubAuthProfileStore(profiles: []),
            oauthLoginService: oauth,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.removeInitialProvider(.claude)

        XCTAssertEqual(authStore.deleteInvocations, [.claude])
        XCTAssertNil(viewModel.settingsMessage)
    }

    func testExpiredProviderRowIsErrored() {
        let viewModel = DashboardViewModel(
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: "2026-05-09T11:24:01+09:00", disabled: false)
            ]),
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        XCTAssertEqual(viewModel.providerRows.first { $0.id == .claude }?.isErrored, true)
    }

    func testDisconnectProviderDisablesAuthProfileAndRefreshesRows() {
        let authStore = StubAuthProfileStore(profiles: [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: false)
        ])
        authStore.nextProfiles = [
            AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: "acct_123", expired: nil, disabled: true)
        ]
        let viewModel = DashboardViewModel(
            authProfileStore: authStore,
            oauthLoginService: StubOAuthLoginService(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        viewModel.disconnectProvider(.codex)

        XCTAssertEqual(authStore.disabledUpdates.map(\.type), [.codex])
        XCTAssertEqual(authStore.disabledUpdates.map(\.disabled), [true])
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.connectionTitle, "연결 필요")
        XCTAssertEqual(viewModel.providerRows.first { $0.id == .codex }?.isConnected, false)
        XCTAssertEqual(viewModel.settingsMessage, "Codex OAuth 연결을 비활성화했습니다. auth 파일은 삭제하지 않았습니다.")
    }

    func testSavePortPersistsConfigAndRefreshesOptionRows() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
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
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        let didSave = viewModel.saveSetting { try viewModel.savePort(18_888) }

        XCTAssertFalse(didSave)
        XCTAssertEqual(viewModel.config.port, AppConfig.default.port)
        XCTAssertEqual(store.savedConfigs, [])
    }

    func testInstallShellFunctionsRendersAndInstallsCurrentConfig() throws {
        var config = AppConfig.default
        config.commands.ccodex = "customcodex"
        let store = StubConfigStore(config: config)
        let installer = StubShellInstaller()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false),
                AuthProfile(fileName: "codex.json", type: .codex, email: "codex@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.installShellFunctions(helperCommand: "/usr/local/bin/cliproxy-manager")

        XCTAssertEqual(installer.installedFunctionNames, ["cc", "customcodex"])
        XCTAssertTrue(installer.installedScript?.contains("customcodex() {") == true)
    }

    func testInstallShellFunctionsInstallsActiveProvidersOnly() throws {
        let installer = StubShellInstaller()
        let automaticInstaller = AutomaticShellInstallService(
            installer: installer,
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "sk-test"]),
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )
        let viewModel = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: installer,
            authProfileStore: StubAuthProfileStore(profiles: [
                AuthProfile(fileName: "claude.json", type: .claude, email: "claude@example.com", accountID: nil, expired: nil, disabled: false)
            ]),
            automaticShellInstallService: automaticInstaller,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        try viewModel.installShellFunctions(helperCommand: "/Applications/CLI Proxy/cliproxy-manager")

        XCTAssertEqual(installer.installedFunctionNames, ["cc"])
        XCTAssertTrue(installer.installedScript?.contains("cc() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccodex() {") == true)
        XCTAssertFalse(installer.installedScript?.contains("ccapi() {") == true)
    }

    func testLoadCodexModelsFetchesBaseModelsFromCurrentPort() async {
        let modelClient = StubProxyModelClient(models: ["gpt-5.5", "gpt-5.6"])
        let viewModel = DashboardViewModel(
            modelClient: modelClient,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        await viewModel.loadCodexModels()

        XCTAssertEqual(modelClient.ports, [18_317])
        XCTAssertEqual(viewModel.availableCodexModels, ["gpt-5.5", "gpt-5.6"])
    }

    func testLatestBaseCodexModelPrefersMainGptModelWithSuffix() async {
        let modelClient = StubProxyModelClient(models: ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo"])
        let viewModel = DashboardViewModel(
            modelClient: modelClient,
            proxyService: StubProxyServiceStarter(),
            claudeConnector: connectedClaudeConnector()
        )

        await viewModel.loadCodexModels()

        XCTAssertEqual(viewModel.latestBaseCodexModel, "gpt-4o")
    }

    func testSetServerEnabledStartsAndStopsServer() async {
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8))), timeout: 0.1),
            proxyService: proxyService,
            claudeConnector: connectedClaudeConnector(),
            serverStatusRetryDelayNanoseconds: 0
        )

        await viewModel.setServerEnabled(true)
        await viewModel.setServerEnabled(false)

        XCTAssertEqual(proxyService.ports, [18_317])
        XCTAssertEqual(proxyService.stopCount, 1)
    }

    func testServerToggleEntersStartingStateImmediately() async {
        let proxyService = StubProxyServiceStarter(startDelayNanoseconds: 50_000_000)
        let viewModel = DashboardViewModel(
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
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testStartServerRetriesStatusUntilServerBecomesReady() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
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
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.stopServer()

        XCTAssertEqual(proxyService.stopCount, 1)
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testRestartServerUsesInjectedProxyServiceAndRefreshesStatus() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        await viewModel.restartServer()

        XCTAssertEqual(proxyService.restartPorts, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .ready)
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .ready)
    }

    func testRestartServerRetriesStatusUntilServerBecomesReady() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let httpClient = SequencedHTTPClient(results: [
            .failure(URLError(.cannotConnectToHost)),
            .success(Data("{}".utf8))
        ])
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: httpClient),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
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
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter(error: ProxyServiceError.missingBinary("test"))
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: []))
        )

        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [config.port])
        XCTAssertEqual(viewModel.serverStatus.severity, .error)
        XCTAssertEqual(viewModel.serverStatus.title, "CLIProxyAPI 시작 실패")
        XCTAssertEqual(viewModel.cards.first { $0.command == config.commands.ccodex }?.status.severity, .error)
        XCTAssertFalse(viewModel.isServerActionInProgress)
    }

    func testLifecycleActionInProgressPreventsOverlappingActions() async {
        let config = AppConfig.default
        let proxyService = StubProxyServiceStarter()
        let viewModel = DashboardViewModel(
            config: config,
            proxyHealthClient: ProxyHealthClient(httpClient: StubHTTPClient(result: .success(Data("{}".utf8)))),
            proxyService: proxyService,
            claudeConnector: ClaudeConnector(runner: StubProcessRunner(results: [
                ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
                ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
            ]))
        )

        viewModel.isServerActionInProgress = true
        await viewModel.startServer()

        XCTAssertEqual(proxyService.ports, [])
        XCTAssertTrue(viewModel.isServerActionInProgress)
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
    private(set) var installedScript: String?
    private(set) var installedFunctionNames: [String] = []
    private(set) var validatedFunctionNames: [[String]] = []
    var installed = false

    init(validationError: Error? = nil) {
        self.validationError = validationError
    }

    func install(functionScript: String, functionNames: [String]) throws {
        installedScript = functionScript
        installedFunctionNames = functionNames
        installed = true
    }

    func isInstalled() -> Bool {
        installed
    }

    func validateFunctionNames(_ names: [String]) throws {
        validatedFunctionNames.append(names)
        if let validationError { throw validationError }
    }
}

private final class StubProxyModelClient: ProxyModelListing, @unchecked Sendable {
    private let models: [String]
    private let lock = NSLock()
    private var _ports: [Int] = []

    var ports: [Int] {
        lock.withLock { _ports }
    }

    init(models: [String]) {
        self.models = models
    }

    func baseModels(port: Int) async throws -> [String] {
        lock.withLock { _ports.append(port) }
        return models
    }
}

private final class StubAuthProfileStore: AuthProfileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _profiles: [AuthProfile]
    private var _disabledUpdates: [DisabledUpdate] = []
    private var _deleteInvocations: [AuthProfileType] = []
    var nextProfiles: [AuthProfile]?

    var disabledUpdates: [DisabledUpdate] {
        lock.withLock { _disabledUpdates }
    }

    var deleteInvocations: [AuthProfileType] {
        lock.withLock { _deleteInvocations }
    }

    init(profiles: [AuthProfile]) {
        self._profiles = profiles
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

    func delete(for type: AuthProfileType) throws -> Int {
        lock.withLock {
            _deleteInvocations.append(type)
            let count = _profiles.filter { $0.type == type }.count
            _profiles.removeAll { $0.type == type }
            return count
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

    var wasCancelled: Bool { lock.withLock { _wasCancelled } }
    var invocationCount: Int { lock.withLock { _invocationCount } }

    func login(provider: OAuthLoginProvider, port: Int) async throws {
        await markStarted()
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

    private func markStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            _invocationCount += 1
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

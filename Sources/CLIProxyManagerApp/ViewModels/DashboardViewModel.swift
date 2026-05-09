import Combine
import CLIProxyManagerCore

protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceControlling {}

protocol AppConfigStoring: Sendable {
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
}

extension AppConfigStore: AppConfigStoring {}

protocol ShellFunctionInstalling: Sendable {
    func install(functionScript: String, functionNames: [String]) throws
    func isInstalled() -> Bool
}

extension ShellProfileInstaller: ShellFunctionInstalling {}

protocol ProxyModelListing: Sendable {
    func baseModels(port: Int) async throws -> [String]
}

extension ProxyModelClient: ProxyModelListing {}

protocol AuthProfileManaging: Sendable {
    func profiles() throws -> [AuthProfile]
    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int
}

extension AuthProfileStore: AuthProfileManaging {}

protocol OAuthLoginStarting: Sendable {
    func login(provider: OAuthLoginProvider, port: Int) async throws
}

extension OAuthLoginService: OAuthLoginStarting {}

struct DashboardOptionRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let detail: String
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus
    @Published var isServerActionInProgress = false
    @Published var isProfileLoginInProgress = false
    @Published private(set) var config: AppConfig
    @Published var availableCodexModels: [String] = []
    @Published var settingsMessage: String?
    @Published var optionRows: [DashboardOptionRow] = []
    @Published var providerRows: [ProviderRowState] = []

    private let configStore: any AppConfigStoring
    private let shellInstaller: any ShellFunctionInstalling
    private let modelClient: any ProxyModelListing
    private let authProfileStore: any AuthProfileManaging
    private let oauthLoginService: any OAuthLoginStarting
    private let automaticShellInstallService: AutomaticShellInstallService
    private let proxyHealthClient: ProxyHealthClient
    private let proxyService: any ProxyServiceControlling
    private let claudeConnector: ClaudeConnector
    private let loginItemService: any LoginItemControlling
    private let appAppearanceService: any AppAppearanceApplying
    private let serverStatusRetryDelayNanoseconds: UInt64
    private var authProfiles: [AuthProfile] = []
    private var lastClaudeStatus: DiagnosticStatus?
    private var lastCodexStatus: DiagnosticStatus?

    init(
        config: AppConfig? = nil,
        configStore: any AppConfigStoring = AppConfigStore(),
        shellInstaller: any ShellFunctionInstalling = ShellProfileInstaller(paths: ManagedPaths()),
        modelClient: any ProxyModelListing = ProxyModelClient(),
        authProfileStore: any AuthProfileManaging = AuthProfileStore(),
        oauthLoginService: (any OAuthLoginStarting)? = nil,
        automaticShellInstallService: AutomaticShellInstallService? = nil,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        claudeConnector: ClaudeConnector = ClaudeConnector(),
        loginItemService: any LoginItemControlling = LoginItemService(),
        appAppearanceService: any AppAppearanceApplying = AppAppearanceService(),
        serverStatusRetryDelayNanoseconds: UInt64 = 300_000_000
    ) {
        self.configStore = configStore
        self.shellInstaller = shellInstaller
        self.modelClient = modelClient
        self.authProfileStore = authProfileStore
        let defaultRuntimePreparer = ProxyServiceManager(paths: ManagedPaths(), bundledBinaryURL: BundledProxyBinary.url())
        self.oauthLoginService = oauthLoginService ?? OAuthLoginService(runtimePreparer: defaultRuntimePreparer)
        self.automaticShellInstallService = automaticShellInstallService ?? AutomaticShellInstallService(installer: shellInstaller)
        self.proxyHealthClient = proxyHealthClient
        self.proxyService = proxyService
        self.claudeConnector = claudeConnector
        self.loginItemService = loginItemService
        self.appAppearanceService = appAppearanceService
        self.serverStatusRetryDelayNanoseconds = serverStatusRetryDelayNanoseconds
        let initialConfig = config ?? ((try? configStore.load()) ?? .default)
        self.config = initialConfig
        cards = ProfileCard.makeDefaultCards(config: initialConfig)
        serverStatus = DiagnosticStatus(
            severity: .warning,
            title: "확인 필요",
            message: "서버 상태 확인 전입니다."
        )
        self.authProfiles = (try? authProfileStore.profiles()) ?? []
        rebuildOptionRows()
        rebuildProviderRows(claudeStatus: nil, codexStatus: nil)
        appAppearanceService.apply(showDockIcon: initialConfig.showDockIcon)
        applyInitialShellInstall()
    }

    func refresh() async {
        let updatedServerStatus = await proxyHealthClient.status(port: config.port)
        let claudeStatus = await claudeConnector.status()
        updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
    }

    func startServer() async {
        await performServerAction(title: "CLIProxyAPI 시작 실패", waitForReady: true) {
            try await proxyService.start(port: config.port)
        }
    }

    func stopServer() async {
        await performServerAction(title: "CLIProxyAPI 중지 실패") {
            try await proxyService.stop()
        }
    }

    func restartServer() async {
        await performServerAction(title: "CLIProxyAPI 재시작 실패", waitForReady: true) {
            try await proxyService.restart(port: config.port)
        }
    }

    func setServerEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            await startServer()
        } else {
            await stopServer()
        }
    }

    func refreshProfiles() {
        authProfiles = (try? authProfileStore.profiles()) ?? []
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
    }

    func connectProvider(_ provider: ProviderRowState.ID) async {
        guard isProfileLoginInProgress == false else { return }
        isProfileLoginInProgress = true
        defer { isProfileLoginInProgress = false }

        let loginProvider: OAuthLoginProvider
        let providerName: String
        switch provider {
        case .claude:
            loginProvider = .claude
            providerName = "Claude OAuth"
        case .codex:
            loginProvider = .codex
            providerName = "Codex OAuth"
        }

        do {
            try await oauthLoginService.login(provider: loginProvider, port: config.port)
            _ = try authProfileStore.setDisabled(false, for: loginProvider.authProfileType)
            refreshProfiles()
            settingsMessage = "\(providerName) 연결 정보를 업데이트했습니다."
        } catch {
            settingsMessage = "\(providerName) 로그인에 실패했습니다: \(error.localizedDescription)"
            refreshProfiles()
        }
    }

    func disconnectProvider(_ provider: ProviderRowState.ID) {
        let profileType: AuthProfileType
        let providerName: String
        switch provider {
        case .claude:
            profileType = .claude
            providerName = "Claude OAuth"
        case .codex:
            profileType = .codex
            providerName = "Codex OAuth"
        }

        do {
            let disabledCount = try authProfileStore.setDisabled(true, for: profileType)
            refreshProfiles()
            if disabledCount == 0 {
                settingsMessage = "비활성화할 \(providerName) auth 파일을 찾지 못했습니다."
            } else {
                settingsMessage = "\(providerName) 연결을 비활성화했습니다. auth 파일은 삭제하지 않았습니다."
            }
        } catch {
            refreshProfiles()
            settingsMessage = "\(providerName) 연결 비활성화에 실패했습니다: \(error.localizedDescription)"
        }
    }

    func addProvider() {
        settingsMessage = "Claude API profile 추가는 이번 단계의 기본 목록에서 숨겨져 있습니다."
    }

    func saveClaudeFunctionName(_ functionName: String) throws {
        var commands = config.commands
        commands.cc = functionName
        try saveCommands(commands)
    }

    func saveClaudeOAuthSettings(functionName: String, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.commands.cc = functionName
        updatedConfig.includeDangerouslySkipPermissions = dangerousPermissionsEnabled
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func saveClaudeAPISettings(functionName: String, model: String) throws {
        var updatedConfig = config
        updatedConfig.commands.ccapi = functionName
        updatedConfig.ccapi = AppConfig.ClaudeAPI(model: model)
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func saveCodexSettings(functionName: String, codex: AppConfig.Codex) throws {
        var updatedConfig = config
        updatedConfig.commands.ccodex = functionName
        updatedConfig.ccodex = codex
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func saveCodexSettings(functionName: String, codex: AppConfig.Codex, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.commands.ccodex = functionName
        updatedConfig.ccodex = codex
        updatedConfig.includeDangerouslySkipPermissions = dangerousPermissionsEnabled
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func savePort(_ port: Int) throws {
        guard (1...65_535).contains(port) else { throw ShellFunctionRendererError.invalidPort(port) }
        var updatedConfig = config
        updatedConfig.port = port
        try saveConfig(updatedConfig)
    }

    func saveCommands(_ commands: AppConfig.Commands) throws {
        var updatedConfig = config
        updatedConfig.commands = commands
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func saveModels(ccapi: AppConfig.ClaudeAPI, ccodex: AppConfig.Codex) throws {
        var updatedConfig = config
        updatedConfig.ccapi = ccapi
        updatedConfig.ccodex = ccodex
        try saveConfig(updatedConfig)
    }

    func saveDangerousPermissionsEnabled(_ isEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.includeDangerouslySkipPermissions = isEnabled
        try saveConfig(updatedConfig)
    }

    func saveStartAtLogin(_ isEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.startAtLogin = isEnabled
        try loginItemService.setStartAtLoginEnabled(isEnabled)
        try saveConfig(updatedConfig)
    }

    func saveDockIconVisible(_ isVisible: Bool) throws {
        guard isVisible || config.showMenuBarIcon else {
            settingsMessage = "Dock 아이콘과 메뉴바 아이콘 중 하나는 켜져 있어야 합니다."
            return
        }
        var updatedConfig = config
        updatedConfig.showDockIcon = isVisible
        try saveConfig(updatedConfig)
        appAppearanceService.apply(showDockIcon: isVisible)
    }

    func saveMenuBarIconVisible(_ isVisible: Bool) throws {
        guard isVisible || config.showDockIcon else {
            settingsMessage = "Dock 아이콘과 메뉴바 아이콘 중 하나는 켜져 있어야 합니다."
            return
        }
        var updatedConfig = config
        updatedConfig.showMenuBarIcon = isVisible
        try saveConfig(updatedConfig)
    }

    func installShellFunctions(helperCommand: String = "/usr/local/bin/cliproxy-manager") throws {
        let script = try ShellFunctionRenderer(config: config, helperCommand: helperCommand).render()
        try shellInstaller.install(
            functionScript: script,
            functionNames: [config.commands.cc, config.commands.ccapi, config.commands.ccodex]
        )
        settingsMessage = "설치가 완료되었습니다. 새 터미널을 열거나 source ~/.zshrc를 실행하세요."
        rebuildOptionRows()
    }

    func saveSetting(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            settingsMessage = error.localizedDescription
        }
    }

    func loadCodexModels() async {
        do {
            availableCodexModels = try await modelClient.baseModels(port: config.port)
        } catch {
            availableCodexModels = []
            settingsMessage = "모델 목록을 불러오지 못했습니다. 직접 입력할 수 있습니다."
        }
    }

    private func saveConfig(_ updatedConfig: AppConfig, validateShellFunctions: Bool = false) throws {
        if validateShellFunctions {
            _ = try ShellFunctionRenderer(config: updatedConfig, helperCommand: "/usr/bin/true").render()
        }
        try automaticShellInstallService.apply(config: updatedConfig)
        try configStore.save(updatedConfig)
        config = updatedConfig
        cards = ProfileCard.makeDefaultCards(config: updatedConfig)
        rebuildOptionRows()
        rebuildProviderRows(claudeStatus: nil, codexStatus: nil)
    }

    private func applyInitialShellInstall() {
        do {
            try automaticShellInstallService.apply(config: config)
        } catch {
            settingsMessage = "shell functions 자동 설치에 실패했습니다: \(error.localizedDescription)"
        }
    }

    private func rebuildProviderRows(claudeStatus: DiagnosticStatus?, codexStatus: DiagnosticStatus?) {
        let claudeProfile = authProfiles.first { $0.type == .claude && $0.disabled == false }
        let codexProfile = authProfiles.first { $0.type == .codex && $0.disabled == false }

        providerRows = [
            ProviderRowState(
                id: .claude,
                name: "Claude OAuth",
                functionName: config.commands.cc,
                connectionTitle: claudeProfile == nil ? "연결 필요" : "연결됨",
                connectionDetail: profileDetail(
                    profile: claudeProfile,
                    fallback: claudeStatus?.message ?? "번들 CLIProxyAPI의 Claude OAuth profile을 연결하세요."
                ),
                isConnected: claudeProfile != nil
            ),
            ProviderRowState(
                id: .codex,
                name: "Codex OAuth",
                functionName: config.commands.ccodex,
                connectionTitle: codexProfile == nil ? "연결 필요" : "연결됨",
                connectionDetail: profileDetail(
                    profile: codexProfile,
                    fallback: codexStatus?.message ?? "번들 CLIProxyAPI의 Codex OAuth profile을 연결하세요."
                ),
                isConnected: codexProfile != nil
            )
        ]
    }

    private func rebuildOptionRows() {
        optionRows = [
            DashboardOptionRow(id: "port", title: "Port", value: "\(config.port)", detail: "App-managed CLIProxyAPI server"),
            DashboardOptionRow(id: "functions", title: "Shell Functions", value: "\(config.commands.cc) / \(config.commands.ccapi) / \(config.commands.ccodex)", detail: "Terminal commands"),
            DashboardOptionRow(id: "models", title: "Models", value: "Claude + Codex mappings", detail: "Model, reasoning, context window"),
            DashboardOptionRow(id: "permissions", title: "Permissions", value: config.includeDangerouslySkipPermissions ? "Dangerous skip enabled" : "Safe mode", detail: "Claude Code permission behavior"),
            DashboardOptionRow(id: "install", title: "Shell Install", value: shellInstaller.isInstalled() ? "Installed" : "Not installed", detail: "Managed .zshrc source block")
        ]
    }

    private func performServerAction(title: String, waitForReady: Bool = false, action: () async throws -> Void) async {
        guard isServerActionInProgress == false else { return }

        isServerActionInProgress = true
        defer { isServerActionInProgress = false }

        do {
            try await action()
            if waitForReady {
                await refreshUntilServerIsReady()
            } else {
                await refresh()
            }
        } catch {
            updateStatuses(
                serverStatus: DiagnosticStatus(
                    severity: .error,
                    title: title,
                    message: error.localizedDescription
                ),
                claudeStatus: nil
            )
        }
    }

    private func refreshUntilServerIsReady() async {
        let claudeStatus = await claudeConnector.status()
        for attempt in 0..<5 {
            let updatedServerStatus = await proxyHealthClient.status(port: config.port)
            updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
            guard updatedServerStatus.severity != .ready else { return }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: serverStatusRetryDelayNanoseconds)
            }
        }
    }

    private func updateStatuses(serverStatus updatedServerStatus: DiagnosticStatus, claudeStatus: DiagnosticStatus?) {
        serverStatus = updatedServerStatus
        lastCodexStatus = updatedServerStatus
        if let claudeStatus {
            lastClaudeStatus = claudeStatus
        }
        refreshProfiles()

        cards = cards.map { card in
            switch card.command {
            case config.commands.cc:
                if let claudeStatus {
                    card.updatingStatus(claudeStatus)
                } else {
                    card
                }
            case config.commands.ccodex:
                card.updatingStatus(updatedServerStatus)
            default:
                card
            }
        }
    }

    private func profileDetail(profile: AuthProfile?, fallback: String) -> String {
        if let email = profile?.email {
            return email
        }
        if let accountID = profile?.accountID {
            return accountID
        }
        return fallback
    }
}

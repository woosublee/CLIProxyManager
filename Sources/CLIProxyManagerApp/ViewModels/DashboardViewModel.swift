import Combine
import CLIProxyManagerCore
import Foundation
#if canImport(AppKit)
import AppKit
#endif

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
    func delete(for type: AuthProfileType) throws -> Int
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
    @Published var serverControlState: ServerControlState = .stopped
    @Published var isServerActionInProgress = false
    @Published var isProfileLoginInProgress = false
    @Published private(set) var config: AppConfig
    @Published var availableCodexModels: [String] = []

    /// Picks the most recent "main" GPT model (e.g. `gpt-5.5`) — excluding `-mini`,
    /// `-codex`, `-codex-spark`, `auto-review`, etc. Returns nil if none match.
    var latestBaseCodexModel: String? {
        let mainPattern = #"^gpt-\d+(\.\d+)?$"#
        return availableCodexModels.first {
            $0.range(of: mainPattern, options: .regularExpression) != nil
        } ?? availableCodexModels.first
    }
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
        serverStatusRetryDelayNanoseconds: UInt64 = 500_000_000
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
        appAppearanceService.apply(appearance: initialConfig.appearance)
        applyInitialShellInstall()
    }

    func saveAppearance(_ mode: AppearanceMode) throws {
        var updatedConfig = config
        updatedConfig.appearance = mode
        try saveConfig(updatedConfig)
        appAppearanceService.apply(appearance: mode)
    }

    func saveMenuBarOnly(_ menuBarOnly: Bool) throws {
        var updatedConfig = config
        updatedConfig.showDockIcon = !menuBarOnly
        // The menu bar icon is the only entry point in menu-bar-only mode, so keep it on.
        if menuBarOnly { updatedConfig.showMenuBarIcon = true }
        try saveConfig(updatedConfig)
        appAppearanceService.apply(showDockIcon: updatedConfig.showDockIcon)
    }

    func saveShowNotifications(_ enabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.showNotifications = enabled
        try saveConfig(updatedConfig)
    }

    func saveBindAddress(_ address: String) throws {
        var updatedConfig = config
        updatedConfig.bindAddress = address
        try saveConfig(updatedConfig)
    }

    func saveAutostartServer(_ enabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.autostartServer = enabled
        try saveConfig(updatedConfig)
    }

    func saveRoundRobinEnabled(_ enabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.roundRobinEnabled = enabled
        try saveConfig(updatedConfig)
    }

    func saveLogLevel(_ level: LogLevel) throws {
        var updatedConfig = config
        updatedConfig.logLevel = level
        try saveConfig(updatedConfig)
    }

    func revealLogsInFinder() {
        #if canImport(AppKit)
        let url = ManagedPaths().logsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        #endif
    }

    func resetAllSettings() {
        // Preserve user-managed accounts (auth profiles in ~/.cliproxy-manager/auth) and the
        // commands/nicknames the user typed; only reset the *preferences* the design Reset
        // button targets: appearance, behavior, server config, log level.
        var updatedConfig = AppConfig.default
        updatedConfig.commands = config.commands
        updatedConfig.ccapi = config.ccapi
        updatedConfig.ccodex = config.ccodex
        updatedConfig.nicknames = config.nicknames
        updatedConfig.includeDangerouslySkipPermissions = config.includeDangerouslySkipPermissions
        do {
            try saveConfig(updatedConfig)
            appAppearanceService.apply(showDockIcon: updatedConfig.showDockIcon)
            appAppearanceService.apply(appearance: updatedConfig.appearance)
            settingsMessage = "Settings reset to defaults."
        } catch {
            settingsMessage = "Reset failed: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        let updatedServerStatus = await proxyHealthClient.status(port: config.port)
        let claudeStatus = await claudeConnector.status()
        updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
    }

    /// Called once on app launch. Auto-starts the server if the user opted in.
    func performAutostartIfEnabled() async {
        guard config.autostartServer, !serverControlState.isRunning else { return }
        await setServerEnabled(true)
    }

    func startServer() async {
        await performServerAction(
            title: "CLIProxyAPI 시작 실패",
            transitionState: .starting,
            waitForReady: true
        ) {
            try await proxyService.start(port: config.port)
        }
    }

    func stopServer() async {
        await performServerAction(title: "CLIProxyAPI 중지 실패", transitionState: .stopping) {
            try await proxyService.stop()
        }
    }

    func restartServer() async {
        await performServerAction(
            title: "CLIProxyAPI 재시작 실패",
            transitionState: .starting,
            waitForReady: true
        ) {
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

    func removeProvider(_ provider: ProviderRowState.ID) {
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
            let deletedCount = try authProfileStore.delete(for: profileType)
            refreshProfiles()
            if deletedCount == 0 {
                settingsMessage = "삭제할 \(providerName) auth 파일을 찾지 못했습니다."
            } else {
                settingsMessage = "\(providerName) 계정을 제거했습니다."
            }
        } catch {
            refreshProfiles()
            settingsMessage = "\(providerName) 계정 제거에 실패했습니다: \(error.localizedDescription)"
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

    func saveClaudeOAuthSettings(functionName: String, nickname: String, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.commands.cc = functionName
        updatedConfig.nicknames.cc = nickname
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

    func saveCodexSettings(functionName: String, nickname: String, codex: AppConfig.Codex, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        updatedConfig.commands.ccodex = functionName
        updatedConfig.nicknames.ccodex = nickname
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
        try saveConfig(updatedConfig)
        try loginItemService.setStartAtLoginEnabled(isEnabled)
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
        try automaticShellInstallService.apply(config: config)
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
        let claudeAny = authProfiles.first { $0.type == .claude }
        let codexAny = authProfiles.first { $0.type == .codex }
        let claudeEnabled = claudeAny.flatMap { $0.disabled ? nil : $0 }
        let codexEnabled = codexAny.flatMap { $0.disabled ? nil : $0 }

        var rows: [ProviderRowState] = []
        if claudeAny != nil {
            rows.append(
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: config.nicknames.cc,
                    functionName: config.commands.cc,
                    connectionTitle: claudeEnabled == nil ? "연결 필요" : "연결됨",
                    connectionDetail: profileDetail(
                        profile: claudeEnabled ?? claudeAny,
                        fallback: claudeStatus?.message ?? "번들 CLIProxyAPI의 Claude OAuth profile을 연결하세요."
                    ),
                    isConnected: claudeEnabled != nil
                )
            )
        }
        if codexAny != nil {
            rows.append(
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: config.nicknames.ccodex,
                    functionName: config.commands.ccodex,
                    connectionTitle: codexEnabled == nil ? "연결 필요" : "연결됨",
                    connectionDetail: profileDetail(
                        profile: codexEnabled ?? codexAny,
                        fallback: codexStatus?.message ?? "번들 CLIProxyAPI의 Codex OAuth profile을 연결하세요."
                    ),
                    isConnected: codexEnabled != nil
                )
            )
        }
        providerRows = rows
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

    private func performServerAction(
        title: String,
        transitionState: ServerControlState,
        waitForReady: Bool = false,
        action: () async throws -> Void
    ) async {
        guard isServerActionInProgress == false else { return }

        isServerActionInProgress = true
        serverControlState = transitionState
        defer { isServerActionInProgress = false }

        do {
            try await action()
            if waitForReady {
                await refreshUntilServerIsReady()
            } else {
                await refresh()
            }
            // After action completes, derive final state from the latest health.
            serverControlState = serverStatus.severity == .ready ? .running : .stopped
        } catch {
            let message = error.localizedDescription
            updateStatuses(
                serverStatus: DiagnosticStatus(
                    severity: .error,
                    title: title,
                    message: message
                ),
                claudeStatus: nil
            )
            serverControlState = .error(message)
        }
    }

    private func refreshUntilServerIsReady() async {
        let claudeStatus = await claudeConnector.status()
        // Up to ~12 seconds: child process launch latency + CFNetwork loopback warm-up
        // can take several seconds on macOS Sequoia/Tahoe even after the binary binds.
        let maxAttempts = 24
        for attempt in 0..<maxAttempts {
            let updatedServerStatus = await proxyHealthClient.status(port: config.port)
            // While the server is still warming up, keep the visible status as "Working…"
            // (severity .warning) instead of flashing red. Only commit a non-error severity
            // (or a final attempt's result) to the UI.
            if updatedServerStatus.severity == .ready
                || updatedServerStatus.severity == .warning
                || attempt == maxAttempts - 1 {
                updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
            }
            guard updatedServerStatus.severity != .ready else { return }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: serverStatusRetryDelayNanoseconds)
            }
        }
    }

    private func updateStatuses(serverStatus updatedServerStatus: DiagnosticStatus, claudeStatus: DiagnosticStatus?) {
        serverStatus = updatedServerStatus
        // Mirror the diagnostic into the explicit control state, but never overwrite a
        // transient transition (.starting / .stopping) — that's owned by performServerAction.
        if !serverControlState.isTransitioning {
            switch updatedServerStatus.severity {
            case .ready:
                serverControlState = .running
            case .warning:
                serverControlState = .stopped
            case .error:
                serverControlState = .error(updatedServerStatus.message)
            }
        }
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

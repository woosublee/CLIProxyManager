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
    func validateFunctionNames(_ names: [String]) throws
}

extension ShellProfileInstaller: ShellFunctionInstalling {}

protocol ProxyModelListing: Sendable {
    func baseModels(port: Int) async throws -> [String]
    func codexBaseModels(port: Int) async throws -> [String]
    func codexBaseModels(port: Int, modelPrefix: String) async throws -> [String]
}

extension ProxyModelListing {
    func codexBaseModels(port: Int, modelPrefix: String) async throws -> [String] {
        try await codexBaseModels(port: port)
    }
}

extension ProxyModelClient: ProxyModelListing {}

protocol AuthProfileManaging: Sendable {
    func profiles() throws -> [AuthProfile]
    func setDisabled(_ disabled: Bool, id: String) throws -> Bool
    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int
    func setPrefix(_ prefix: String?, id: String) throws -> Bool
    func delete(id: String) throws -> Bool
    func delete(for type: AuthProfileType) throws -> Int
}

extension AuthProfileManaging {
    func setDisabled(_ disabled: Bool, id: String) throws -> Bool { false }
    func setPrefix(_ prefix: String?, id: String) throws -> Bool { false }
    func delete(id: String) throws -> Bool { false }
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

enum CommandNameAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

enum CodexModelLoadingState: Equatable, Sendable {
    case idle
    case startingServer
    case loadingModels
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            nil
        case .startingServer:
            "Starting the local proxy server to load Codex models."
        case .loadingModels:
            "Loading Codex models."
        case .failed(let message):
            message
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    var isLoading: Bool {
        switch self {
        case .startingServer, .loadingModels:
            true
        case .idle, .failed:
            false
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus
    @Published var serverControlState: ServerControlState = .stopped
    @Published var isServerActionInProgress = false
    @Published var isProfileLoginInProgress = false
    @Published private(set) var activeOAuthLoginProvider: ProviderRowState.ID?
    @Published private(set) var completedOAuthLoginProvider: ProviderRowState.ID?
    @Published private(set) var completedOAuthLoginIsInitialSetup = true
    @Published private(set) var config: AppConfig
    @Published var availableCodexModels: [String] = []
    @Published private(set) var codexModelLoadingState: CodexModelLoadingState = .idle

    var latestBaseCodexModel: String? {
        let excludedKeywords = ["mini", "preview", "codex", "spark", "review"]
        return availableCodexModels.first { model in
            let lowercasedModel = model.lowercased()
            return lowercasedModel.hasPrefix("gpt-") && !excludedKeywords.contains { lowercasedModel.contains($0) }
        } ?? availableCodexModels.first
    }
    @Published var settingsMessage: String? {
        didSet { scheduleSettingsMessageAutoClear() }
    }
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
    private let settingsMessageAutoClearDelayNanoseconds: UInt64
    private var authProfiles: [AuthProfile] = []
    private var oauthLoginTask: Task<Void, Never>?
    private var oauthLoginSessionID: UUID?
    private var settingsMessageAutoClearTask: Task<Void, Never>?
    private var lastClaudeStatus: DiagnosticStatus?
    private var lastCodexStatus: DiagnosticStatus?
    private var lastPersistedConfig: AppConfig

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
        serverStatusRetryDelayNanoseconds: UInt64 = 500_000_000,
        settingsMessageAutoClearDelayNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.configStore = configStore
        self.shellInstaller = shellInstaller
        self.modelClient = modelClient
        self.authProfileStore = authProfileStore
        let defaultRuntimePreparer = ProxyServiceManager(paths: ManagedPaths(), bundledBinaryURL: BundledProxyBinary.url(), bundledManifestURL: BundledProxyBinary.manifestURL())
        self.oauthLoginService = oauthLoginService ?? OAuthLoginService(runtimePreparer: defaultRuntimePreparer)
        self.automaticShellInstallService = automaticShellInstallService ?? AutomaticShellInstallService.runtimeDefault(installer: shellInstaller)
        self.proxyHealthClient = proxyHealthClient
        self.proxyService = proxyService
        self.claudeConnector = claudeConnector
        self.loginItemService = loginItemService
        self.appAppearanceService = appAppearanceService
        self.serverStatusRetryDelayNanoseconds = serverStatusRetryDelayNanoseconds
        self.settingsMessageAutoClearDelayNanoseconds = settingsMessageAutoClearDelayNanoseconds
        let persistedConfig = Self.availableConfig(config ?? ((try? configStore.load()) ?? .default))
        var initialConfig = persistedConfig
        self.authProfiles = (try? authProfileStore.profiles()) ?? []
        initialConfig = Self.reconciledOAuthCommandProfiles(in: initialConfig, authProfiles: self.authProfiles)
        self.lastPersistedConfig = persistedConfig
        self.config = initialConfig
        cards = ProfileCard.makeDefaultCards(config: initialConfig)
        serverStatus = DiagnosticStatus(
            severity: .warning,
            title: "Needs check",
            message: "Server status has not been checked yet."
        )
        reconcileAuthProfilePrefixes()
        refreshProfiles()
        rebuildOptionRows()
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
        updatedConfig.showNotifications = false
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
        updatedConfig.roundRobinEnabled = false
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
        let rawServerStatus = await stableServerStatus()
        let updatedServerStatus = passiveRefreshPresentationStatus(from: rawServerStatus)
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
            title: "Failed to start CLIProxyAPI",
            transitionState: .starting,
            waitForReady: true
        ) {
            try await proxyService.start(port: config.port)
        }
    }

    func stopServer() async {
        await performServerAction(title: "Failed to stop CLIProxyAPI", transitionState: .stopping) {
            try await proxyService.stop()
        }
    }

    func restartServer() async {
        await performServerAction(
            title: "Failed to restart CLIProxyAPI",
            transitionState: .starting,
            waitForReady: true
        ) {
            try await proxyService.restart(port: config.port)
        }
    }

    func applyCLIProxyAPIPendingUpdate(using service: CLIProxyAPIUpdateService) async {
        do {
            try service.applyPendingNow()
            if serverControlState.isRunning {
                await restartServer()
            }
            settingsMessage = "CLIProxyAPI binary updated. Restarting the app is not required."
        } catch {
            settingsMessage = "CLIProxyAPI update failed: \(error.localizedDescription)"
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
        reconcileConfigWithAuthProfiles()
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
    }

    func clearSettingsMessage() {
        settingsMessageAutoClearTask?.cancel()
        settingsMessageAutoClearTask = nil
        settingsMessage = nil
    }

    func startOAuthLogin(_ provider: ProviderRowState.ID) {
        startOAuthLogin(providerType: oauthProviderType(for: provider))
    }

    func startOAuthLogin(providerType: AuthProfileType) {
        guard oauthLoginTask == nil else { return }
        let sessionID = UUID()
        let provider = providerID(for: providerType)
        oauthLoginSessionID = sessionID
        completedOAuthLoginProvider = nil
        completedOAuthLoginIsInitialSetup = true
        activeOAuthLoginProvider = provider
        isProfileLoginInProgress = true
        let isInitialSetup = isInitialOAuthSetup(for: providerType)
        oauthLoginTask = Task { [weak self] in
            await self?.runOAuthLogin(providerType, sessionID: sessionID, isInitialSetup: isInitialSetup)
        }
    }

    func cancelOAuthLogin() {
        let cancelledProvider = activeOAuthLoginProvider
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
        oauthLoginSessionID = nil
        activeOAuthLoginProvider = nil
        completedOAuthLoginProvider = nil
        completedOAuthLoginIsInitialSetup = true
        isProfileLoginInProgress = false

        if let cancelledProvider {
            settingsMessage = "\(oauthProviderName(cancelledProvider)) login was cancelled."
            refreshProfiles()
        }
    }

    func connectProvider(_ provider: ProviderRowState.ID) async {
        guard oauthLoginTask == nil, isProfileLoginInProgress == false else { return }
        let providerType = oauthProviderType(for: provider)
        let sessionID = UUID()
        oauthLoginSessionID = sessionID
        completedOAuthLoginProvider = nil
        completedOAuthLoginIsInitialSetup = true
        activeOAuthLoginProvider = providerID(for: providerType)
        isProfileLoginInProgress = true
        await runOAuthLogin(providerType, sessionID: sessionID, isInitialSetup: isInitialOAuthSetup(for: providerType))
    }

    private func oauthProviderType(for provider: ProviderRowState.ID) -> AuthProfileType {
        if let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }) {
            return commandProfile.provider
        }
        if let providerRow = providerRows.first(where: { $0.id == provider }) {
            return providerRow.providerType
        }
        return provider.inferredProviderType
    }

    private func providerID(for providerType: AuthProfileType) -> ProviderRowState.ID {
        providerType == .codex ? .codex : .claude
    }

    private func oauthProviderName(_ provider: ProviderRowState.ID) -> String {
        oauthProviderName(oauthProviderType(for: provider))
    }

    private func oauthProviderName(_ providerType: AuthProfileType) -> String {
        switch providerType {
        case .claude:
            "Claude OAuth"
        case .codex:
            "Codex OAuth"
        }
    }

    private func isInitialOAuthSetup(for provider: ProviderRowState.ID) -> Bool {
        isInitialOAuthSetup(for: oauthProviderType(for: provider))
    }

    private func isInitialOAuthSetup(for providerType: AuthProfileType) -> Bool {
        !authProfiles.contains { $0.type == providerType }
    }

    private func runOAuthLogin(_ providerType: AuthProfileType, sessionID: UUID, isInitialSetup: Bool) async {
        defer {
            if oauthLoginSessionID == sessionID {
                isProfileLoginInProgress = false
                activeOAuthLoginProvider = nil
                oauthLoginTask = nil
                oauthLoginSessionID = nil
            }
        }

        let beforeProfiles = authProfiles
        let loginProvider: OAuthLoginProvider = providerType == .codex ? .codex : .claude
        let providerName = oauthProviderName(providerType)

        do {
            try await oauthLoginService.login(provider: loginProvider, port: config.port)
            try Task.checkCancellation()
            guard oauthLoginSessionID == sessionID else { return }
            authProfiles = (try? authProfileStore.profiles()) ?? []
            let completedID = reconcileOAuthLoginCompletion(providerType: providerType, beforeProfiles: beforeProfiles)
            refreshProfiles()
            completedOAuthLoginProvider = completedID
            completedOAuthLoginIsInitialSetup = isInitialSetup
            settingsMessage = "\(providerName) connection was updated."
        } catch is CancellationError {
            guard oauthLoginSessionID == sessionID else { return }
            settingsMessage = "\(providerName) login was cancelled."
            refreshProfiles()
        } catch {
            guard oauthLoginSessionID == sessionID else { return }
            settingsMessage = "\(providerName) login failed: \(error.localizedDescription)"
            refreshProfiles()
        }
    }

    private func reconcileOAuthLoginCompletion(providerType: AuthProfileType, beforeProfiles: [AuthProfile]) -> ProviderRowState.ID {
        let beforeIDs = Set(beforeProfiles.map(\.id))
        let candidates = authProfiles.filter { $0.type == providerType }
        let selectedProfile = candidates.first(where: { !beforeIDs.contains($0.id) }) ?? candidates.first
        guard let selectedProfile else { return providerID(for: providerType) }

        var updatedConfig = Self.reconciledOAuthCommandProfiles(in: config, authProfiles: authProfiles)
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.authProfileID == selectedProfile.id }) {
            updatedConfig.oauthCommandProfiles[index].isEnabled = true
        }
        enableAuthProfile(selectedProfile)
        let finalConfig = Self.mirroredLegacyFields(in: updatedConfig)
        let completedID = finalConfig.oauthCommandProfiles.first(where: { $0.authProfileID == selectedProfile.id })?.id ?? selectedProfile.type.rawValue
        try? saveConfig(finalConfig)
        return ProviderRowState.ID(rawValue: completedID)
    }

    private func authProfileID(for provider: ProviderRowState.ID) -> String? {
        if let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }) {
            return commandProfile.authProfileID
        }
        let providerType = oauthProviderType(for: provider)
        return authProfiles.first(where: { $0.type == providerType })?.id
    }

    private func allowsLegacyProviderWideAuthFallback(for provider: ProviderRowState.ID) -> Bool {
        let providerType = oauthProviderType(for: provider)
        return lastPersistedConfig.oauthCommandProfiles.isEmpty
            && provider == providerID(for: providerType)
            && authProfiles.filter { $0.type == providerType }.count <= 1
    }

    private func enableAuthProfile(_ profile: AuthProfile) {
        if (try? authProfileStore.setDisabled(false, id: profile.id)) != true {
            _ = try? authProfileStore.setDisabled(false, for: profile.type)
        }
    }

    @discardableResult
    private func removeAuthProfile(for provider: ProviderRowState.ID) throws -> Bool {
        let providerType = oauthProviderType(for: provider)
        if let authProfileID = authProfileID(for: provider) {
            let deleted = try authProfileStore.delete(id: authProfileID)
            if deleted || !allowsLegacyProviderWideAuthFallback(for: provider) {
                return deleted
            }
        }
        guard allowsLegacyProviderWideAuthFallback(for: provider) else { return false }
        return try authProfileStore.delete(for: providerType) > 0
    }

    @discardableResult
    private func disableAuthProfile(for provider: ProviderRowState.ID) throws -> Bool {
        let providerType = oauthProviderType(for: provider)
        if let authProfileID = authProfileID(for: provider) {
            let disabled = try authProfileStore.setDisabled(true, id: authProfileID)
            if disabled || !allowsLegacyProviderWideAuthFallback(for: provider) {
                return disabled
            }
        }
        guard allowsLegacyProviderWideAuthFallback(for: provider) else { return false }
        return try authProfileStore.setDisabled(true, for: providerType) > 0
    }

    func removeInitialProvider(_ provider: ProviderRowState.ID) {
        do {
            _ = try removeAuthProfile(for: provider)
            refreshProfiles()
            try resetProviderSettings(provider)
            settingsMessage = nil
        } catch {
            refreshProfiles()
            settingsMessage = nil
        }
    }

    func removeProvider(_ provider: ProviderRowState.ID) {
        let providerName = oauthProviderName(oauthProviderType(for: provider))

        do {
            let deleted = try removeAuthProfile(for: provider)
            refreshProfiles()
            if !deleted {
                settingsMessage = "\(providerName) auth file was not found."
            } else {
                try resetProviderSettings(provider)
                settingsMessage = "\(providerName) account was removed."
            }
        } catch {
            refreshProfiles()
            settingsMessage = "\(providerName) account removal failed: \(error.localizedDescription)"
        }
    }

    func disconnectProvider(_ provider: ProviderRowState.ID) {
        let providerName = oauthProviderName(oauthProviderType(for: provider))

        do {
            let disabled = try disableAuthProfile(for: provider)
            refreshProfiles()
            if !disabled {
                settingsMessage = "\(providerName) auth file was not found."
            } else {
                settingsMessage = "\(providerName) connection was disabled. The auth file was not deleted."
            }
        } catch {
            refreshProfiles()
            settingsMessage = "\(providerName) connection disable failed: \(error.localizedDescription)"
        }
    }

    func addProvider() {
        settingsMessage = "Claude API profiles are hidden from the default account list in this version."
    }

    func toggleAccountDetailVisibility(_ provider: ProviderRowState.ID) {
        var updatedConfig = config
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
            updatedConfig.oauthCommandProfiles[index].accountDetailHidden.toggle()
            do {
                try savePrivacyOnlyConfig(updatedConfig)
            } catch {
                settingsMessage = "Account privacy update failed: \(error.localizedDescription)"
            }
            return
        }

        var accountPrivacy = config.accountPrivacy
        switch oauthProviderType(for: provider) {
        case .claude:
            accountPrivacy.claudeHidden.toggle()
        case .codex:
            accountPrivacy.codexHidden.toggle()
        }

        do {
            try saveAccountPrivacy(accountPrivacy)
        } catch {
            settingsMessage = "Account privacy update failed: \(error.localizedDescription)"
        }
    }

    func commandNameAvailability(provider: ProviderRowState.ID, functionName: String) async -> CommandNameAvailability {
        let normalizedName = normalizeCommandName(functionName)
        do {
            try ShellCommandNameValidator.validate(normalizedName)
            var updatedConfig = config
            if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
                updatedConfig.oauthCommandProfiles[index].commandName = normalizedName
            } else {
                switch oauthProviderType(for: provider) {
                case .claude:
                    updatedConfig.commands.cc = normalizedName
                case .codex:
                    updatedConfig.commands.ccodex = normalizedName
                }
            }
            let activeNames = activeFunctionNames(in: updatedConfig)
            try ShellCommandNameValidator.validate(activeNames)
            try shellInstaller.validateFunctionNames([normalizedName])
            return .available
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func saveClaudeFunctionName(_ functionName: String) throws {
        if let claudeProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.claude }) {
            try saveClaudeOAuthSettings(
                provider: ProviderRowState.ID(rawValue: claudeProfile.id),
                functionName: functionName,
                nickname: claudeProfile.nickname,
                dangerousPermissionsEnabled: claudeProfile.dangerousPermissionsEnabled
            )
        } else {
            var commands = config.commands
            commands.cc = normalizeCommandName(functionName)
            try saveCommands(commands)
        }
    }

    func saveClaudeOAuthSettings(functionName: String, nickname: String, dangerousPermissionsEnabled: Bool) throws {
        let provider = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.claude })
            .map { ProviderRowState.ID(rawValue: $0.id) } ?? .claude
        try saveClaudeOAuthSettings(
            provider: provider,
            functionName: functionName,
            nickname: nickname,
            dangerousPermissionsEnabled: dangerousPermissionsEnabled
        )
    }

    func saveClaudeOAuthSettings(provider: ProviderRowState.ID, functionName: String, nickname: String, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        let normalizedFunctionName = normalizeCommandName(functionName)
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
            updatedConfig.oauthCommandProfiles[index].commandName = normalizedFunctionName
            updatedConfig.oauthCommandProfiles[index].nickname = nickname
            updatedConfig.oauthCommandProfiles[index].dangerousPermissionsEnabled = dangerousPermissionsEnabled
        } else {
            updatedConfig.commands.cc = normalizedFunctionName
            updatedConfig.nicknames.cc = nickname
            updatedConfig.includeDangerouslySkipPermissions = dangerousPermissionsEnabled
        }
        try saveConfig(
            updatedConfig,
            validateShellFunctions: true,
            shellProfileValidationNames: [normalizedFunctionName]
        )
    }

    func saveClaudeAPISettings(functionName: String, model: String) throws {
        var updatedConfig = config
        updatedConfig.commands.ccapi = normalizeCommandName(functionName)
        updatedConfig.ccapi = AppConfig.ClaudeAPI(model: model)
        try saveConfig(
            updatedConfig,
            validateShellFunctions: true,
            shellProfileValidationNames: [updatedConfig.commands.ccapi]
        )
    }

    func saveCodexSettings(functionName: String, codex: AppConfig.Codex) throws {
        let commandProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.codex })
        let provider = commandProfile.map { ProviderRowState.ID(rawValue: $0.id) } ?? .codex
        try saveCodexSettings(
            provider: provider,
            functionName: functionName,
            nickname: commandProfile?.nickname ?? config.nicknames.ccodex,
            codex: codex,
            dangerousPermissionsEnabled: commandProfile?.dangerousPermissionsEnabled ?? config.includeDangerouslySkipPermissions
        )
    }

    func saveCodexSettings(functionName: String, nickname: String, codex: AppConfig.Codex, dangerousPermissionsEnabled: Bool) throws {
        let provider = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.codex })
            .map { ProviderRowState.ID(rawValue: $0.id) } ?? .codex
        try saveCodexSettings(
            provider: provider,
            functionName: functionName,
            nickname: nickname,
            codex: codex,
            dangerousPermissionsEnabled: dangerousPermissionsEnabled
        )
    }

    func saveCodexSettings(provider: ProviderRowState.ID, functionName: String, nickname: String, codex: AppConfig.Codex, dangerousPermissionsEnabled: Bool) throws {
        var updatedConfig = config
        let normalizedFunctionName = normalizeCommandName(functionName)
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
            updatedConfig.oauthCommandProfiles[index].commandName = normalizedFunctionName
            updatedConfig.oauthCommandProfiles[index].nickname = nickname
            updatedConfig.oauthCommandProfiles[index].codex = codex
            updatedConfig.oauthCommandProfiles[index].dangerousPermissionsEnabled = dangerousPermissionsEnabled
        } else {
            updatedConfig.commands.ccodex = normalizedFunctionName
            updatedConfig.nicknames.ccodex = nickname
            updatedConfig.ccodex = codex
            updatedConfig.includeDangerouslySkipPermissions = dangerousPermissionsEnabled
        }
        try saveConfig(
            updatedConfig,
            validateShellFunctions: true,
            shellProfileValidationNames: [normalizedFunctionName]
        )
    }

    func savePort(_ port: Int) throws {
        guard (1...65_535).contains(port) else { throw ShellFunctionRendererError.invalidPort(port) }
        var updatedConfig = config
        updatedConfig.port = port
        try saveConfig(updatedConfig)
    }

    func saveCommands(_ commands: AppConfig.Commands) throws {
        var updatedConfig = config
        updatedConfig.commands = normalizedCommands(commands)
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
            settingsMessage = "Keep either the Dock icon or menu bar icon enabled."
            return
        }
        var updatedConfig = config
        updatedConfig.showDockIcon = isVisible
        try saveConfig(updatedConfig)
        appAppearanceService.apply(showDockIcon: isVisible)
    }

    func saveMenuBarIconVisible(_ isVisible: Bool) throws {
        guard isVisible || config.showDockIcon else {
            settingsMessage = "Keep either the Dock icon or menu bar icon enabled."
            return
        }
        var updatedConfig = config
        updatedConfig.showMenuBarIcon = isVisible
        try saveConfig(updatedConfig)
    }

    func installShellFunctions(helperCommand: String = "/usr/local/bin/cliproxy-manager") throws {
        try automaticShellInstallService.apply(config: config, helperCommand: helperCommand, enabledFunctions: enabledShellFunctions())
        settingsMessage = "Installation complete. Open a new terminal or run source ~/.zshrc."
        rebuildOptionRows()
    }

    @discardableResult
    func saveSetting(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            settingsMessage = error.localizedDescription
            return false
        }
    }

    func refreshCodexModels() async {
        guard !codexModelLoadingState.isLoading, !isServerActionInProgress else { return }

        if serverControlState.isRunning {
            await loadCodexModels()
            return
        }

        codexModelLoadingState = .startingServer
        isServerActionInProgress = true
        defer { isServerActionInProgress = false }

        do {
            try await proxyService.start(port: config.port)
            await refreshUntilServerIsReady()
            serverControlState = serverStatus.severity == .ready ? .running : .stopped
            await loadCodexModels()
        } catch {
            handleCodexModelLoadingFailure(error)
        }
    }

    func loadCodexModels() async {
        codexModelLoadingState = .loadingModels
        do {
            availableCodexModels = try await modelClient.codexBaseModels(port: config.port)
            codexModelLoadingState = .idle
        } catch {
            handleCodexModelLoadingFailure(error)
        }
    }

    private func handleCodexModelLoadingFailure(_ error: Error? = nil) {
        availableCodexModels = []
        let fallbackMessage = "Codex is connected, but the app could not load models through the local proxy server. Start the server and refresh, or enter a model manually."
        codexModelLoadingState = .failed(error?.localizedDescription ?? fallbackMessage)
    }

    private func normalizeCommandName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedCommands(_ commands: AppConfig.Commands) -> AppConfig.Commands {
        AppConfig.Commands(
            cc: normalizeCommandName(commands.cc),
            ccapi: normalizeCommandName(commands.ccapi),
            ccodex: normalizeCommandName(commands.ccodex)
        )
    }

    static func availableConfig(_ config: AppConfig) -> AppConfig {
        var config = config
        config.showNotifications = false
        config.roundRobinEnabled = false
        return config
    }

    private static func persistedConfig(_ config: AppConfig) -> AppConfig {
        var updatedConfig = availableConfig(config)
        updatedConfig.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(updatedConfig.oauthCommandProfiles)
        return mirroredLegacyFields(in: updatedConfig)
    }

    private static func reconciledOAuthCommandProfiles(in config: AppConfig, authProfiles: [AuthProfile]) -> AppConfig {
        var updatedConfig = config
        var commandProfiles = config.oauthCommandProfiles
        let hasStoredProfiles = !commandProfiles.isEmpty
        var usedIDs = Set(commandProfiles.map(\.id))
        var seenAuthProfileIDs = Set(commandProfiles.map(\.authProfileID))
        var firstProviderSeen: Set<AuthProfileType> = []

        for authProfile in authProfiles {
            let isFirstForProvider = !firstProviderSeen.contains(authProfile.type)
            firstProviderSeen.insert(authProfile.type)
            guard !seenAuthProfileIDs.contains(authProfile.id) else { continue }

            let id = commandProfileID(
                provider: authProfile.type,
                authProfileID: authProfile.id,
                preferLegacyID: isFirstForProvider && !hasStoredProfiles,
                usedIDs: &usedIDs
            )
            let legacyCommandName: String
            let legacyNickname: String
            let legacyPrivacyHidden: Bool
            let legacyCodex: AppConfig.Codex?
            switch authProfile.type {
            case .claude:
                legacyCommandName = isFirstForProvider && !hasStoredProfiles ? config.commands.cc : ""
                legacyNickname = isFirstForProvider && !hasStoredProfiles ? config.nicknames.cc : ""
                legacyPrivacyHidden = isFirstForProvider && !hasStoredProfiles ? config.accountPrivacy.claudeHidden : true
                legacyCodex = nil
            case .codex:
                legacyCommandName = isFirstForProvider && !hasStoredProfiles ? config.commands.ccodex : ""
                legacyNickname = isFirstForProvider && !hasStoredProfiles ? config.nicknames.ccodex : ""
                legacyPrivacyHidden = isFirstForProvider && !hasStoredProfiles ? config.accountPrivacy.codexHidden : true
                legacyCodex = isFirstForProvider && !hasStoredProfiles ? config.ccodex : AppConfig.default.ccodex
            }
            commandProfiles.append(
                AppConfig.OAuthCommandProfile(
                    id: id,
                    provider: authProfile.type,
                    authProfileID: authProfile.id,
                    commandName: legacyCommandName,
                    nickname: legacyNickname,
                    accountDetailHidden: legacyPrivacyHidden,
                    dangerousPermissionsEnabled: isFirstForProvider && !hasStoredProfiles ? config.includeDangerouslySkipPermissions : false,
                    codex: legacyCodex,
                    modelPrefix: "",
                    isEnabled: true
                )
            )
            seenAuthProfileIDs.insert(authProfile.id)
        }

        updatedConfig.oauthCommandProfiles = commandProfilesWithRecomputedModelPrefixes(commandProfiles)
        return mirroredLegacyFields(in: updatedConfig)
    }

    private static func mirroredLegacyFields(in config: AppConfig) -> AppConfig {
        var updatedConfig = config
        if let claudeProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.claude }) {
            updatedConfig.commands.cc = claudeProfile.commandName
            updatedConfig.nicknames.cc = claudeProfile.nickname
            updatedConfig.accountPrivacy.claudeHidden = claudeProfile.accountDetailHidden
            updatedConfig.includeDangerouslySkipPermissions = claudeProfile.dangerousPermissionsEnabled
        }
        if let codexProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.codex }) {
            updatedConfig.commands.ccodex = codexProfile.commandName
            updatedConfig.nicknames.ccodex = codexProfile.nickname
            updatedConfig.accountPrivacy.codexHidden = codexProfile.accountDetailHidden
            updatedConfig.ccodex = codexProfile.codex ?? AppConfig.default.ccodex
            if updatedConfig.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.claude }) == nil {
                updatedConfig.includeDangerouslySkipPermissions = codexProfile.dangerousPermissionsEnabled
            }
        }
        return updatedConfig
    }

    private static func commandProfileID(
        provider: AuthProfileType,
        authProfileID: String,
        preferLegacyID: Bool,
        usedIDs: inout Set<String>
    ) -> String {
        let legacyID = provider.rawValue
        if preferLegacyID, !usedIDs.contains(legacyID) {
            usedIDs.insert(legacyID)
            return legacyID
        }

        let baseID = "\(provider.rawValue)-\(slug(for: authProfileID))"
        var candidate = baseID
        var suffix = 2
        while usedIDs.contains(candidate) {
            candidate = "\(baseID)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }

    private static func commandProfilesWithRecomputedModelPrefixes(
        _ commandProfiles: [AppConfig.OAuthCommandProfile]
    ) -> [AppConfig.OAuthCommandProfile] {
        var usedPrefixes: Set<String> = []
        return commandProfiles.map { commandProfile in
            var updatedProfile = commandProfile
            updatedProfile.modelPrefix = uniqueModelPrefix(
                provider: commandProfile.provider,
                nickname: commandProfile.nickname,
                authProfileID: commandProfile.authProfileID,
                usedPrefixes: &usedPrefixes
            )
            return updatedProfile
        }
    }

    private static func uniqueModelPrefix(
        provider: AuthProfileType,
        nickname: String,
        authProfileID: String,
        usedPrefixes: inout Set<String>
    ) -> String {
        let basePrefix = modelPrefixBase(provider: provider, nickname: nickname, authProfileID: authProfileID)
        var candidate = basePrefix
        var suffix = 2
        while usedPrefixes.contains(candidate) {
            candidate = "\(basePrefix)-\(suffix)"
            suffix += 1
        }
        usedPrefixes.insert(candidate)
        return candidate
    }

    private static func modelPrefixBase(provider: AuthProfileType, nickname: String, authProfileID: String) -> String {
        let suffix = nonEmptySlug(for: nickname) ?? shortAuthProfileSlug(provider: provider, authProfileID: authProfileID)
        return "\(provider.rawValue)-\(suffix)"
    }

    private static func shortAuthProfileSlug(provider: AuthProfileType, authProfileID: String) -> String {
        let fileName = URL(fileURLWithPath: authProfileID).deletingPathExtension().lastPathComponent
        let fullSlug = slug(for: fileName)
        let providerPrefix = "\(provider.rawValue)-"
        let suffixSource: String
        if fullSlug == provider.rawValue {
            suffixSource = "account"
        } else if fullSlug.hasPrefix(providerPrefix) {
            suffixSource = String(fullSlug.dropFirst(providerPrefix.count))
        } else {
            suffixSource = fullSlug
        }

        let firstSegment = suffixSource.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return firstSegment.isEmpty ? "account" : firstSegment
    }

    private static func nonEmptySlug(for value: String) -> String? {
        let slug = rawSlug(for: value)
        return slug.isEmpty ? nil : slug
    }

    private static func slug(for value: String) -> String {
        let slug = rawSlug(for: value)
        return slug.isEmpty ? "account" : slug
    }

    private static func rawSlug(for value: String) -> String {
        let lowercasedValue = value.lowercased()
        var result = ""
        var previousWasSeparator = false
        for scalar in lowercasedValue.unicodeScalars {
            let isAllowed = (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value))
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func reconcileConfigWithAuthProfiles() {
        let updatedConfig = Self.reconciledOAuthCommandProfiles(in: config, authProfiles: authProfiles)
        if updatedConfig != config {
            config = updatedConfig
            cards = ProfileCard.makeDefaultCards(config: updatedConfig)
            rebuildOptionRows()
        }
        reconcileAuthProfilePrefixes()
    }

    private struct AuthProfilePrefixRollback {
        let authProfileID: String
        let oldPrefix: String?
    }

    private enum AuthProfilePrefixSyncError: LocalizedError {
        case profileNotUpdated(String)

        var errorDescription: String? {
            switch self {
            case .profileNotUpdated(let authProfileID):
                "Failed to update auth profile prefix for `\(authProfileID)`."
            }
        }
    }

    private func reconcileAuthProfilePrefixes() {
        _ = try? syncAuthProfilePrefixesForSave()
    }

    @discardableResult
    private func syncAuthProfilePrefixesForSave() throws -> [AuthProfilePrefixRollback] {
        var rollbacks: [AuthProfilePrefixRollback] = []
        let profilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        do {
            for commandProfile in config.oauthCommandProfiles where commandProfile.isEnabled {
                guard let authProfile = profilesByID[commandProfile.authProfileID],
                      authProfile.prefix != commandProfile.modelPrefix else {
                    continue
                }
                let updated = try authProfileStore.setPrefix(commandProfile.modelPrefix, id: commandProfile.authProfileID)
                guard updated else { throw AuthProfilePrefixSyncError.profileNotUpdated(commandProfile.authProfileID) }
                rollbacks.append(AuthProfilePrefixRollback(authProfileID: commandProfile.authProfileID, oldPrefix: authProfile.prefix))
            }
            if !rollbacks.isEmpty {
                authProfiles = try authProfileStore.profiles()
            }
            return rollbacks
        } catch {
            rollbackAuthProfilePrefixes(rollbacks)
            throw error
        }
    }

    private func rollbackAuthProfilePrefixes(_ rollbacks: [AuthProfilePrefixRollback]) {
        guard !rollbacks.isEmpty else { return }
        for rollback in rollbacks.reversed() {
            _ = try? authProfileStore.setPrefix(rollback.oldPrefix, id: rollback.authProfileID)
        }
        authProfiles = (try? authProfileStore.profiles()) ?? authProfiles
    }

    private func resetProviderSettings(_ provider: ProviderRowState.ID) throws {
        var updatedConfig = config
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
            updatedConfig.oauthCommandProfiles.remove(at: index)
            resetLegacyFields(for: oauthProviderType(for: provider), in: &updatedConfig)
            try saveConfig(updatedConfig, validateShellFunctions: true)
            return
        }

        resetLegacyFields(for: oauthProviderType(for: provider), in: &updatedConfig)
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    private func resetLegacyFields(for providerType: AuthProfileType, in config: inout AppConfig) {
        switch providerType {
        case .claude:
            config.commands.cc = AppConfig.default.commands.cc
            config.nicknames.cc = ""
            config.accountPrivacy.claudeHidden = true
        case .codex:
            config.commands.ccodex = AppConfig.default.commands.ccodex
            config.nicknames.ccodex = ""
            config.ccodex = AppConfig.default.ccodex
            config.accountPrivacy.codexHidden = true
        }
        config.includeDangerouslySkipPermissions = false
    }

    private func saveConfig(
        _ updatedConfig: AppConfig,
        validateShellFunctions: Bool = false,
        shellProfileValidationNames: [String]? = nil
    ) throws {
        let updatedConfig = Self.persistedConfig(updatedConfig)
        if validateShellFunctions {
            let activeNames = activeFunctionNames(in: updatedConfig)
            try ShellCommandNameValidator.validate(activeNames)
            if let shellProfileValidationNames {
                let validationNames = shellProfileValidationNames
                    .map(normalizeCommandName)
                    .filter { !$0.isEmpty }
                try ShellCommandNameValidator.validate(validationNames)
                if !validationNames.isEmpty {
                    try shellInstaller.validateFunctionNames(validationNames)
                }
            } else {
                try shellInstaller.validateFunctionNames(activeNames)
            }
        }
        let oldConfig = config
        let oldCards = cards
        config = updatedConfig
        cards = ProfileCard.makeDefaultCards(config: updatedConfig)
        rebuildOptionRows()
        rebuildProviderRows(claudeStatus: nil, codexStatus: nil)

        var prefixRollbacks: [AuthProfilePrefixRollback] = []
        var didApplyShellInstall = false
        do {
            prefixRollbacks = try syncAuthProfilePrefixesForSave()
            try automaticShellInstallService.apply(config: updatedConfig, enabledFunctions: enabledShellFunctions(in: updatedConfig))
            didApplyShellInstall = true
            try configStore.save(updatedConfig)
            lastPersistedConfig = updatedConfig
            rebuildOptionRows()
            rebuildProviderRows(claudeStatus: nil, codexStatus: nil)
        } catch {
            rollbackAuthProfilePrefixes(prefixRollbacks)
            if didApplyShellInstall {
                try? automaticShellInstallService.apply(config: oldConfig, enabledFunctions: enabledShellFunctions(in: oldConfig))
            }
            config = oldConfig
            cards = oldCards
            rebuildOptionRows()
            rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
            throw error
        }
    }

    private func saveAccountPrivacy(_ accountPrivacy: AppConfig.AccountPrivacy) throws {
        var updatedConfig = config
        updatedConfig.accountPrivacy = accountPrivacy
        try savePrivacyOnlyConfig(updatedConfig)
    }

    private func savePrivacyOnlyConfig(_ updatedConfig: AppConfig) throws {
        let availableConfig = Self.persistedConfig(updatedConfig)
        let oldConfig = config
        let oldCards = cards
        config = availableConfig
        cards = ProfileCard.makeDefaultCards(config: availableConfig).map { card in
            switch card.id {
            case ProfileCard.claudeID:
                if let lastClaudeStatus {
                    card.updatingStatus(lastClaudeStatus)
                } else {
                    card
                }
            case ProfileCard.codexID:
                if let lastCodexStatus {
                    card.updatingStatus(lastCodexStatus)
                } else {
                    card
                }
            default:
                card
            }
        }
        rebuildOptionRows()
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)

        var prefixRollbacks: [AuthProfilePrefixRollback] = []
        do {
            prefixRollbacks = try syncAuthProfilePrefixesForSave()
            try configStore.save(availableConfig)
            lastPersistedConfig = availableConfig
        } catch {
            rollbackAuthProfilePrefixes(prefixRollbacks)
            config = oldConfig
            cards = oldCards
            rebuildOptionRows()
            rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
            throw error
        }
    }

    private func applyInitialShellInstall() {
        do {
            try applyShellInstallForCurrentProfiles()
        } catch {
            settingsMessage = "Automatic shell function installation failed: \(error.localizedDescription)"
        }
    }

    private func applyShellInstallForCurrentProfiles() throws {
        let activeNames = activeFunctionNames(in: config)
        try ShellCommandNameValidator.validate(activeNames)
        try automaticShellInstallService.apply(config: config, enabledFunctions: enabledShellFunctions())
    }

    private func enabledShellFunctions() -> AutomaticShellInstallService.EnabledFunctions {
        enabledShellFunctions(in: config)
    }

    private func enabledShellFunctions(in config: AppConfig) -> AutomaticShellInstallService.EnabledFunctions {
        let enabledProfiles = renderableOAuthCommandProfiles(in: config)
        return AutomaticShellInstallService.EnabledFunctions(
            claudeOAuth: enabledProfiles.contains { $0.provider == .claude },
            codex: enabledProfiles.contains { $0.provider == .codex },
            claudeAPI: false
        )
    }

    private func activeFunctionNames(in config: AppConfig) -> [String] {
        renderableOAuthCommandProfiles(in: config)
            .map { normalizeCommandName($0.commandName) }
            .filter { !$0.isEmpty }
    }

    private func renderableOAuthCommandProfiles(in config: AppConfig) -> [AppConfig.OAuthCommandProfile] {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        return config.oauthCommandProfiles.filter { commandProfile in
            guard commandProfile.isEnabled,
                  let authProfile = authProfilesByID[commandProfile.authProfileID],
                  !authProfile.disabled else {
                return false
            }
            return true
        }
    }

    private func rebuildProviderRows(claudeStatus: DiagnosticStatus?, codexStatus: DiagnosticStatus?) {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        if config.oauthCommandProfiles.isEmpty {
            var usedIDs: Set<String> = []
            var firstProviderSeen: Set<AuthProfileType> = []
            providerRows = authProfiles.map { authProfile in
                let enabledProfile = authProfile.disabled ? nil : authProfile
                let diagnosticStatus = authProfile.type == .codex ? codexStatus : claudeStatus
                let fallback = authProfile.type == .codex
                    ? diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Codex OAuth profile."
                    : diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Claude OAuth profile."
                let isFirstForProvider = !firstProviderSeen.contains(authProfile.type)
                firstProviderSeen.insert(authProfile.type)
                let rowID = Self.commandProfileID(
                    provider: authProfile.type,
                    authProfileID: authProfile.id,
                    preferLegacyID: isFirstForProvider,
                    usedIDs: &usedIDs
                )
                return ProviderRowState(
                    id: ProviderRowState.ID(rawValue: rowID),
                    providerType: authProfile.type,
                    authProfileID: authProfile.id,
                    commandProfileID: rowID,
                    name: authProfile.type == .codex ? "Codex OAuth" : "Claude OAuth",
                    nickname: authProfile.type == .codex ? config.nicknames.ccodex : config.nicknames.cc,
                    functionName: authProfile.type == .codex ? config.commands.ccodex : config.commands.cc,
                    connectionTitle: enabledProfile == nil ? "Needs connection" : "Connected",
                    connectionDetail: profileDetail(profile: enabledProfile ?? authProfile, fallback: fallback),
                    isConnected: enabledProfile != nil,
                    isErrored: isProviderErrored(providerType: authProfile.type, enabledProfile: enabledProfile, diagnosticStatus: diagnosticStatus),
                    accountDetailHidden: authProfile.type == .codex ? config.accountPrivacy.codexHidden : config.accountPrivacy.claudeHidden
                )
            }
            return
        }

        providerRows = config.oauthCommandProfiles.compactMap { commandProfile in
            guard let authProfile = authProfilesByID[commandProfile.authProfileID] else { return nil }
            let enabledProfile = authProfile.disabled ? nil : authProfile
            let diagnosticStatus = commandProfile.provider == .codex ? codexStatus : claudeStatus
            let fallback = commandProfile.provider == .codex
                ? diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Codex OAuth profile."
                : diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Claude OAuth profile."
            return ProviderRowState(
                id: ProviderRowState.ID(rawValue: commandProfile.id),
                providerType: commandProfile.provider,
                authProfileID: commandProfile.authProfileID,
                commandProfileID: commandProfile.id,
                name: commandProfile.provider == .codex ? "Codex OAuth" : "Claude OAuth",
                nickname: commandProfile.nickname,
                functionName: commandProfile.commandName,
                connectionTitle: enabledProfile == nil ? "Needs connection" : "Connected",
                connectionDetail: profileDetail(
                    profile: enabledProfile ?? authProfile,
                    fallback: fallback
                ),
                isConnected: enabledProfile != nil,
                isErrored: isProviderErrored(providerType: commandProfile.provider, enabledProfile: enabledProfile, diagnosticStatus: diagnosticStatus),
                accountDetailHidden: commandProfile.accountDetailHidden
            )
        }
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

    private func stableServerStatus() async -> DiagnosticStatus {
        let firstStatus = await proxyHealthClient.status(port: config.port)
        guard firstStatus.severity == .error else { return firstStatus }

        try? await Task.sleep(nanoseconds: serverStatusRetryDelayNanoseconds)
        return await proxyHealthClient.status(port: config.port)
    }

    private func passiveRefreshPresentationStatus(from status: DiagnosticStatus) -> DiagnosticStatus {
        guard isHealthTimeout(status) else { return status }

        return DiagnosticStatus(
            severity: .warning,
            title: status.title,
            message: status.message
        )
    }

    private func codexProviderStatus(from serverStatus: DiagnosticStatus) -> DiagnosticStatus {
        guard serverStatus.severity == .error,
              !isCriticalServerStatusForProvider(serverStatus) else {
            return serverStatus
        }

        return DiagnosticStatus(
            severity: .warning,
            title: serverStatus.title,
            message: serverStatus.message
        )
    }

    private func isProviderErrored(
        providerType: AuthProfileType,
        enabledProfile: AuthProfile?,
        diagnosticStatus: DiagnosticStatus?
    ) -> Bool {
        guard let enabledProfile else { return false }
        if isExpired(enabledProfile) { return true }

        guard let diagnosticStatus,
              diagnosticStatus.severity == .error else {
            return false
        }

        switch providerType {
        case .claude:
            return false
        case .codex:
            return isCriticalServerStatusForProvider(diagnosticStatus)
        }
    }

    private func isCriticalServerStatusForProvider(_ status: DiagnosticStatus) -> Bool {
        switch status.title {
        case "CLIProxyAPI Port Configuration Error",
             "Failed to start CLIProxyAPI",
             "Failed to stop CLIProxyAPI",
             "Failed to restart CLIProxyAPI":
            return true
        default:
            return false
        }
    }

    private func isHealthTimeout(_ status: DiagnosticStatus) -> Bool {
        status.severity == .error && status.title == "CLIProxyAPI Response Timed Out"
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
        lastCodexStatus = codexProviderStatus(from: updatedServerStatus)
        if let claudeStatus {
            lastClaudeStatus = claudeStatus
        }
        refreshProfiles()

        cards = cards.map { card in
            switch card.id {
            case ProfileCard.claudeID:
                if let claudeStatus {
                    card.updatingStatus(claudeStatus)
                } else {
                    card
                }
            case ProfileCard.codexID:
                card.updatingStatus(updatedServerStatus)
            default:
                card
            }
        }
    }

    private func scheduleSettingsMessageAutoClear() {
        settingsMessageAutoClearTask?.cancel()
        settingsMessageAutoClearTask = nil
        guard settingsMessage != nil else { return }
        let delay = settingsMessageAutoClearDelayNanoseconds
        settingsMessageAutoClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            self?.clearSettingsMessage()
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

    private func isExpired(_ profile: AuthProfile?) -> Bool {
        guard let expired = profile?.expired,
              let expiryDate = ISO8601DateFormatter().date(from: expired) else {
            return false
        }
        return expiryDate <= Date()
    }
}

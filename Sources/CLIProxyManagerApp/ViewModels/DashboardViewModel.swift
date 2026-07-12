import Combine
import CLIProxyManagerCore
import Foundation
#if canImport(AppKit)
import AppKit
#endif

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
    func codexModelOptions(port: Int) async throws -> [CodexModelOption]
    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption]
    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption]
}

extension ProxyModelListing {
    func codexModelOptions(port: Int, modelPrefix: String) async throws -> [CodexModelOption] {
        try await codexModelOptions(port: port)
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
    private enum ProxyConfigurationRestartReason: Hashable {
        case apiKey
        case fastMode
    }

    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus
    @Published var serverControlState: ServerControlState = .stopped
    @Published var isServerActionInProgress = false
    @Published var isProfileLoginInProgress = false
    @Published private(set) var activeOAuthLoginProvider: ProviderRowState.ID?
    @Published private(set) var completedOAuthLoginProvider: ProviderRowState.ID?
    @Published private(set) var completedOAuthLoginIsInitialSetup = true
    @Published private(set) var config: AppConfig
    @Published private(set) var availableCodexModelOptions: [CodexModelOption] = []
    @Published private(set) var availableCodexAPIModelOptions: [CodexModelOption] = []
    @Published private(set) var availableClaudeAPIModelOptions: [ClaudeModelOption] = []
    @Published private(set) var availableClaudeModelOptionsByProvider: [ProviderRowState.ID: [ClaudeModelOption]] = [:]
    @Published private(set) var codexModelLoadingState: CodexModelLoadingState = .idle

    var availableCodexModels: [String] {
        availableCodexModelOptions.map(\.id)
    }

    func preferredCodexDefaultModel(in options: [CodexModelOption]) -> String? {
        options.first(where: { $0.id == "gpt-5.6-terra" })?.id ?? options.first?.id
    }

    var latestBaseCodexModel: String? {
        preferredCodexDefaultModel(in: availableCodexModelOptions)
    }
    @Published var settingsMessage: String? {
        didSet { scheduleSettingsMessageAutoClear() }
    }
    @Published var optionRows: [DashboardOptionRow] = []
    @Published var providerRows: [ProviderRowState] = []
    @Published private(set) var subscriptionUsageStates: [String: AccountSubscriptionUsageState] = [:]
    @Published private(set) var isSubscriptionUsageRefreshInProgress = false
    @Published private(set) var lastSuccessfulSubscriptionUsageRefreshAt: Date?
    @Published private(set) var cpmInstallationStatus: CPMInstallationStatus
    @Published private(set) var isCPMInstallationActionInProgress = false

    var canRefreshSubscriptionUsage: Bool {
        config.subscriptionUsage.isEnabled
            && subscriptionUsageKeyStore.isConfigured()
            && serverStatus.severity == .ready
    }

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
    private let subscriptionQuotaClient: any SubscriptionQuotaFetching
    private let subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring
    private let subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching
    private let claudeModelOptionsCache: any ClaudeModelOptionsCaching
    private let cpmInstallationService: any CPMInstallationManaging
    private let secretStore: any SecretStore
    private let subscriptionUsageSleep: @Sendable (UInt64) async throws -> Void
    private let serverStatusRetryDelayNanoseconds: UInt64
    private let settingsMessageAutoClearDelayNanoseconds: UInt64
    private var authProfiles: [AuthProfile] = []
    private var oauthLoginTask: Task<Void, Never>?
    private var oauthLoginSessionID: UUID?
    private var settingsMessageAutoClearTask: Task<Void, Never>?
    private var lastClaudeStatus: DiagnosticStatus?
    private var lastCodexStatus: DiagnosticStatus?
    private var lastPersistedConfig: AppConfig
    private var subscriptionUsagePollingTask: Task<Void, Never>?
    private var subscriptionUsageRefreshTask: Task<Void, Never>?
    private var subscriptionUsageRefreshIsForced = false
    private var pendingForcedSubscriptionUsageRefresh = false
    private var pendingProxyConfigurationRestartReasons: Set<ProxyConfigurationRestartReason> = []
    private var proxyConfigurationRestartTask: Task<Void, Never>?
    private var subscriptionUsageRefreshGeneration = 0
    private var subscriptionUsageRetryDelayNanoseconds: UInt64 = 60_000_000_000

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
        subscriptionQuotaClient: any SubscriptionQuotaFetching = CLIProxyAPISubscriptionQuotaClient(),
        subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring = SubscriptionUsageManagementKeyFileStore(),
        subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching = SubscriptionUsageSnapshotCacheFileStore(),
        claudeModelOptionsCache: any ClaudeModelOptionsCaching = ClaudeModelOptionsCacheFileStore(),
        cpmInstallationService: (any CPMInstallationManaging)? = nil,
        secretStore: any SecretStore = FileSecretStore(),
        subscriptionUsageSleep: @escaping @Sendable (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        },
        serverStatusRetryDelayNanoseconds: UInt64 = 500_000_000,
        settingsMessageAutoClearDelayNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.configStore = configStore
        self.shellInstaller = shellInstaller
        self.modelClient = modelClient
        self.authProfileStore = authProfileStore
        let defaultRuntimePreparer = ProxyServiceManager(paths: ManagedPaths(), bundledBinaryURL: BundledProxyBinary.url(), bundledManifestURL: BundledProxyBinary.manifestURL())
        self.oauthLoginService = oauthLoginService ?? OAuthLoginService(runtimePreparer: defaultRuntimePreparer)
        self.automaticShellInstallService = automaticShellInstallService ?? AutomaticShellInstallService.runtimeDefault(
            installer: shellInstaller,
            secretStore: secretStore
        )
        self.proxyHealthClient = proxyHealthClient
        self.proxyService = proxyService
        self.claudeConnector = claudeConnector
        self.loginItemService = loginItemService
        self.appAppearanceService = appAppearanceService
        self.subscriptionQuotaClient = subscriptionQuotaClient
        self.subscriptionUsageKeyStore = subscriptionUsageKeyStore
        self.subscriptionUsageSnapshotCache = subscriptionUsageSnapshotCache
        self.claudeModelOptionsCache = claudeModelOptionsCache
        let resolvedCPMInstallationService = cpmInstallationService ?? CPMInstallationService()
        self.cpmInstallationService = resolvedCPMInstallationService
        self.cpmInstallationStatus = resolvedCPMInstallationService.status()
        self.secretStore = secretStore
        self.subscriptionUsageSleep = subscriptionUsageSleep
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
        restoreClaudeModelOptions()
        restoreSubscriptionUsageSnapshots()
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

    func previewUsageOverlayBackgroundOpacity(_ opacity: Double) {
        config.usageOverlay.backgroundOpacity = min(max(opacity, 0.2), 1)
    }

    func saveUsageOverlay(_ usageOverlay: AppConfig.UsageOverlay) throws {
        var updatedConfig = config
        updatedConfig.usageOverlay = usageOverlay
        try savePrivacyOnlyConfig(updatedConfig)
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
        let url = ManagedPaths().proxyLogsDirectory
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
        updatedConfig.codexAPI = config.codexAPI
        updatedConfig.nicknames = config.nicknames
        updatedConfig.includeDangerouslySkipPermissions = config.includeDangerouslySkipPermissions
        do {
            let shouldDeleteManagementKey = config.subscriptionUsage.isEnabled || subscriptionUsageKeyStore.isConfigured()
            try saveConfig(updatedConfig)
            if shouldDeleteManagementKey {
                cancelSubscriptionUsageWork()
                try subscriptionUsageKeyStore.deleteManagementKey()
            }
            setSubscriptionUsageStates(.disabled)
            clearSubscriptionUsageSnapshots()
            appAppearanceService.apply(showDockIcon: updatedConfig.showDockIcon)
            appAppearanceService.apply(appearance: updatedConfig.appearance)
            settingsMessage = "Settings reset to defaults."
            if serverControlState.isRunning {
                Task { [weak self] in
                    await self?.restartServer()
                }
            }
        } catch {
            settingsMessage = "Reset failed: \(error.localizedDescription)"
        }
    }

    func startApplication() async {
        await refresh()
        await prepareSubscriptionUsage()
        await performAutostartIfEnabled()
    }

    func openMainWindow() async {
        await refresh()
    }

    func refresh() async {
        let rawServerStatus = await stableServerStatus()
        let updatedServerStatus = passiveRefreshPresentationStatus(from: rawServerStatus)
        let claudeStatus = await claudeConnector.status()
        updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
    }

    func saveSubscriptionUsageEnabled(_ enabled: Bool) throws {
        if enabled {
            let createdKey = try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
            var updatedConfig = config
            updatedConfig.subscriptionUsage.isEnabled = true
            do {
                try saveConfig(updatedConfig)
            } catch {
                if createdKey {
                    try? subscriptionUsageKeyStore.deleteManagementKey()
                }
                throw error
            }
        } else {
            var updatedConfig = config
            updatedConfig.subscriptionUsage.isEnabled = false
            try saveConfig(updatedConfig)
            cancelSubscriptionUsageWork()
            try subscriptionUsageKeyStore.deleteManagementKey()
            setSubscriptionUsageStates(.disabled)
            clearSubscriptionUsageSnapshots()
        }

        Task { [weak self] in
            guard let self else { return }
            if self.serverControlState.isRunning {
                await self.restartServer()
            } else {
                await self.refreshSubscriptionUsage()
            }
        }
    }

    func prepareSubscriptionUsage() async {
        do {
            if config.subscriptionUsage.isEnabled {
                let createdKey = try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
                if createdKey, serverControlState.isRunning {
                    await restartServer()
                    return
                }
            } else if subscriptionUsageKeyStore.isConfigured() {
                try subscriptionUsageKeyStore.deleteManagementKey()
                if serverControlState.isRunning {
                    await restartServer()
                    return
                }
            }
        } catch {
            settingsMessage = "Subscription usage setup failed: \(error.localizedDescription)"
            return
        }
        await refreshSubscriptionUsage()
    }

    private func restoreSubscriptionUsageSnapshots() {
        guard config.subscriptionUsage.isEnabled else { return }
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        let snapshots = subscriptionUsageSnapshotCache.load().filter { enabledProfileIDs.contains($0.key) }
        guard !snapshots.isEmpty else { return }

        for snapshot in snapshots.values {
            subscriptionUsageStates[snapshot.profileID] = .available(snapshot)
        }
        lastSuccessfulSubscriptionUsageRefreshAt = snapshots.values.map(\.fetchedAt).max()
    }

    private func persistSuccessfulSubscriptionUsageSnapshots() {
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        let snapshots = subscriptionUsageStates.reduce(into: [String: SubscriptionUsageSnapshot]()) { result, entry in
            if enabledProfileIDs.contains(entry.key), let snapshot = entry.value.snapshot {
                result[entry.key] = snapshot
            }
        }
        try? subscriptionUsageSnapshotCache.save(snapshots)
    }

    private func clearSubscriptionUsageSnapshots() {
        try? subscriptionUsageSnapshotCache.clear()
    }

    private func cancelSubscriptionUsageWork() {
        subscriptionUsageRefreshGeneration += 1
        subscriptionUsageRefreshTask?.cancel()
        subscriptionUsageRefreshTask = nil
        subscriptionUsageRefreshIsForced = false
        pendingForcedSubscriptionUsageRefresh = false
        isSubscriptionUsageRefreshInProgress = false
        subscriptionUsagePollingTask?.cancel()
        subscriptionUsagePollingTask = nil
        subscriptionUsageRetryDelayNanoseconds = 60_000_000_000
    }

    private struct SubscriptionUsageRemovalRefreshContext {
        let canceledActiveRefresh: Bool
        let requiresForcedRefresh: Bool
    }

    private func invalidateSubscriptionUsageRefreshForRemoval() -> SubscriptionUsageRemovalRefreshContext {
        let canceledActiveRefresh = subscriptionUsageRefreshTask != nil
        let requiresForcedRefresh = subscriptionUsageRefreshIsForced || pendingForcedSubscriptionUsageRefresh
        guard canceledActiveRefresh else {
            return SubscriptionUsageRemovalRefreshContext(
                canceledActiveRefresh: false,
                requiresForcedRefresh: requiresForcedRefresh
            )
        }

        subscriptionUsageRefreshGeneration += 1
        subscriptionUsageRefreshTask?.cancel()
        subscriptionUsageRefreshTask = nil
        subscriptionUsageRefreshIsForced = false
        pendingForcedSubscriptionUsageRefresh = false
        isSubscriptionUsageRefreshInProgress = false
        subscriptionUsagePollingTask?.cancel()
        subscriptionUsagePollingTask = nil
        return SubscriptionUsageRemovalRefreshContext(
            canceledActiveRefresh: true,
            requiresForcedRefresh: requiresForcedRefresh
        )
    }

    private func resumeSubscriptionUsageAfterRemoval(_ context: SubscriptionUsageRemovalRefreshContext) {
        if context.canceledActiveRefresh {
            Task { [weak self] in
                await self?.refreshSubscriptionUsage(force: context.requiresForcedRefresh)
            }
        } else if subscriptionUsagePollingTask == nil {
            scheduleSubscriptionUsagePollingIfNeeded()
        }
    }

    func refreshSubscriptionUsage(force: Bool = false) async {
        if subscriptionUsageRefreshTask != nil {
            if force {
                pendingForcedSubscriptionUsageRefresh = true
            }
            return
        }
        guard config.subscriptionUsage.isEnabled else {
            setSubscriptionUsageStates(.disabled)
            return
        }
        guard subscriptionUsageKeyStore.isConfigured() else {
            setSubscriptionUsageStates(.managementKeyNotConfigured)
            return
        }
        let profiles = force
            ? authProfiles.filter(isSubscriptionUsageEnabled(for:))
            : refreshableSubscriptionUsageProfiles()
        guard !profiles.isEmpty else {
            subscriptionUsagePollingTask?.cancel()
            subscriptionUsagePollingTask = nil
            return
        }

        subscriptionUsageRefreshGeneration += 1
        let generation = subscriptionUsageRefreshGeneration
        isSubscriptionUsageRefreshInProgress = true
        let previousStates = subscriptionUsageStates
        if !force {
            let unavailableProfileIDs = Set(profiles.compactMap { profile -> String? in
                previousStates[profile.id]?.snapshot == nil ? profile.id : nil
            })
            if !unavailableProfileIDs.isEmpty {
                setSubscriptionUsageStates(.loading, profileIDs: unavailableProfileIDs)
            }
        }
        let port = config.port
        let quotaClient = subscriptionQuotaClient
        let refreshTask = Task { [weak self] in
            let report = await quotaClient.fetchUsage(port: port, profiles: profiles)
            guard !Task.isCancelled,
                  let self,
                  self.config.subscriptionUsage.isEnabled,
                  self.subscriptionUsageKeyStore.isConfigured(),
                  self.subscriptionUsageRefreshGeneration == generation else {
                return
            }
            self.applySubscriptionUsageReport(report, for: profiles, previousStates: previousStates)
            self.rebuildProviderRows(claudeStatus: self.lastClaudeStatus, codexStatus: self.lastCodexStatus)
            self.scheduleSubscriptionUsagePollingIfNeeded()
        }
        subscriptionUsageRefreshTask = refreshTask
        subscriptionUsageRefreshIsForced = force
        await refreshTask.value
        if subscriptionUsageRefreshGeneration == generation {
            subscriptionUsageRefreshTask = nil
            subscriptionUsageRefreshIsForced = false
            isSubscriptionUsageRefreshInProgress = false
            if pendingForcedSubscriptionUsageRefresh {
                pendingForcedSubscriptionUsageRefresh = false
                await refreshSubscriptionUsage(force: true)
            }
        }
    }

    private func applySubscriptionUsageReport(
        _ report: SubscriptionUsageReport,
        for profiles: [AuthProfile],
        previousStates: [String: AccountSubscriptionUsageState]? = nil
    ) {
        var didUpdateStates = false
        var successfulSnapshots: [SubscriptionUsageSnapshot] = []
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        for profile in profiles where enabledProfileIDs.contains(profile.id) {
            let reported = report.statesByProfileID[profile.id] ?? .unavailable(.transientFailure)
            let merged = mergedSubscriptionUsageState(
                previous: previousStates?[profile.id] ?? subscriptionUsageStates[profile.id],
                reported: reported
            )
            subscriptionUsageStates[profile.id] = merged
            if case let .available(snapshot) = reported {
                successfulSnapshots.append(snapshot)
            }
            didUpdateStates = true
        }
        if let latestSuccess = successfulSnapshots.map(\.fetchedAt).max() {
            lastSuccessfulSubscriptionUsageRefreshAt = latestSuccess
        }
        if didUpdateStates {
            persistSuccessfulSubscriptionUsageSnapshots()
        }
    }

    private func mergedSubscriptionUsageState(
        previous: AccountSubscriptionUsageState?,
        reported: AccountSubscriptionUsageState
    ) -> AccountSubscriptionUsageState {
        switch reported {
        case .available:
            return reported
        case .unavailable(let issue):
            guard let snapshot = previous?.snapshot else { return reported }
            return .stale(snapshot, issue)
        case .stale(let snapshot, let issue):
            return .stale(snapshot, issue)
        case .disabled, .managementKeyNotConfigured, .loading:
            return reported
        }
    }

    private func refreshableSubscriptionUsageProfiles() -> [AuthProfile] {
        authProfiles.filter { profile in
            guard isSubscriptionUsageEnabled(for: profile) else { return false }
            return !(subscriptionUsageStates[profile.id]?.stopsAutomaticPolling ?? false)
        }
    }

    private func isSubscriptionUsageEnabled(for profile: AuthProfile) -> Bool {
        guard !profile.disabled else { return false }
        return config.oauthCommandProfiles.first(where: { $0.authProfileID == profile.id })?.isEnabled ?? true
    }

    private func setSubscriptionUsageStates(
        _ state: AccountSubscriptionUsageState,
        profileIDs: Set<String>? = nil
    ) {
        let targetProfileIDs = profileIDs ?? Set(authProfiles.map(\.id))
        for profileID in targetProfileIDs {
            subscriptionUsageStates[profileID] = state
        }
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
    }

    private func scheduleSubscriptionUsagePollingIfNeeded() {
        subscriptionUsagePollingTask?.cancel()
        guard config.subscriptionUsage.isEnabled,
              subscriptionUsageKeyStore.isConfigured() else {
            return
        }

        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        let hasRefreshableAccount = subscriptionUsageStates.contains { profileID, state in
            guard enabledProfileIDs.contains(profileID) else { return false }
            switch state {
            case .available, .loading:
                return true
            case .stale, .unavailable:
                return !state.stopsAutomaticPolling
            case .disabled, .managementKeyNotConfigured:
                return false
            }
        }
        guard hasRefreshableAccount else { return }

        let hasRetriableFailure = subscriptionUsageStates.contains { profileID, state in
            guard enabledProfileIDs.contains(profileID) else { return false }
            if case let .stale(_, issue) = state {
                return !issue.stopsPolling
            }
            if case let .unavailable(issue) = state {
                return !issue.stopsPolling
            }
            return false
        }
        let delay: UInt64
        if hasRetriableFailure {
            delay = subscriptionUsageRetryDelayNanoseconds
            subscriptionUsageRetryDelayNanoseconds = min(subscriptionUsageRetryDelayNanoseconds * 2, 900_000_000_000)
        } else {
            delay = 300_000_000_000
            subscriptionUsageRetryDelayNanoseconds = 60_000_000_000
        }

        let sleep = subscriptionUsageSleep
        subscriptionUsagePollingTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.refreshSubscriptionUsage()
        }
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
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        subscriptionUsageStates = subscriptionUsageStates.filter { enabledProfileIDs.contains($0.key) }
        persistSuccessfulSubscriptionUsageSnapshots()
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
    private func setAuthProfileDisabled(_ disabled: Bool, for provider: ProviderRowState.ID) throws -> Bool {
        let providerType = oauthProviderType(for: provider)
        if let authProfileID = authProfileID(for: provider) {
            let updated = try authProfileStore.setDisabled(disabled, id: authProfileID)
            if updated || !allowsLegacyProviderWideAuthFallback(for: provider) {
                return updated
            }
        }
        guard allowsLegacyProviderWideAuthFallback(for: provider) else { return false }
        return try authProfileStore.setDisabled(disabled, for: providerType) > 0
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


    func removeInitialProvider(_ provider: ProviderRowState.ID) {
        let refreshContext = invalidateSubscriptionUsageRefreshForRemoval()
        defer { resumeSubscriptionUsageAfterRemoval(refreshContext) }
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
        let refreshContext = invalidateSubscriptionUsageRefreshForRemoval()
        defer { resumeSubscriptionUsageAfterRemoval(refreshContext) }

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

    func setProviderEnabled(_ provider: ProviderRowState.ID, enabled: Bool) {
        let providerName = oauthProviderName(oauthProviderType(for: provider))
        cancelSubscriptionUsageWork()
        let priorConfig = config
        let priorAuthDisabled = authProfiles.first { $0.id == authProfileID(for: provider) }?.disabled

        do {
            let authUpdated = try setAuthProfileDisabled(!enabled, for: provider)
            guard authUpdated else {
                refreshProfiles()
                scheduleSubscriptionUsagePollingIfNeeded()
                settingsMessage = "\(providerName) auth file was not found."
                return
            }
            authProfiles = (try? authProfileStore.profiles()) ?? authProfiles

            var updatedConfig = config
            if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
                updatedConfig.oauthCommandProfiles[index].isEnabled = enabled
            }
            try saveConfig(
                updatedConfig,
                validateShellFunctions: true,
                preservingUnavailableRoundRobinProfiles: true
            )
            refreshProfiles()
            scheduleSubscriptionUsagePollingIfNeeded()
            settingsMessage = enabled
                ? "\(providerName) account was enabled."
                : "\(providerName) account was disabled. The auth file was not deleted."
        } catch {
            config = priorConfig
            cards = ProfileCard.makeDefaultCards(config: priorConfig)
            if let priorAuthDisabled {
                _ = try? setAuthProfileDisabled(priorAuthDisabled, for: provider)
                authProfiles = (try? authProfileStore.profiles()) ?? authProfiles
                try? applyShellInstallForCurrentProfiles()
            }
            refreshProfiles()
            scheduleSubscriptionUsagePollingIfNeeded()
            settingsMessage = "\(providerName) account \(enabled ? "enable" : "disable") failed: \(error.localizedDescription)"
        }
    }

    func disconnectProvider(_ provider: ProviderRowState.ID) {
        setProviderEnabled(provider, enabled: false)
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
            } else if provider == .claudeAPI {
                updatedConfig.commands.ccapi = normalizedName
            } else if provider == .codexAPI {
                updatedConfig.commands.ccodexapi = normalizedName
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

    func roundRobinSettings(for providerType: AuthProfileType) -> RoundRobinSettingsState {
        let profile = roundRobinProfile(for: providerType)
        return roundRobinSettings(updating: profile)
    }

    func roundRobinSettings(updating profile: AppConfig.RoundRobinProfile) -> RoundRobinSettingsState {
        let options = roundRobinAccountOptions(for: profile.provider)
        let availability = roundRobinAvailability(profile: profile, options: options)
        return RoundRobinSettingsState(profile: profile, accountOptions: options, availability: availability)
    }

    func roundRobinCommandNameAvailability(profileID: String, functionName: String) async -> CommandNameAvailability {
        let normalizedName = normalizeCommandName(functionName)
        do {
            try ShellCommandNameValidator.validate(normalizedName)
            var updatedConfig = config
            if let index = updatedConfig.roundRobinProfiles.firstIndex(where: { $0.id == profileID }) {
                updatedConfig.roundRobinProfiles[index].commandName = normalizedName
                updatedConfig.roundRobinProfiles[index].isEnabled = true
            } else if profileID.hasPrefix("codex") {
                updatedConfig.roundRobinProfiles.append(AppConfig.RoundRobinProfile(id: profileID, provider: .codex, isEnabled: true, commandName: normalizedName, includedAuthProfileIDs: roundRobinProfile(for: .codex).includedAuthProfileIDs))
            } else {
                updatedConfig.roundRobinProfiles.append(AppConfig.RoundRobinProfile(id: profileID, provider: .claude, isEnabled: true, commandName: normalizedName, includedAuthProfileIDs: roundRobinProfile(for: .claude).includedAuthProfileIDs))
            }
            let activeNames = activeFunctionNames(in: updatedConfig)
            try ShellCommandNameValidator.validate(activeNames)
            try shellInstaller.validateFunctionNames([normalizedName])
            return .available
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func saveRoundRobinSettings(_ state: RoundRobinSettingsState) throws {
        var updatedConfig = config
        var profile = state.profile
        profile.commandName = normalizeCommandName(profile.commandName)
        let options = roundRobinAccountOptions(for: profile.provider)
        let validIDs = Set(options.map(\.id))
        profile.includedAuthProfileIDs = profile.includedAuthProfileIDs.filter { validIDs.contains($0) }

        guard profile.isEnabled else {
            updatedConfig.roundRobinProfiles.removeAll { $0.id == profile.id }
            try saveConfig(
                updatedConfig,
                validateShellFunctions: true,
                shellProfileValidationNames: []
            )
            settingsMessage = "Round-robin settings saved."
            return
        }

        if !roundRobinAvailability(profile: profile, options: options).canEnable {
            throw RoundRobinSettingsError.insufficientAccounts
        }
        if let index = updatedConfig.roundRobinProfiles.firstIndex(where: { $0.id == profile.id }) {
            updatedConfig.roundRobinProfiles[index] = profile
        } else {
            updatedConfig.roundRobinProfiles.append(profile)
        }
        try saveConfig(
            updatedConfig,
            validateShellFunctions: true,
            shellProfileValidationNames: [profile.commandName]
        )
        settingsMessage = "Round-robin settings saved."
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
            dangerousPermissionsEnabled: dangerousPermissionsEnabled,
            connectionMode: config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue })?.connectionMode,
            claudeRouting: config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue })?.claude
        )
    }

    func saveClaudeOAuthSettings(
        provider: ProviderRowState.ID,
        functionName: String,
        nickname: String,
        dangerousPermissionsEnabled: Bool,
        connectionMode: AppConfig.ConnectionMode? = nil,
        claudeRouting: ClaudeRouting? = nil
    ) throws {
        var updatedConfig = config
        let normalizedFunctionName = normalizeCommandName(functionName)
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
            updatedConfig.oauthCommandProfiles[index].commandName = normalizedFunctionName
            updatedConfig.oauthCommandProfiles[index].nickname = nickname
            updatedConfig.oauthCommandProfiles[index].dangerousPermissionsEnabled = dangerousPermissionsEnabled
            if let connectionMode {
                updatedConfig.oauthCommandProfiles[index].connectionMode = connectionMode
            }
            if let claudeRouting {
                updatedConfig.oauthCommandProfiles[index].claude = claudeRouting
            }
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

    func saveClaudeOAuthConnectionMode(_ mode: AppConfig.ConnectionMode, provider: ProviderRowState.ID) throws {
        guard let index = config.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) else { return }
        var updatedConfig = config
        updatedConfig.oauthCommandProfiles[index].connectionMode = mode
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    func isAPIKeyConfigured(_ key: SecretKey) -> Bool {
        (try? secretStore.get(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ?? false
    }

    func saveClaudeAPISettings(
        functionName: String,
        nickname: String = "",
        claudeRouting: ClaudeRouting? = nil,
        dangerousPermissionsEnabled: Bool,
        key: String?
    ) throws {
        let saveSettings = {
            var updatedConfig = self.config
            updatedConfig.commands.ccapi = self.normalizeCommandName(functionName)
            updatedConfig.ccapi = AppConfig.ClaudeAPI(
                claude: claudeRouting ?? updatedConfig.ccapi.claude,
                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                dangerousPermissionsEnabled: dangerousPermissionsEnabled
            )
            try self.saveConfig(
                updatedConfig,
                validateShellFunctions: true,
                shellProfileValidationNames: [updatedConfig.commands.ccapi]
            )
        }
        if let key {
            try withAPIKeyTransaction(key: .claudeAPIKey, replacement: key, operation: saveSettings)
        } else {
            try saveSettings()
        }
        requestProxyConfigurationRestart(reason: .apiKey)
    }

    func saveCodexAPISettings(
        functionName: String,
        nickname: String = "",
        codex: AppConfig.Codex,
        dangerousPermissionsEnabled: Bool,
        key: String?
    ) throws {
        let saveSettings = {
            var updatedConfig = self.config
            updatedConfig.commands.ccodexapi = self.normalizeCommandName(functionName)
            updatedConfig.codexAPI = AppConfig.CodexAPI(
                codex: CodexAPIModelOptions.normalized(codex),
                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                dangerousPermissionsEnabled: dangerousPermissionsEnabled
            )
            try self.saveConfig(
                updatedConfig,
                validateShellFunctions: true,
                shellProfileValidationNames: [updatedConfig.commands.ccodexapi]
            )
        }
        if let key {
            try withAPIKeyTransaction(key: .codexAPIKey, replacement: key, operation: saveSettings)
        } else {
            try saveSettings()
        }
        requestProxyConfigurationRestart(reason: .apiKey)
    }

    private func saveAPIKey(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIProxyManagerCommandError.emptySecret(key.rawValue)
        }
        try secretStore.set(trimmed, for: key)
    }

    private func withAPIKeyTransaction(
        key: SecretKey,
        replacement: String?,
        operation: () throws -> Void
    ) throws {
        let previousValue = try? secretStore.get(key)
        do {
            if let replacement {
                try saveAPIKey(replacement, for: key)
            } else {
                try secretStore.delete(key)
            }
            try operation()
        } catch {
            if let previousValue {
                try? secretStore.set(previousValue, for: key)
            } else {
                try? secretStore.delete(key)
            }
            try? automaticShellInstallService.apply(
                config: shellInstallConfig(in: config),
                enabledFunctions: enabledShellFunctions(in: config)
            )
            throw error
        }
    }

    private func requestProxyConfigurationRestart(reason: ProxyConfigurationRestartReason) {
        guard serverControlState.isRunning || isServerActionInProgress || serverControlState.isTransitioning else {
            return
        }
        pendingProxyConfigurationRestartReasons.insert(reason)
        guard !isServerActionInProgress, !serverControlState.isTransitioning else { return }
        guard proxyConfigurationRestartTask == nil else { return }
        proxyConfigurationRestartTask = Task { await self.restartForPendingConfigurationChanges() }
    }

    private func restartForPendingConfigurationChanges() async {
        defer { proxyConfigurationRestartTask = nil }
        guard !pendingProxyConfigurationRestartReasons.isEmpty else { return }
        let reasons = pendingProxyConfigurationRestartReasons
        pendingProxyConfigurationRestartReasons.removeAll()

        await restartServer()

        if case .error(let message) = serverControlState, reasons.contains(.fastMode) {
            settingsMessage = "Fast mode settings were saved, but CLIProxyAPI could not restart: \(message)"
        }
    }

    func removeAPIProvider(_ provider: ProviderRowState.ID) {
        let key: SecretKey = provider == .codexAPI ? .codexAPIKey : .claudeAPIKey
        do {
            try withAPIKeyTransaction(key: key, replacement: nil) {
                var updatedConfig = config
                if provider == .codexAPI {
                    updatedConfig.commands.ccodexapi = ""
                } else {
                    updatedConfig.commands.ccapi = ""
                }
                try saveConfig(updatedConfig, validateShellFunctions: true)
            }
            requestProxyConfigurationRestart(reason: .apiKey)
        } catch {
            settingsMessage = "API key removal failed: \(error.localizedDescription)"
        }
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

    func saveModels(ccodex: AppConfig.Codex) throws {
        var updatedConfig = config
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

    func refreshCPMInstallationStatus() {
        cpmInstallationStatus = cpmInstallationService.status()
    }

    func installOrUpdateCPM() async {
        guard !isCPMInstallationActionInProgress else { return }
        isCPMInstallationActionInProgress = true
        defer { isCPMInstallationActionInProgress = false }
        do {
            try await cpmInstallationService.installOrUpdate()
            refreshCPMInstallationStatus()
            settingsMessage = "cpm installed."
        } catch {
            refreshCPMInstallationStatus()
            settingsMessage = error.localizedDescription
        }
    }

    func removeCPM() async {
        guard !isCPMInstallationActionInProgress else { return }
        isCPMInstallationActionInProgress = true
        defer { isCPMInstallationActionInProgress = false }
        do {
            try await cpmInstallationService.remove()
            refreshCPMInstallationStatus()
            settingsMessage = "cpm removed."
        } catch {
            refreshCPMInstallationStatus()
            settingsMessage = error.localizedDescription
        }
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
        do {
            guard try await prepareModelServer() else {
                codexModelLoadingState = .idle
                return
            }
            await loadCodexModels()
        } catch {
            handleCodexModelLoadingFailure(error)
        }
    }

    private func prepareModelServer() async throws -> Bool {
        if serverControlState.isRunning { return true }
        guard !isServerActionInProgress else { return false }
        isServerActionInProgress = true
        defer { isServerActionInProgress = false }
        try await proxyService.start(port: config.port)
        await refreshUntilServerIsReady()
        serverControlState = serverStatus.severity == .ready ? .running : .stopped
        return serverControlState.isRunning
    }

    func loadCodexModels() async {
        codexModelLoadingState = .loadingModels
        do {
            availableCodexModelOptions = try await modelClient.codexModelOptions(port: config.port)
            codexModelLoadingState = .idle
        } catch {
            handleCodexModelLoadingFailure(error)
        }
    }

    func prepareCodexAPIModels() async {
        guard availableCodexAPIModelOptions.isEmpty else { return }
        await refreshCodexModels()
        _ = try? await codexAPIModels()
    }

    func codexAPIModels() async throws -> [CodexModelOption] {
        let models = try await modelClient.codexModelOptions(port: config.port, modelPrefix: "cpm-codex-api")
        availableCodexAPIModelOptions = models
        return models
    }

    func codexModels(for provider: ProviderRowState.ID) async throws -> [CodexModelOption] {
        guard let commandProfile = config.oauthCommandProfiles.first(where: { $0.id == provider.rawValue }) else {
            return availableCodexModelOptions
        }
        let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return availableCodexModelOptions }
        return try await modelClient.codexModelOptions(port: config.port, modelPrefix: prefix)
    }

    private func restoreClaudeModelOptions() {
        let cached = claudeModelOptionsCache.load()
        availableClaudeAPIModelOptions = cached[ProviderRowState.ID.claudeAPI.rawValue] ?? []
        availableClaudeModelOptionsByProvider = Dictionary(
            uniqueKeysWithValues: cached.compactMap { key, value in
                guard key != ProviderRowState.ID.claudeAPI.rawValue else { return nil }
                return (ProviderRowState.ID(rawValue: key), value)
            }
        )
    }

    private func persistClaudeModelOptions() {
        var cached = Dictionary(
            uniqueKeysWithValues: availableClaudeModelOptionsByProvider.map { ($0.key.rawValue, $0.value) }
        )
        if !availableClaudeAPIModelOptions.isEmpty {
            cached[ProviderRowState.ID.claudeAPI.rawValue] = availableClaudeAPIModelOptions
        }
        try? claudeModelOptionsCache.save(cached)
    }

    func prepareClaudeModels(for provider: ProviderRowState.ID) async {
        if provider == .claudeAPI {
            guard availableClaudeAPIModelOptions.isEmpty,
                  (try? await prepareModelServer()) == true else { return }
            _ = try? await claudeAPIModels()
            return
        }

        guard availableClaudeModelOptionsByProvider[provider]?.isEmpty != false,
              config.oauthCommandProfiles.contains(where: {
                  $0.id == provider.rawValue && $0.provider == .claude && $0.connectionMode == .proxy
              }),
              (try? await prepareModelServer()) == true else { return }
        _ = try? await claudeModels(for: provider)
    }

    func claudeAPIModels() async throws -> [ClaudeModelOption] {
        let models = try await modelClient.claudeModelOptions(port: config.port, modelPrefix: "cpm-claude-api")
        availableClaudeAPIModelOptions = models
        persistClaudeModelOptions()
        return models
    }

    func claudeModels(for provider: ProviderRowState.ID) async throws -> [ClaudeModelOption] {
        guard let commandProfile = config.oauthCommandProfiles.first(where: {
            $0.id == provider.rawValue && $0.provider == .claude
        }) else {
            return []
        }
        let prefix = commandProfile.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw ClaudeModelDiscoveryError.emptyModelPrefix }
        let models = try await modelClient.claudeModelOptions(port: config.port, modelPrefix: prefix)
        availableClaudeModelOptionsByProvider[provider] = models
        persistClaudeModelOptions()
        return models
    }

    func codexModels(forRoundRobinProfile profile: AppConfig.RoundRobinProfile) async throws -> [CodexModelOption] {
        let prefixes = roundRobinModelPrefixes(for: profile)
        guard let firstPrefix = prefixes.first else { return availableCodexModelOptions }
        var common = try await modelClient.codexModelOptions(port: config.port, modelPrefix: firstPrefix)

        for prefix in prefixes.dropFirst() {
            let next = try await modelClient.codexModelOptions(port: config.port, modelPrefix: prefix)
            let nextByID = Dictionary(
                next.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            common = common.compactMap { current in
                guard let other = nextByID[current.id] else { return nil }
                let supported = current.supportedReasoning.filter(other.supportedReasoning.contains)
                let defaultReasoning: AppConfig.CodexReasoning?
                if let otherDefault = other.defaultReasoning, supported.contains(otherDefault) {
                    defaultReasoning = otherDefault
                } else if let currentDefault = current.defaultReasoning, supported.contains(currentDefault) {
                    defaultReasoning = currentDefault
                } else {
                    defaultReasoning = nil
                }
                return CodexModelOption(
                    id: current.id,
                    supportedReasoning: supported,
                    defaultReasoning: defaultReasoning,
                    supportsFastMode: current.supportsFastMode && other.supportsFastMode
                )
            }
        }
        return common
    }

    private func roundRobinModelPrefixes(for profile: AppConfig.RoundRobinProfile) -> [String] {
        let commandProfilesByAuthID = commandProfilesByAuthID(in: config)
        return profile.includedAuthProfileIDs.compactMap { authProfileID in
            commandProfilesByAuthID[authProfileID]?.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func handleCodexModelLoadingFailure(_ error: Error? = nil) {
        availableCodexModelOptions = []
        let fallbackMessage = "Codex is connected, but the app could not load models through the local proxy server. Start the server and refresh, or keep the saved model."
        codexModelLoadingState = .failed(error?.localizedDescription ?? fallbackMessage)
    }

    private func normalizeCommandName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedCommands(_ commands: AppConfig.Commands) -> AppConfig.Commands {
        AppConfig.Commands(
            cc: normalizeCommandName(commands.cc),
            ccapi: normalizeCommandName(commands.ccapi),
            ccodex: normalizeCommandName(commands.ccodex),
            ccodexapi: normalizeCommandName(commands.ccodexapi)
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
        shellProfileValidationNames: [String]? = nil,
        preservingUnavailableRoundRobinProfiles: Bool = false
    ) throws {
        let persistedConfig = preservingUnavailableRoundRobinProfiles
            ? updatedConfig
            : removingUnavailableRoundRobinProfiles(from: updatedConfig)
        let updatedConfig = Self.persistedConfig(persistedConfig)
        let oldFastConfiguration = try CodexFastConfiguration(config: config)
        let newFastConfiguration = try CodexFastConfiguration(config: updatedConfig)
        let fastConfigurationChanged = oldFastConfiguration != newFastConfiguration
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
            try automaticShellInstallService.apply(config: shellInstallConfig(in: updatedConfig), enabledFunctions: enabledShellFunctions(in: updatedConfig))
            didApplyShellInstall = true
            try configStore.save(updatedConfig)
            lastPersistedConfig = updatedConfig
            rebuildOptionRows()
            rebuildProviderRows(claudeStatus: nil, codexStatus: nil)
        } catch {
            rollbackAuthProfilePrefixes(prefixRollbacks)
            if didApplyShellInstall {
                try? automaticShellInstallService.apply(config: shellInstallConfig(in: oldConfig), enabledFunctions: enabledShellFunctions(in: oldConfig))
            }
            config = oldConfig
            cards = oldCards
            rebuildOptionRows()
            rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
            throw error
        }

        if fastConfigurationChanged {
            requestProxyConfigurationRestart(reason: .fastMode)
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
        try automaticShellInstallService.apply(config: shellInstallConfig(in: config), enabledFunctions: enabledShellFunctions())
    }

    private func enabledShellFunctions() -> AutomaticShellInstallService.EnabledFunctions {
        enabledShellFunctions(in: config)
    }

    private func shellInstallConfig(in config: AppConfig) -> AppConfig {
        var installConfig = config
        let renderableIDs = Set(renderableRoundRobinProfiles(in: config).map(\.id))
        installConfig.roundRobinProfiles = config.roundRobinProfiles.filter { renderableIDs.contains($0.id) }
        return installConfig
    }

    private func enabledShellFunctions(in config: AppConfig) -> AutomaticShellInstallService.EnabledFunctions {
        let enabledProfiles = renderableOAuthCommandProfiles(in: config)
        let enabledRoundRobinProfiles = renderableRoundRobinProfiles(in: config)
        return AutomaticShellInstallService.EnabledFunctions(
            claudeOAuth: enabledProfiles.contains { $0.provider == .claude } || enabledRoundRobinProfiles.contains { $0.provider == .claude },
            codex: enabledProfiles.contains { $0.provider == .codex } || enabledRoundRobinProfiles.contains { $0.provider == .codex },
            claudeAPI: !config.commands.ccapi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            codexAPI: !config.commands.ccodexapi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private func activeFunctionNames(in config: AppConfig) -> [String] {
        let oauthNames = renderableOAuthCommandProfiles(in: config)
            .map { normalizeCommandName($0.commandName) }
        let roundRobinNames = config.roundRobinProfiles
            .filter(\.isEnabled)
            .map { normalizeCommandName($0.commandName) }
        let apiNames = [
            isAPIKeyConfigured(.claudeAPIKey) ? normalizeCommandName(config.commands.ccapi) : "",
            isAPIKeyConfigured(.codexAPIKey) ? normalizeCommandName(config.commands.ccodexapi) : ""
        ]
        return (oauthNames + roundRobinNames + apiNames).filter { !$0.isEmpty }
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

    private func renderableRoundRobinProfiles(in config: AppConfig) -> [AppConfig.RoundRobinProfile] {
        config.roundRobinProfiles.filter { isRoundRobinProfileUsable($0, in: config) }
    }

    private func removingUnavailableRoundRobinProfiles(from config: AppConfig) -> AppConfig {
        var updatedConfig = config
        updatedConfig.roundRobinProfiles = config.roundRobinProfiles.filter { isRoundRobinProfileUsable($0, in: config) }
        return updatedConfig
    }

    private func isRoundRobinProfileUsable(_ profile: AppConfig.RoundRobinProfile, in config: AppConfig) -> Bool {
        guard profile.isEnabled else { return false }
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        let commandProfilesByAuthID = commandProfilesByAuthID(in: config)
        let usableCount = profile.includedAuthProfileIDs.reduce(into: 0) { count, authProfileID in
            let commandProfile = commandProfilesByAuthID[authProfileID]
            guard let authProfile = authProfilesByID[authProfileID],
                  authProfile.type == profile.provider,
                  !authProfile.disabled,
                  commandProfile?.isEnabled != false,
                  (profile.provider != .claude || commandProfile?.connectionMode != .direct),
                  let prefix = routingPrefix(authProfile: authProfile, commandProfile: commandProfile),
                  !prefix.isEmpty else {
                return
            }
            count += 1
        }
        return usableCount >= 2
    }

    private func roundRobinProfile(for providerType: AuthProfileType) -> AppConfig.RoundRobinProfile {
        let defaultID = providerType == .codex ? "codex-default" : "claude-default"
        if var existing = config.roundRobinProfiles.first(where: { $0.id == defaultID }) {
            if providerType == .codex, existing.codex == nil {
                existing.codex = config.ccodex
            }
            return existing
        }
        return AppConfig.RoundRobinProfile(
            id: defaultID,
            provider: providerType,
            isEnabled: false,
            commandName: "",
            includedAuthProfileIDs: roundRobinAccountOptions(for: providerType).filter { $0.isEnabled && $0.hasPrefix }.map(\.id),
            codex: providerType == .codex ? config.ccodex : nil
        )
    }

    private func roundRobinAccountOptions(for providerType: AuthProfileType) -> [RoundRobinAccountOption] {
        let commandProfilesByAuthID = commandProfilesByAuthID(in: config)
        return authProfiles
            .filter { profile in
                guard profile.type == providerType else { return false }
                return providerType != .claude || commandProfilesByAuthID[profile.id]?.connectionMode != .direct
            }
            .map { profile in
                let commandProfile = commandProfilesByAuthID[profile.id]
                let prefix = routingPrefix(authProfile: profile, commandProfile: commandProfile) ?? ""
                let nickname = commandProfile?.nickname.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = nickname.isEmpty ? profile.email ?? profile.id : nickname
                let detailParts = [
                    profile.disabled || commandProfile?.isEnabled == false ? "Disabled" : "Connected",
                    prefix.isEmpty ? "No routing prefix" : "Prefix: \(prefix)"
                ]
                return RoundRobinAccountOption(
                    id: profile.id,
                    title: title,
                    detail: detailParts.joined(separator: " · "),
                    isEnabled: !profile.disabled && commandProfile?.isEnabled != false,
                    hasPrefix: !prefix.isEmpty
                )
            }
    }

    private func commandProfilesByAuthID(in config: AppConfig) -> [String: AppConfig.OAuthCommandProfile] {
        config.oauthCommandProfiles.reduce(into: [:]) { result, commandProfile in
            result[commandProfile.authProfileID] = commandProfile
        }
    }

    private func routingPrefix(authProfile: AuthProfile, commandProfile: AppConfig.OAuthCommandProfile?) -> String? {
        let commandPrefix = commandProfile?.modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !commandPrefix.isEmpty { return commandPrefix }
        let authPrefix = authProfile.prefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return authPrefix.isEmpty ? nil : authPrefix
    }

    private func roundRobinAvailability(
        profile: AppConfig.RoundRobinProfile,
        options: [RoundRobinAccountOption]
    ) -> RoundRobinAvailability {
        let enabledOptions = options.filter { $0.isEnabled }
        guard enabledOptions.count >= 2 else {
            return .insufficientProviderAccounts(count: enabledOptions.count)
        }
        let selectedOptions = enabledOptions.filter { profile.includedAuthProfileIDs.contains($0.id) }
        guard selectedOptions.count >= 2 else {
            return .insufficientSelectedAccounts(count: selectedOptions.count)
        }
        let missingPrefixIDs = selectedOptions.filter { !$0.hasPrefix }.map(\.id)
        guard missingPrefixIDs.isEmpty else {
            return .missingPrefixes(missingPrefixIDs)
        }
        return .available(count: selectedOptions.count)
    }

    private var defaultSubscriptionUsageState: AccountSubscriptionUsageState {
        config.subscriptionUsage.isEnabled ? .managementKeyNotConfigured : .disabled
    }

    private func rebuildProviderRows(claudeStatus: DiagnosticStatus?, codexStatus: DiagnosticStatus?) {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        var rows: [ProviderRowState]

        if config.oauthCommandProfiles.isEmpty {
            var usedIDs: Set<String> = []
            var firstProviderSeen: Set<AuthProfileType> = []
            rows = authProfiles.map { authProfile in
                let isDisabled = authProfile.disabled
                let enabledProfile = isDisabled ? nil : authProfile
                let diagnosticStatus = authProfile.type == .codex ? codexStatus : claudeStatus
                let fallback = authProfile.type == .codex
                    ? diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Codex OAuth profile."
                    : diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Claude OAuth profile."
                let isFirstForProvider = !firstProviderSeen.contains(authProfile.type)
                firstProviderSeen.insert(authProfile.type)
                let rowID = Self.commandProfileID(provider: authProfile.type, authProfileID: authProfile.id, preferLegacyID: isFirstForProvider, usedIDs: &usedIDs)
                return ProviderRowState(
                    id: ProviderRowState.ID(rawValue: rowID), providerType: authProfile.type,
                    authProfileID: authProfile.id, commandProfileID: rowID,
                    name: authProfile.type == .codex ? "Codex OAuth" : "Claude OAuth",
                    nickname: authProfile.type == .codex ? config.nicknames.ccodex : config.nicknames.cc,
                    functionName: authProfile.type == .codex ? config.commands.ccodex : config.commands.cc,
                    connectionTitle: isDisabled ? "Disabled" : "Connected",
                    connectionDetail: profileDetail(profile: enabledProfile ?? authProfile, fallback: fallback),
                    isConnected: enabledProfile != nil, isDisabled: isDisabled,
                    isErrored: isProviderErrored(providerType: authProfile.type, enabledProfile: enabledProfile, diagnosticStatus: diagnosticStatus),
                    accountDetailHidden: authProfile.type == .codex ? config.accountPrivacy.codexHidden : config.accountPrivacy.claudeHidden,
                    subscriptionUsageState: subscriptionUsageStates[authProfile.id] ?? defaultSubscriptionUsageState
                )
            }
        } else {
            rows = config.oauthCommandProfiles.compactMap { commandProfile in
                guard let authProfile = authProfilesByID[commandProfile.authProfileID] else { return nil }
                let isDisabled = authProfile.disabled || !commandProfile.isEnabled
                let enabledProfile = isDisabled ? nil : authProfile
                let diagnosticStatus = commandProfile.provider == .codex ? codexStatus : claudeStatus
                let fallback = commandProfile.provider == .codex
                    ? diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Codex OAuth profile."
                    : diagnosticStatus?.message ?? "Connect the bundled CLIProxyAPI Claude OAuth profile."
                return ProviderRowState(
                    id: ProviderRowState.ID(rawValue: commandProfile.id), providerType: commandProfile.provider,
                    authProfileID: commandProfile.authProfileID, commandProfileID: commandProfile.id,
                    name: commandProfile.provider == .codex ? "Codex OAuth" : "Claude OAuth",
                    nickname: commandProfile.nickname, functionName: commandProfile.commandName,
                    connectionTitle: isDisabled ? "Disabled" : "Connected",
                    connectionDetail: profileDetail(profile: enabledProfile ?? authProfile, fallback: fallback),
                    isConnected: enabledProfile != nil, isDisabled: isDisabled,
                    isErrored: isProviderErrored(providerType: commandProfile.provider, enabledProfile: enabledProfile, diagnosticStatus: diagnosticStatus),
                    accountDetailHidden: commandProfile.accountDetailHidden,
                    subscriptionUsageState: subscriptionUsageStates[authProfile.id] ?? defaultSubscriptionUsageState
                )
            }
        }

        if isAPIKeyConfigured(.claudeAPIKey) {
            rows.append(ProviderRowState(
                id: .claudeAPI, providerType: .claude, name: "Claude API Key", nickname: config.ccapi.nickname,
                functionName: config.commands.ccapi, connectionTitle: "Configured",
                connectionDetail: "CLIProxyAPI",
                isConnected: true, accountDetailHidden: true, subscriptionUsageState: .disabled,
                showsSubscriptionUsage: false
            ))
        }
        if isAPIKeyConfigured(.codexAPIKey) {
            rows.append(ProviderRowState(
                id: .codexAPI, providerType: .codex, name: "OpenAI API Key", nickname: config.codexAPI.nickname,
                functionName: config.commands.ccodexapi, connectionTitle: "Configured",
                connectionDetail: "CLIProxyAPI", isConnected: true,
                accountDetailHidden: true, subscriptionUsageState: .disabled,
                showsSubscriptionUsage: false
            ))
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
                if serverStatus.severity == .ready {
                    await refreshSubscriptionUsage()
                }
            } else {
                await refresh()
            }
            // After action completes, derive final state from the latest health.
            serverControlState = serverStatus.severity == .ready ? .running : .stopped
            if !pendingProxyConfigurationRestartReasons.isEmpty, serverControlState.isRunning {
                let reasons = pendingProxyConfigurationRestartReasons
                pendingProxyConfigurationRestartReasons.removeAll()
                do {
                    try await restartProxyAndRefresh()
                } catch {
                    let message = error.localizedDescription
                    serverControlState = .error(message)
                    if reasons.contains(.fastMode) {
                        settingsMessage = "Fast mode settings were saved, but CLIProxyAPI could not restart: \(message)"
                    }
                }
            } else if !serverControlState.isRunning {
                pendingProxyConfigurationRestartReasons.removeAll()
            }
        } catch {
            pendingProxyConfigurationRestartReasons.removeAll()
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

    private func restartProxyAndRefresh() async throws {
        try await proxyService.restart(port: config.port)
        await refreshUntilServerIsReady()
        serverControlState = serverStatus.severity == .ready ? .running : .stopped
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

import Combine
import CLIProxyManagerCore
import Foundation
#if canImport(AppKit)
import AppKit
#endif

protocol AppConfigStoring: Sendable {
    func load() throws -> AppConfig
    func loadDocument() throws -> AppConfigLoadResult
    func save(_ config: AppConfig) throws
}

extension AppConfigStoring {
    func loadDocument() throws -> AppConfigLoadResult {
        .canonical(try load())
    }
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
    func prepareCodexCredentialMigrations() throws -> [AuthProfileMigration]
    func finalizeCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) throws
    func rollbackCodexCredentialMigrations(_ migrations: [AuthProfileMigration])
    func setDisabled(_ disabled: Bool, id: String) throws -> Bool
    func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int
    func setPrefix(_ prefix: String?, id: String) throws -> Bool
    func delete(id: String) throws -> Bool
    func delete(for type: AuthProfileType) throws -> Int
}

extension AuthProfileManaging {
    func prepareCodexCredentialMigrations() throws -> [AuthProfileMigration] { [] }
    func finalizeCodexCredentialMigrations(_: [AuthProfileMigration]) throws {}
    func rollbackCodexCredentialMigrations(_: [AuthProfileMigration]) {}
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
    private enum ProxyConfigurationRestartReason: Hashable, Sendable {
        case apiKey
        case configuration
        case fastMode
    }

    private struct CodexFastConfigurationInput: Equatable {
        struct Role: Equatable {
            let model: String
            let fastModeEnabled: Bool

            init(_ role: AppConfig.CodexRole) {
                model = role.model
                fastModeEnabled = role.fastModeEnabled
            }

            var codexRole: AppConfig.CodexRole {
                .init(model: model, reasoning: .auto, fastModeEnabled: fastModeEnabled)
            }
        }

        struct Configuration: Equatable {
            let opus: Role
            let sonnet: Role
            let haiku: Role

            init(_ codex: AppConfig.Codex) {
                opus = Role(codex.opus)
                sonnet = Role(codex.sonnet)
                haiku = Role(codex.haiku)
            }

            var codex: AppConfig.Codex {
                .init(opus: opus.codexRole, sonnet: sonnet.codexRole, haiku: haiku.codexRole)
            }
        }

        let oauth: [Configuration]
        let roundRobin: [Configuration]
        let apiKeys: [Configuration]
    }

    private struct ProxyRestartReadinessError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct UsageOverlayAccountVisibilitySaveError: LocalizedError {
        let underlyingError: Error

        var errorDescription: String? {
            "Usage HUD account visibility could not be saved: \(underlyingError.localizedDescription)"
        }
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
    @Published private(set) var availableCodexAPIModelOptionsByProvider: [ProviderRowState.ID: [CodexModelOption]] = [:]
    @Published private(set) var availableClaudeAPIModelOptions: [ClaudeModelOption] = []
    @Published private(set) var availableClaudeModelOptionsByProvider: [ProviderRowState.ID: [ClaudeModelOption]] = [:]
    @Published private(set) var codexModelLoadingState: CodexModelLoadingState = .idle

    var availableCodexModels: [String] {
        availableCodexModelOptions.map(\.id)
    }

    func preferredCodexDefaultModel(in options: [CodexModelOption]) -> String? {
        options.first(where: {
            $0.id.caseInsensitiveCompare("gpt-5.6-terra") == .orderedSame
        })?.id ?? options.first?.id
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
    @Published private(set) var codexResetCreditsSnapshots: [String: CodexResetCreditsSnapshot] = [:]
    @Published private(set) var apiCostUsageStates: [String: APICostUsageState] = [:]
    @Published private(set) var isSubscriptionUsageRefreshInProgress = false
    @Published private(set) var isSubscriptionUsageReloadInProgress = false
    @Published private(set) var isAPIUsageReloadInProgress = false
    @Published private(set) var lastSuccessfulSubscriptionUsageRefreshAt: Date?
    @Published private(set) var cpmInstallationStatus: CPMInstallationStatus
    @Published private(set) var isCPMInstallationActionInProgress = false

    var canRefreshSubscriptionUsage: Bool {
        canReloadSubscriptionUsage && serverStatus.severity == .ready
    }

    var canReloadSubscriptionUsage: Bool {
        config.isSubscriptionUsageEnabled
            && subscriptionUsageKeyStore.isConfigured()
    }

    var isSubscriptionUsageReloadActionInProgress: Bool {
        isSubscriptionUsageReloadInProgress || isSubscriptionUsageRefreshInProgress
    }

    var canReloadUsage: Bool {
        config.isUsageEnabled && subscriptionUsageKeyStore.isConfigured()
    }

    var isUsageReloadActionInProgress: Bool {
        isSubscriptionUsageReloadInProgress
            || isSubscriptionUsageRefreshInProgress
            || isAPIUsageReloadInProgress
    }

    var lastSuccessfulUsageRefreshAt: Date? {
        let subscriptionDates = providerRows.compactMap { row -> Date? in
            guard row.showsUsage,
                  case let .subscription(state) = row.usageState else {
                return nil
            }
            return state.snapshot?.fetchedAt
        }
        let apiDates = providerRows.compactMap { row -> Date? in
            guard row.showsUsage,
                  case let .apiCost(state) = row.usageState else {
                return nil
            }
            return state.snapshot?.updatedAt
        }
        return (subscriptionDates + apiDates).min()
    }

    private let configStore: any AppConfigStoring
    private let shellInstaller: any ShellFunctionInstalling
    private let modelClient: any ProxyModelListing
    private let authProfileStore: any AuthProfileManaging
    private let oauthLoginService: any OAuthLoginStarting
    private let automaticShellInstallService: AutomaticShellInstallService
    private let proxyHealthClient: any ProxyHealthChecking
    private let proxyService: any ProxyServiceControlling
    private let bundledProxyReconciler: any BundledProxyReconciling
    private let claudeConnector: ClaudeConnector
    private let loginItemService: any LoginItemControlling
    private let appAppearanceService: any AppAppearanceApplying
    private let subscriptionQuotaClient: any SubscriptionQuotaFetching
    private let subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring
    private let subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching
    private let codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching
    private let codexResetCreditsNow: @Sendable () -> Date
    private let apiUsageCollector: any APIUsageCollecting
    private let claudeModelOptionsCache: any ClaudeModelOptionsCaching
    private let cpmInstallationService: any CPMInstallationManaging
    private let secretStore: any SecretStore
    private let subscriptionUsageSleep: @Sendable (UInt64) async throws -> Void
    private let serverStatusRetryDelayNanoseconds: UInt64
    private let settingsMessageAutoClearDelayNanoseconds: UInt64
    private var authProfiles: [AuthProfile] = []
    private var oauthLoginTask: Task<Void, Never>?
    private var settingsMessageAutoClearTask: Task<Void, Never>?
    private var configWriteProtectionMessage: String?
    private var applicationLaunchTask: Task<Void, Never>?
    private var applicationLaunchGeneration = 0
    private var lastClaudeStatus: DiagnosticStatus?
    private var lastCodexStatus: DiagnosticStatus?
    private var lastPersistedConfig: AppConfig
    private enum SubscriptionUsagePollingWakeReason: Equatable {
        case usage
        case resetCredits
    }
    private var subscriptionUsagePollingTask: Task<Void, Never>?
    private var subscriptionUsagePollingWakeReason: SubscriptionUsagePollingWakeReason?
    private var subscriptionUsagePollingDeadline: Date?
    private var subscriptionUsageNextUsageRefreshAt: Date?
    private var subscriptionUsageRefreshTask: Task<Void, Never>?
    private var codexResetCreditsRefreshTask: Task<Void, Never>?
    private var apiUsageReportTask: Task<Void, Never>?
    private var apiUsageLifecycleTailTask: Task<Void, Never>?
    private var apiUsageLifecycleTailID: UUID?
    private var apiUsageLifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var apiUsageLifecycleGeneration = 0
    private var acceptedAPIUsageReportIdentity: APIUsageCollectorIdentity?
    private var isPreparingAPIUsageForTermination = false
    private var apiUsageTerminationPreparationTask: Task<Void, Error>?
    private var apiUsageTerminationPreparationID: UUID?
    private var apiUsageTerminationPreparationSucceeded = false
    private var shouldRecoverAfterTerminationPreparation = false
    private enum ProxyRuntimeCertainty {
        case confirmedStopped
        case mayBeRunning
    }

    private enum SubscriptionUsageRefreshPriority: Int, Comparable, Sendable {
        case automatic
        case forced

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var isForced: Bool { self == .forced }
    }

    private enum SubscriptionUsageRefreshSource: Hashable, Sendable {
        case automatic
        case serverAction(Int)
        case oauth(UUID)
    }

    private enum SubscriptionUsageDispatchSourceAuthorization {
        case sourceOwned
        case independentHandoff
    }

    private struct SubscriptionUsageDispatchPermit: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case usage
            case resetCredits
            case combined
        }

        let id: UUID
        let kind: Kind
        let configurationGeneration: Int
        let source: SubscriptionUsageRefreshSource
        let priority: SubscriptionUsageRefreshPriority
        let port: Int
        let profiles: [AuthProfile]
        let usageProfileIDs: Set<String>
        let resetCreditsProfileIDs: Set<String>
        let attemptedAt: Date
        let usageRefreshGeneration: Int?
        let resetCreditsRefreshGeneration: Int?
    }

    private struct PendingCodexResetCreditsRefresh: Sendable {
        var priority: SubscriptionUsageRefreshPriority
        var source: SubscriptionUsageRefreshSource

        mutating func merge(
            priority newPriority: SubscriptionUsageRefreshPriority,
            source newSource: SubscriptionUsageRefreshSource
        ) {
            if newPriority >= priority {
                source = newSource
            }
            priority = max(priority, newPriority)
        }
    }

    private enum SubscriptionUsageRefreshRequestResult {
        case completed
        case deferred
    }

    private enum DeferredSubscriptionUsageRefreshReason: Hashable {
        case automatic
        case oauthFinal
        case serverActionHandback
    }

    private struct DeferredSubscriptionUsageRefresh {
        var priority: SubscriptionUsageRefreshPriority
        var reasons: Set<DeferredSubscriptionUsageRefreshReason>
    }

    private struct ConfigurationRestartFailure: Equatable, Sendable {
        let generation: Int
        let reasons: Set<ProxyConfigurationRestartReason>
        let message: String

        var ownedSettingsMessage: String? {
            guard reasons.contains(.fastMode) else { return nil }
            return "Fast mode settings were saved, but CLIProxyAPI could not restart: \(message)"
        }
    }

    private struct ProxyConfigurationDrainResult: Equatable, Sendable {
        enum Terminal: Equatable, Sendable {
            case stable(
                appliedGeneration: Int,
                reasons: Set<ProxyConfigurationRestartReason>
            )
            case failed(ConfigurationRestartFailure)
            case stopped
        }

        let terminal: Terminal
        let performedRestart: Bool

        var succeeded: Bool {
            switch terminal {
            case .stable, .stopped:
                return true
            case .failed:
                return false
            }
        }
    }

    private struct ServerActionCompletion {
        let generation: Int
        let terminal: ProxyConfigurationDrainResult.Terminal

        var succeeded: Bool {
            switch terminal {
            case .stable, .stopped:
                return true
            case .failed:
                return false
            }
        }
    }

    private struct OAuthLoginSessionState {
        enum Phase {
            case authenticating
            case reconciled
        }

        let id: UUID
        let startedDuringServerActionGeneration: Int?
        var phase: Phase = .authenticating
        var observedServerActionCompletion: ServerActionCompletion?
    }

    private struct ConfigurationWorkState {
        var generation = 0
        var nextServerActionGeneration = 0
        var activeServerActionGeneration: Int?
        var oauthRefreshOwnerSessionID: UUID?
        var lastAppliedGeneration = 0
        var lastAppliedReasons: Set<ProxyConfigurationRestartReason> = []
        var ownedRestartFailure: ConfigurationRestartFailure?
        var deferredSubscriptionUsageRefresh: DeferredSubscriptionUsageRefresh?
        var deferredCollectorUpdate = false

        mutating func queueSubscriptionUsageRefresh(
            _ priority: SubscriptionUsageRefreshPriority,
            reason: DeferredSubscriptionUsageRefreshReason
        ) {
            if var deferredSubscriptionUsageRefresh {
                deferredSubscriptionUsageRefresh.priority = max(
                    deferredSubscriptionUsageRefresh.priority,
                    priority
                )
                deferredSubscriptionUsageRefresh.reasons.insert(reason)
                self.deferredSubscriptionUsageRefresh = deferredSubscriptionUsageRefresh
            } else {
                deferredSubscriptionUsageRefresh = DeferredSubscriptionUsageRefresh(
                    priority: priority,
                    reasons: [reason]
                )
            }
        }

        mutating func removeDeferredSubscriptionUsageRefreshReason(
            _ reason: DeferredSubscriptionUsageRefreshReason
        ) {
            deferredSubscriptionUsageRefresh?.reasons.remove(reason)
            if deferredSubscriptionUsageRefresh?.reasons.isEmpty == true {
                deferredSubscriptionUsageRefresh = nil
            }
        }

        mutating func clearDeferredRefreshWork() {
            deferredSubscriptionUsageRefresh = nil
            deferredCollectorUpdate = false
        }
    }

    private var proxyRuntimeCertainty = ProxyRuntimeCertainty.mayBeRunning
    private var hasStartedAPIUsageCollector = false
    private var subscriptionUsageRefreshIsForced = false
    private var codexResetCreditsRefreshIsForced = false
    private var activeSubscriptionUsageDispatchPermit: SubscriptionUsageDispatchPermit?
    private var activeCodexResetCreditsDispatchPermit: SubscriptionUsageDispatchPermit?
    private var activeCodexResetCreditsSourceAuthorization = SubscriptionUsageDispatchSourceAuthorization.sourceOwned
    private var pendingCodexResetCreditsRefresh: PendingCodexResetCreditsRefresh?
    private var codexResetCreditsLastAttemptAt: [String: Date] = [:]
    private var codexResetCreditsInFlightProfileIDs: Set<String> = []
    private var pendingCodexResetCreditsProfileIDs: Set<String> = []
    private var codexResetCreditsRetryNotBefore: Date?
    private static let codexResetCreditsRefreshInterval: TimeInterval = 3 * 60 * 60
    private static let codexResetCreditsPreflightRetryInterval: TimeInterval = 60
    private static let maximumSubscriptionUsageSleepInterval: TimeInterval = 24 * 60 * 60
    private var oauthLoginSession: OAuthLoginSessionState?
    private var oauthLoginSessionID: UUID? { oauthLoginSession?.id }
    private var configurationWork = ConfigurationWorkState()
    private var pendingProxyConfigurationRestartReasons: Set<ProxyConfigurationRestartReason> = []
    private var proxyConfigurationRestartTask: Task<Void, Never>?
    private var serverActionWaitsForReady = false
    private var serverActionCompletionWaiters: [CheckedContinuation<ServerActionCompletion, Never>] = []
    private var subscriptionUsageRefreshGeneration = 0
    private var codexResetCreditsRefreshGeneration = 0
    private var subscriptionUsageRetryDelayNanoseconds: UInt64 = 60_000_000_000

    init(
        config: AppConfig? = nil,
        configStore: any AppConfigStoring = AppConfigStore(),
        shellInstaller: any ShellFunctionInstalling = ShellProfileInstaller(paths: ManagedPaths()),
        modelClient: any ProxyModelListing = ProxyModelClient(),
        authProfileStore: any AuthProfileManaging = AuthProfileStore(),
        oauthLoginService: (any OAuthLoginStarting)? = nil,
        automaticShellInstallService: AutomaticShellInstallService? = nil,
        proxyHealthClient: any ProxyHealthChecking = ProxyHealthClient(),
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        bundledProxyReconciler: (any BundledProxyReconciling)? = nil,
        claudeConnector: ClaudeConnector = ClaudeConnector(),
        loginItemService: any LoginItemControlling = LoginItemService(),
        appAppearanceService: any AppAppearanceApplying = AppAppearanceService(),
        subscriptionQuotaClient: any SubscriptionQuotaFetching = CLIProxyAPISubscriptionQuotaClient(),
        subscriptionUsageKeyStore: any SubscriptionUsageManagementKeyConfiguring = SubscriptionUsageManagementKeyFileStore(),
        subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching = SubscriptionUsageSnapshotCacheFileStore(),
        codexResetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching = CodexResetCreditsSnapshotCacheFileStore(),
        codexResetCreditsNow: @escaping @Sendable () -> Date = { Date() },
        apiUsageCollector: any APIUsageCollecting = APIUsageCollector(),
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
        self.bundledProxyReconciler = bundledProxyReconciler ?? BundledProxyBinary.reconciliationService()
        self.claudeConnector = claudeConnector
        self.loginItemService = loginItemService
        self.appAppearanceService = appAppearanceService
        self.subscriptionQuotaClient = subscriptionQuotaClient
        self.subscriptionUsageKeyStore = subscriptionUsageKeyStore
        self.subscriptionUsageSnapshotCache = subscriptionUsageSnapshotCache
        self.codexResetCreditsSnapshotCache = codexResetCreditsSnapshotCache
        self.codexResetCreditsNow = codexResetCreditsNow
        self.apiUsageCollector = apiUsageCollector
        self.claudeModelOptionsCache = claudeModelOptionsCache
        let resolvedCPMInstallationService = cpmInstallationService ?? CPMInstallationService()
        self.cpmInstallationService = resolvedCPMInstallationService
        self.cpmInstallationStatus = resolvedCPMInstallationService.status()
        self.secretStore = secretStore
        self.subscriptionUsageSleep = subscriptionUsageSleep
        self.serverStatusRetryDelayNanoseconds = serverStatusRetryDelayNanoseconds
        self.settingsMessageAutoClearDelayNanoseconds = settingsMessageAutoClearDelayNanoseconds
        let loadedDocument: AppConfigLoadResult
        let configLoadErrorMessage: String?
        let configWriteProtectionMessage: String?
        if let config {
            loadedDocument = .canonical(config)
            configLoadErrorMessage = nil
            configWriteProtectionMessage = nil
        } else {
            do {
                loadedDocument = try configStore.loadDocument()
                configLoadErrorMessage = nil
                configWriteProtectionMessage = nil
            } catch {
                loadedDocument = .canonical(.default)
                configLoadErrorMessage = "Config could not be loaded: \(error.localizedDescription)"
                if let storeError = error as? AppConfigStoreError,
                   case .unsupportedSchemaVersion = storeError {
                    configWriteProtectionMessage = "This config was created by a newer app version and is read-only here."
                } else {
                    configWriteProtectionMessage = nil
                }
            }
        }
        self.configWriteProtectionMessage = configWriteProtectionMessage

        var persistedConfig = Self.availableConfig(loadedDocument.config)
        if loadedDocument.requiresCanonicalRewrite {
            persistedConfig = Self.removingEmptyLegacyAPIKeyProfiles(
                from: persistedConfig,
                secretStore: secretStore
            )
        }
        let credentialMigrationResult: CodexCredentialMigrationResult
        if configLoadErrorMessage == nil {
            credentialMigrationResult = Self.applyPreparedCodexCredentialMigrations(
                to: persistedConfig,
                authProfileStore: authProfileStore,
                configStore: configStore,
                subscriptionUsageSnapshotCache: subscriptionUsageSnapshotCache,
                resetCreditsSnapshotCache: codexResetCreditsSnapshotCache
            )
        } else {
            credentialMigrationResult = CodexCredentialMigrationResult(
                config: persistedConfig,
                profiles: Result { try authProfileStore.profiles() },
                mapping: [:]
            )
        }
        persistedConfig = credentialMigrationResult.config
        var initialConfig = persistedConfig
        var migrationSaveErrorMessage: String?
        var shouldApplyInitialShellInstall = configLoadErrorMessage == nil
        switch credentialMigrationResult.profiles {
        case .success(let profiles):
            self.authProfiles = profiles
            if configLoadErrorMessage == nil {
                let reconciliation = AppConfigMigration.reconcile(
                    loadResult: AppConfigLoadResult(
                        config: persistedConfig,
                        legacyOAuthDefaults: loadedDocument.legacyOAuthDefaults,
                        requiresCanonicalRewrite: loadedDocument.requiresCanonicalRewrite
                    ),
                    authProfiles: profiles
                )
                initialConfig = reconciliation.config
                if reconciliation.shouldPersist {
                    do {
                        try configStore.save(initialConfig)
                        persistedConfig = initialConfig
                    } catch {
                        migrationSaveErrorMessage = "Config migration failed: \(error.localizedDescription)"
                    }
                }
            }
        case .failure:
            self.authProfiles = []
            shouldApplyInitialShellInstall = false
        }
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
        restoreCodexResetCreditsSnapshots()
        reconcileAuthProfilePrefixes()
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
        rebuildOptionRows()
        appAppearanceService.apply(showDockIcon: initialConfig.showDockIcon)
        appAppearanceService.apply(appearance: initialConfig.appearance)
        if let configLoadErrorMessage {
            settingsMessage = configLoadErrorMessage
        } else if let migrationSaveErrorMessage {
            settingsMessage = migrationSaveErrorMessage
        }
        if shouldApplyInitialShellInstall {
            applyInitialShellInstall()
        }
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

    func saveSubscriptionUsageMenuBarVisible(_ isVisible: Bool) throws {
        var updatedConfig = config
        updatedConfig.subscriptionUsage.showInMenuBar = isVisible
        try saveUsageDisplayConfig(updatedConfig)
    }

    func saveUsageOverlay(_ usageOverlay: AppConfig.UsageOverlay) throws {
        var updatedConfig = config
        updatedConfig.usageOverlay = usageOverlay
        try saveUsageDisplayConfig(updatedConfig)
    }

    private func saveUsageDisplayConfig(_ updatedConfig: AppConfig) throws {
        let wasEnabled = config.isUsageEnabled
        let willBeEnabled = updatedConfig.isUsageEnabled

        if !wasEnabled && willBeEnabled {
            let createdKey = try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
            do {
                try savePrivacyOnlyConfig(updatedConfig)
            } catch {
                if createdKey { try? subscriptionUsageKeyStore.deleteManagementKey() }
                throw error
            }
        } else {
            try savePrivacyOnlyConfig(updatedConfig)
            if wasEnabled && !willBeEnabled {
                let generation = invalidateAPIUsageLifecycle()
                cancelSubscriptionUsageWork()
                let cleanupError: Error?
                do {
                    try subscriptionUsageKeyStore.deleteManagementKey()
                    cleanupError = nil
                } catch {
                    cleanupError = error
                }
                setSubscriptionUsageStates(.disabled)
                clearSubscriptionUsageSnapshots()
                clearCodexResetCreditSnapshots()
                lastSuccessfulSubscriptionUsageRefreshAt = nil
                apiCostUsageStates.removeAll()
                rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
                hasStartedAPIUsageCollector = false
                let proxyCouldServeRequests = proxyRuntimeCertainty != .confirmedStopped
                let collector = apiUsageCollector
                enqueueAPIUsageLifecycle(generation: generation) { _ in
                    try? await collector.stop(
                        reason: .trackingDisabled(proxyCouldServeRequests: proxyCouldServeRequests),
                        at: Date()
                    )
                }
                requestServerRestartAfterConfigChange()
                if let cleanupError { throw cleanupError }
                return
            }
        }

        guard wasEnabled != willBeEnabled else { return }
        let generation = invalidateAPIUsageLifecycle()
        requestServerRestartAfterConfigChange()
        enqueueAPIUsageLifecycle(generation: generation) { [weak self] generation in
            await self?.performPrepareUsage(generation: generation)
        }
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
        updatedConfig.oauthCommandProfiles = config.oauthCommandProfiles
        updatedConfig.apiKeyProfiles = config.apiKeyProfiles
        let shouldDeleteManagementKey = config.isUsageEnabled || subscriptionUsageKeyStore.isConfigured()
        let shouldStopAPIUsageCollector = config.isUsageEnabled || hasStartedAPIUsageCollector
        do {
            try saveConfig(updatedConfig)
        } catch {
            settingsMessage = "Reset failed: \(error.localizedDescription)"
            return
        }

        let generation = invalidateAPIUsageLifecycle()
        var cleanupError: Error?
        if shouldDeleteManagementKey {
            cancelSubscriptionUsageWork()
            do {
                try subscriptionUsageKeyStore.deleteManagementKey()
            } catch {
                cleanupError = error
            }
        }
        setSubscriptionUsageStates(.disabled)
        clearSubscriptionUsageSnapshots()
        clearCodexResetCreditSnapshots()
        lastSuccessfulSubscriptionUsageRefreshAt = nil
        apiCostUsageStates.removeAll()
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
        hasStartedAPIUsageCollector = false
        if shouldStopAPIUsageCollector {
            let proxyCouldServeRequests = proxyRuntimeCertainty != .confirmedStopped
            let collector = apiUsageCollector
            enqueueAPIUsageLifecycle(generation: generation) { _ in
                try? await collector.stop(
                    reason: .trackingDisabled(proxyCouldServeRequests: proxyCouldServeRequests),
                    at: Date()
                )
            }
        }
        appAppearanceService.apply(showDockIcon: updatedConfig.showDockIcon)
        appAppearanceService.apply(appearance: updatedConfig.appearance)
        settingsMessage = cleanupError.map { "Reset failed: \($0.localizedDescription)" }
            ?? "Settings reset to defaults."
        requestServerRestartAfterConfigChange()
    }

    @discardableResult
    func beginApplicationLaunch(
        onComplete: @escaping @MainActor @Sendable () -> Void = {}
    ) -> Task<Void, Never> {
        applicationLaunchGeneration &+= 1
        let generation = applicationLaunchGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStartApplication(generation: generation)
            guard self.isCurrentApplicationLaunch(generation: generation) else { return }
            onComplete()
        }
        applicationLaunchTask = task
        return task
    }

    func startApplication() async {
        applicationLaunchGeneration &+= 1
        await performStartApplication(generation: applicationLaunchGeneration)
    }

    private func performStartApplication(generation: Int) async {
        guard isCurrentApplicationLaunch(generation: generation) else { return }
        await refresh()
        guard isCurrentApplicationLaunch(generation: generation) else { return }
        let wasRunning = serverControlState.isRunning
        var attemptedReconciliationRestart = false

        do {
            guard isCurrentApplicationLaunch(generation: generation) else { return }
            let result = try bundledProxyReconciler.reconcile()
            guard isCurrentApplicationLaunch(generation: generation) else { return }
            if result.didChangeBinary, wasRunning {
                attemptedReconciliationRestart = true
                guard isCurrentApplicationLaunch(generation: generation) else { return }
                if !(await restartServerAfterRequiredChange()),
                   isCurrentApplicationLaunch(generation: generation) {
                    settingsMessage = "Bundled CLIProxyAPI was installed, but the server could not be restarted: \(serverStatus.message)"
                }
                guard isCurrentApplicationLaunch(generation: generation) else { return }
            }
        } catch {
            guard isCurrentApplicationLaunch(generation: generation) else { return }
            settingsMessage = "Bundled CLIProxyAPI update failed: \(error.localizedDescription)"
        }

        guard isCurrentApplicationLaunch(generation: generation) else { return }
        await refresh()
        guard isCurrentApplicationLaunch(generation: generation) else { return }
        await prepareUsage()
        guard isCurrentApplicationLaunch(generation: generation) else { return }
        if !attemptedReconciliationRestart {
            await performAutostartIfEnabled()
        }
    }

    private func isCurrentApplicationLaunch(generation: Int) -> Bool {
        !isPreparingAPIUsageForTermination
            && !Task.isCancelled
            && generation == applicationLaunchGeneration
    }

    func openMainWindow() async {
        await refresh()
    }

    func refresh() async {
        let wasProxyReady = serverStatus.severity == .ready
        let rawServerStatus = await stableServerStatus()
        updateProxyRuntimeCertainty(from: rawServerStatus)
        let updatedServerStatus = passiveRefreshPresentationStatus(from: rawServerStatus)
        let claudeStatus = await claudeConnector.status()
        updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
        if wasProxyReady != (updatedServerStatus.severity == .ready) {
            scheduleAPIUsageCollectorUpdateIfStarted()
        }
    }

    func prepareUsage() async {
        guard !isPreparingAPIUsageForTermination else { return }
        let generation = invalidateAPIUsageLifecycle()
        let task = enqueueAPIUsageLifecycle(generation: generation) { [weak self] generation in
            await self?.performPrepareUsage(generation: generation)
        }
        await task.value
    }

    private func performPrepareUsage(generation: Int) async {
        guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
        var didRefreshUsageAfterRestart = false
        do {
            if config.isUsageEnabled {
                let createdKey = subscriptionUsageKeyStore.isConfigured()
                    ? false
                    : try subscriptionUsageKeyStore.createManagementKeyIfNeeded()
                if createdKey, serverControlState.isRunning {
                    guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
                    didRefreshUsageAfterRestart = await restartServerAfterRequiredChange()
                    guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
                }
            } else if subscriptionUsageKeyStore.isConfigured() {
                guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
                try subscriptionUsageKeyStore.deleteManagementKey()
                if serverControlState.isRunning {
                    guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
                    didRefreshUsageAfterRestart = await restartServerAfterRequiredChange()
                    guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
                }
            }
        } catch {
            settingsMessage = "Usage setup failed: \(error.localizedDescription)"
            return
        }

        guard isCurrentAPIUsageLifecycle(generation: generation) else { return }
        observeAPIUsageReportsIfNeeded()
        let configuration = apiUsageCollectorConfiguration
        let restoredReport = await apiUsageCollector.restore(configuration: configuration)
        guard isCurrentAPIUsageLifecycle(
            generation: generation,
            configuration: configuration
        ) else { return }
        acceptAPIUsageReport(
            restoredReport,
            configuration: configuration,
            generation: generation
        )
        let lifecycleReport: APIUsageCollectionReport
        if configuration.usageEnabled {
            if hasStartedAPIUsageCollector {
                lifecycleReport = await apiUsageCollector.update(configuration: configuration)
            } else {
                hasStartedAPIUsageCollector = true
                lifecycleReport = await apiUsageCollector.start(configuration: configuration)
            }
        } else {
            lifecycleReport = await apiUsageCollector.start(configuration: configuration)
            hasStartedAPIUsageCollector = false
        }
        acceptAPIUsageReport(
            lifecycleReport,
            configuration: configuration,
            generation: generation
        )
        if !didRefreshUsageAfterRestart {
            await refreshSubscriptionUsage()
        }
    }

    @discardableResult
    private func enqueueAPIUsageLifecycle(
        generation: Int,
        _ operation: @escaping @MainActor @Sendable (Int) async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let previousTask = apiUsageLifecycleTailTask
        let task = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else {
                self?.finishAPIUsageLifecycleTask(id: id)
                return
            }
            await operation(generation)
            self?.finishAPIUsageLifecycleTask(id: id)
        }
        apiUsageLifecycleTasks[id] = task
        apiUsageLifecycleTailTask = task
        apiUsageLifecycleTailID = id
        return task
    }

    private func finishAPIUsageLifecycleTask(id: UUID) {
        apiUsageLifecycleTasks[id] = nil
        if apiUsageLifecycleTailID == id {
            apiUsageLifecycleTailTask = nil
            apiUsageLifecycleTailID = nil
        }
    }

    @discardableResult
    private func invalidateAPIUsageLifecycle() -> Int {
        apiUsageLifecycleGeneration &+= 1
        acceptedAPIUsageReportIdentity = nil
        return apiUsageLifecycleGeneration
    }

    private func isCurrentAPIUsageLifecycle(
        generation: Int,
        configuration: APIUsageCollectorConfiguration? = nil
    ) -> Bool {
        guard !isPreparingAPIUsageForTermination,
              generation == apiUsageLifecycleGeneration else {
            return false
        }
        return configuration.map { $0 == apiUsageCollectorConfiguration } ?? true
    }

    private func observeAPIUsageReportsIfNeeded() {
        guard apiUsageReportTask == nil else { return }
        let collector = apiUsageCollector
        apiUsageReportTask = Task { [weak self] in
            let reports = await collector.reports()
            for await report in reports {
                guard !Task.isCancelled else { break }
                self?.applyAPIUsageReport(report)
            }
        }
    }

    private func acceptAPIUsageReport(
        _ report: APIUsageCollectionReport,
        configuration: APIUsageCollectorConfiguration,
        generation: Int
    ) {
        guard isCurrentAPIUsageLifecycle(
            generation: generation,
            configuration: configuration
        ) else { return }
        acceptedAPIUsageReportIdentity = report.identity
        applyAPIUsageReport(report)
    }

    private func applyAPIUsageReport(_ report: APIUsageCollectionReport) {
        guard config.isUsageEnabled,
              !isPreparingAPIUsageForTermination,
              report.identity == acceptedAPIUsageReportIdentity else {
            return
        }
        let enabledProfileIDs = enabledAPIUsageProfileIDs
        apiCostUsageStates = report.statesByProfileID.filter { enabledProfileIDs.contains($0.key) }
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
    }

    func beginTermination() {
        guard !isPreparingAPIUsageForTermination else { return }
        isPreparingAPIUsageForTermination = true
        applicationLaunchGeneration &+= 1
        applicationLaunchTask?.cancel()
        _ = invalidateAPIUsageLifecycle()
        apiUsageLifecycleTasks.values.forEach { $0.cancel() }
    }

    func prepareForTermination() async throws {
        beginTermination()
        shouldRecoverAfterTerminationPreparation = false
        if apiUsageTerminationPreparationSucceeded { return }

        if let task = apiUsageTerminationPreparationTask,
           let id = apiUsageTerminationPreparationID {
            try await finishTerminationPreparation(task, id: id)
            return
        }

        let launchTask = applicationLaunchTask
        let lifecycleTasks = Array(apiUsageLifecycleTasks.values)
        apiUsageLifecycleTasks.removeAll()
        apiUsageLifecycleTailTask = nil
        apiUsageLifecycleTailID = nil
        let collector = apiUsageCollector
        let id = UUID()
        let task = Task {
            try await collector.stop(reason: .applicationTermination, at: Date())
            for task in lifecycleTasks {
                await task.value
            }
            await launchTask?.value
        }
        apiUsageTerminationPreparationID = id
        apiUsageTerminationPreparationTask = task
        try await finishTerminationPreparation(task, id: id)
    }

    func cancelTerminationPreparation() {
        guard isPreparingAPIUsageForTermination else { return }
        shouldRecoverAfterTerminationPreparation = true
        if apiUsageTerminationPreparationTask == nil || apiUsageTerminationPreparationSucceeded {
            recoverAfterCancelledTermination()
        }
    }

    private func finishTerminationPreparation(
        _ task: Task<Void, Error>,
        id: UUID
    ) async throws {
        do {
            try await task.value
            guard apiUsageTerminationPreparationID == id else { return }
            applicationLaunchTask = nil
            apiUsageReportTask?.cancel()
            apiUsageReportTask = nil
            apiUsageTerminationPreparationSucceeded = true
            if shouldRecoverAfterTerminationPreparation {
                recoverAfterCancelledTermination()
            }
        } catch {
            if apiUsageTerminationPreparationID == id {
                if shouldRecoverAfterTerminationPreparation {
                    recoverAfterCancelledTermination()
                } else {
                    clearTerminationPreparationTaskState()
                }
            }
            throw error
        }
    }

    private func recoverAfterCancelledTermination() {
        resetTerminationPreparationState()
        restartAPIUsageAfterCancelledTermination()
    }

    private func restartAPIUsageAfterCancelledTermination() {
        guard config.isUsageEnabled else { return }
        observeAPIUsageReportsIfNeeded()
        let generation = invalidateAPIUsageLifecycle()
        let configuration = apiUsageCollectorConfiguration
        let collector = apiUsageCollector
        hasStartedAPIUsageCollector = true
        enqueueAPIUsageLifecycle(generation: generation) { [weak self] generation in
            guard let self,
                  self.isCurrentAPIUsageLifecycle(
                    generation: generation,
                    configuration: configuration
                  ) else { return }
            let report = await collector.start(configuration: configuration)
            self.acceptAPIUsageReport(
                report,
                configuration: configuration,
                generation: generation
            )
        }
    }

    private func clearTerminationPreparationTaskState() {
        apiUsageTerminationPreparationTask = nil
        apiUsageTerminationPreparationID = nil
        apiUsageTerminationPreparationSucceeded = false
    }

    private func resetTerminationPreparationState() {
        clearTerminationPreparationTaskState()
        shouldRecoverAfterTerminationPreparation = false
        isPreparingAPIUsageForTermination = false
    }

    private func restoreSubscriptionUsageSnapshots() {
        guard config.isSubscriptionUsageEnabled else { return }
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        let snapshots = subscriptionUsageSnapshotCache.load().filter { enabledProfileIDs.contains($0.key) }
        guard !snapshots.isEmpty else { return }

        for snapshot in snapshots.values {
            subscriptionUsageStates[snapshot.profileID] = .available(snapshot)
        }
        lastSuccessfulSubscriptionUsageRefreshAt = snapshots.values.map(\.fetchedAt).max()
    }

    private func restoreCodexResetCreditsSnapshots() {
        guard config.isSubscriptionUsageEnabled else { return }
        let enabledCodexIDs = Set(authProfiles.filter {
            $0.type == .codex && isSubscriptionUsageEnabled(for: $0)
        }.map(\.id))
        let loadedSnapshots = codexResetCreditsSnapshotCache.load()
        let now = codexResetCreditsNow()
        codexResetCreditsSnapshots = loadedSnapshots.filter {
            enabledCodexIDs.contains($0.key) && $0.value.fetchedAt <= now
        }
        if codexResetCreditsSnapshots != loadedSnapshots {
            try? codexResetCreditsSnapshotCache.save(codexResetCreditsSnapshots)
        }
    }

    private func resetCreditsProfileIDs(
        for profiles: [AuthProfile],
        force: Bool,
        now: Date
    ) -> Set<String> {
        if !force,
           let retryNotBefore = codexResetCreditsRetryNotBefore,
           now < retryNotBefore {
            return []
        }
        return Set(profiles.compactMap { profile in
            guard profile.type == .codex else { return nil }
            if force { return profile.id }
            guard !codexResetCreditsInFlightProfileIDs.contains(profile.id),
                  !pendingCodexResetCreditsProfileIDs.contains(profile.id) else { return nil }
            let reference = codexResetCreditsLastAttemptAt[profile.id]
                ?? codexResetCreditsSnapshots[profile.id]?.fetchedAt
            guard let reference else { return profile.id }
            return now.timeIntervalSince(reference) >= Self.codexResetCreditsRefreshInterval
                ? profile.id
                : nil
        })
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

    private func persistCodexResetCreditSnapshots() {
        let enabledCodexIDs = Set(authProfiles.filter {
            $0.type == .codex && isSubscriptionUsageEnabled(for: $0)
        }.map(\.id))
        let snapshots = codexResetCreditsSnapshots.filter { enabledCodexIDs.contains($0.key) }
        try? codexResetCreditsSnapshotCache.save(snapshots)
    }

    private func clearCodexResetCreditSnapshots() {
        codexResetCreditsSnapshots.removeAll()
        codexResetCreditsLastAttemptAt.removeAll()
        codexResetCreditsInFlightProfileIDs.removeAll()
        pendingCodexResetCreditsProfileIDs.removeAll()
        codexResetCreditsRetryNotBefore = nil
        try? codexResetCreditsSnapshotCache.clear()
    }

    private func removeCodexResetCreditState(for profileID: String?) {
        guard let profileID else { return }
        codexResetCreditsSnapshots.removeValue(forKey: profileID)
        codexResetCreditsLastAttemptAt.removeValue(forKey: profileID)
        codexResetCreditsInFlightProfileIDs.remove(profileID)
        pendingCodexResetCreditsProfileIDs.remove(profileID)
        persistCodexResetCreditSnapshots()
    }

    private func cancelSubscriptionUsageWork() {
        subscriptionUsageRefreshGeneration += 1
        codexResetCreditsRefreshGeneration += 1
        subscriptionUsageRefreshTask?.cancel()
        subscriptionUsageRefreshTask = nil
        codexResetCreditsRefreshTask?.cancel()
        codexResetCreditsRefreshTask = nil
        subscriptionUsageRefreshIsForced = false
        activeSubscriptionUsageDispatchPermit = nil
        configurationWork.clearDeferredRefreshWork()
        codexResetCreditsRefreshIsForced = false
        activeCodexResetCreditsDispatchPermit = nil
        activeCodexResetCreditsSourceAuthorization = .sourceOwned
        pendingCodexResetCreditsRefresh = nil
        isSubscriptionUsageRefreshInProgress = false
        subscriptionUsagePollingTask?.cancel()
        subscriptionUsagePollingTask = nil
        subscriptionUsagePollingWakeReason = nil
        subscriptionUsagePollingDeadline = nil
        subscriptionUsageNextUsageRefreshAt = nil
        subscriptionUsageRetryDelayNanoseconds = 60_000_000_000
        codexResetCreditsInFlightProfileIDs.removeAll()
        pendingCodexResetCreditsProfileIDs.removeAll()
        codexResetCreditsRetryNotBefore = nil
    }

    private struct SubscriptionUsageRemovalRefreshContext {
        let canceledActiveRefresh: Bool
        let requiresForcedRefresh: Bool
    }

    private func invalidateSubscriptionUsageRefreshForRemoval() -> SubscriptionUsageRemovalRefreshContext {
        let canceledActiveRefresh = subscriptionUsageRefreshTask != nil || codexResetCreditsRefreshTask != nil
        let requiresForcedRefresh = subscriptionUsageRefreshIsForced
            || activeSubscriptionUsageDispatchPermit?.priority == .forced
            || configurationWork.deferredSubscriptionUsageRefresh?.priority == .forced
            || codexResetCreditsRefreshIsForced
            || activeCodexResetCreditsDispatchPermit?.priority == .forced
            || pendingCodexResetCreditsRefresh?.priority == .forced
        guard canceledActiveRefresh else {
            return SubscriptionUsageRemovalRefreshContext(
                canceledActiveRefresh: false,
                requiresForcedRefresh: requiresForcedRefresh
            )
        }

        subscriptionUsageRefreshGeneration += 1
        codexResetCreditsRefreshGeneration += 1
        subscriptionUsageRefreshTask?.cancel()
        subscriptionUsageRefreshTask = nil
        codexResetCreditsRefreshTask?.cancel()
        codexResetCreditsRefreshTask = nil
        subscriptionUsageRefreshIsForced = false
        activeSubscriptionUsageDispatchPermit = nil
        configurationWork.clearDeferredRefreshWork()
        codexResetCreditsRefreshIsForced = false
        activeCodexResetCreditsDispatchPermit = nil
        activeCodexResetCreditsSourceAuthorization = .sourceOwned
        pendingCodexResetCreditsRefresh = nil
        isSubscriptionUsageRefreshInProgress = false
        subscriptionUsagePollingTask?.cancel()
        subscriptionUsagePollingTask = nil
        subscriptionUsagePollingWakeReason = nil
        subscriptionUsagePollingDeadline = nil
        subscriptionUsageNextUsageRefreshAt = nil
        codexResetCreditsInFlightProfileIDs.removeAll()
        pendingCodexResetCreditsProfileIDs.removeAll()
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

    func reloadSubscriptionUsage() async {
        guard canReloadSubscriptionUsage,
              !isSubscriptionUsageReloadActionInProgress else {
            return
        }

        isSubscriptionUsageReloadInProgress = true
        defer { isSubscriptionUsageReloadInProgress = false }

        await refresh()
        guard serverStatus.severity == .ready else { return }
        await refreshSubscriptionUsage(force: true)
    }

    func reloadUsage() async {
        guard canReloadUsage,
              !isUsageReloadActionInProgress else {
            return
        }

        isAPIUsageReloadInProgress = true
        defer { isAPIUsageReloadInProgress = false }

        await refresh()
        guard serverStatus.severity == .ready else { return }
        await refreshSubscriptionUsage(force: true)
        let configuration = apiUsageCollectorConfiguration
        let generation = apiUsageLifecycleGeneration
        let collector = apiUsageCollector
        let task = enqueueAPIUsageLifecycle(generation: generation) { [weak self] generation in
            guard let self,
                  self.isCurrentAPIUsageLifecycle(
                    generation: generation,
                    configuration: configuration
                  ) else { return }
            let report = await collector.reload(configuration: configuration)
            self.acceptAPIUsageReport(
                report,
                configuration: configuration,
                generation: generation
            )
        }
        await task.value
    }

    func refreshSubscriptionUsage(force: Bool = false) async {
        _ = await refreshSubscriptionUsage(
            force: force,
            pollingWakeReason: nil,
            source: .automatic
        )
    }

    private func queueSubscriptionUsageRefresh(
        _ priority: SubscriptionUsageRefreshPriority,
        reason: DeferredSubscriptionUsageRefreshReason
    ) {
        configurationWork.queueSubscriptionUsageRefresh(priority, reason: reason)
    }

    private func deferredSubscriptionUsageRefreshReason(
        for source: SubscriptionUsageRefreshSource
    ) -> DeferredSubscriptionUsageRefreshReason {
        switch source {
        case .automatic:
            return .automatic
        case .serverAction:
            return .serverActionHandback
        case .oauth:
            return .oauthFinal
        }
    }

    private func makeSubscriptionUsageDispatchPermit(
        kind: SubscriptionUsageDispatchPermit.Kind,
        source: SubscriptionUsageRefreshSource,
        priority: SubscriptionUsageRefreshPriority,
        profiles: [AuthProfile],
        usageProfileIDs: Set<String>,
        resetCreditsProfileIDs: Set<String>,
        attemptedAt: Date,
        usageRefreshGeneration: Int? = nil,
        resetCreditsRefreshGeneration: Int? = nil
    ) -> SubscriptionUsageDispatchPermit {
        SubscriptionUsageDispatchPermit(
            id: UUID(),
            kind: kind,
            configurationGeneration: configurationWork.generation,
            source: source,
            priority: priority,
            port: config.port,
            profiles: profiles,
            usageProfileIDs: usageProfileIDs,
            resetCreditsProfileIDs: resetCreditsProfileIDs,
            attemptedAt: attemptedAt,
            usageRefreshGeneration: usageRefreshGeneration,
            resetCreditsRefreshGeneration: resetCreditsRefreshGeneration
        )
    }

    private func isSubscriptionUsageDispatchAuthorized(
        _ permit: SubscriptionUsageDispatchPermit
    ) -> Bool {
        let allowsCompletedSourceHandoff = permit.kind == .resetCredits
            && activeCodexResetCreditsSourceAuthorization == .independentHandoff
        guard permit.configurationGeneration == configurationWork.generation,
              !configurationWorkBlocksSubscriptionUsageRefresh(
                source: permit.source,
                allowsCompletedSourceHandoff: allowsCompletedSourceHandoff
              ),
              config.port == permit.port,
              config.isSubscriptionUsageEnabled,
              subscriptionUsageKeyStore.isConfigured() else {
            return false
        }
        let requestedProfileIDs = permit.usageProfileIDs.union(permit.resetCreditsProfileIDs)
        guard Set(permit.profiles.map(\.id)) == requestedProfileIDs,
              permit.usageProfileIDs.isSubset(of: requestedProfileIDs),
              permit.resetCreditsProfileIDs.isSubset(of: requestedProfileIDs) else {
            return false
        }
        let currentProfiles = authProfiles
            .filter(isSubscriptionUsageEnabled(for:))
            .filter { requestedProfileIDs.contains($0.id) }
        guard currentProfiles == permit.profiles else { return false }

        switch permit.kind {
        case .usage, .combined:
            guard activeSubscriptionUsageDispatchPermit == permit,
                  permit.usageRefreshGeneration == subscriptionUsageRefreshGeneration else {
                return false
            }
        case .resetCredits:
            guard activeCodexResetCreditsDispatchPermit == permit,
                  permit.resetCreditsRefreshGeneration == codexResetCreditsRefreshGeneration else {
                return false
            }
        }
        return true
    }

    private func requeueSubscriptionUsageDispatch(
        priority: SubscriptionUsageRefreshPriority,
        source: SubscriptionUsageRefreshSource
    ) {
        queueSubscriptionUsageRefresh(
            priority,
            reason: deferredSubscriptionUsageRefreshReason(for: source)
        )
    }

    private func invalidateSubscriptionUsageDispatchPermit(
        _ permit: SubscriptionUsageDispatchPermit,
        requeue: Bool,
        scheduleStabilization: Bool
    ) {
        switch permit.kind {
        case .usage, .combined:
            guard activeSubscriptionUsageDispatchPermit == permit else { return }
            if requeue {
                requeueSubscriptionUsageDispatch(priority: permit.priority, source: permit.source)
            }
            activeSubscriptionUsageDispatchPermit = nil
            subscriptionUsageRefreshGeneration &+= 1
            subscriptionUsageRefreshTask?.cancel()
            subscriptionUsageRefreshTask = nil
            subscriptionUsageRefreshIsForced = false
            isSubscriptionUsageRefreshInProgress = false
            codexResetCreditsInFlightProfileIDs.subtract(permit.resetCreditsProfileIDs)
        case .resetCredits:
            guard activeCodexResetCreditsDispatchPermit == permit else { return }
            if requeue {
                requeueSubscriptionUsageDispatch(priority: permit.priority, source: permit.source)
                if let pendingCodexResetCreditsRefresh {
                    requeueSubscriptionUsageDispatch(
                        priority: pendingCodexResetCreditsRefresh.priority,
                        source: pendingCodexResetCreditsRefresh.source
                    )
                }
            }
            activeCodexResetCreditsDispatchPermit = nil
            activeCodexResetCreditsSourceAuthorization = .sourceOwned
            codexResetCreditsRefreshGeneration &+= 1
            codexResetCreditsRefreshTask?.cancel()
            codexResetCreditsRefreshTask = nil
            codexResetCreditsRefreshIsForced = false
            codexResetCreditsInFlightProfileIDs.subtract(permit.resetCreditsProfileIDs)
            pendingCodexResetCreditsRefresh = nil
            pendingCodexResetCreditsProfileIDs.removeAll()
        }
        if scheduleStabilization {
            scheduleConfigurationWorkStabilization()
        }
    }

    private func rejectSupersededSubscriptionUsageDispatch(
        _ permit: SubscriptionUsageDispatchPermit
    ) {
        invalidateSubscriptionUsageDispatchPermit(
            permit,
            requeue: true,
            scheduleStabilization: true
        )
    }

    private func invalidateSupersededSubscriptionUsageDispatches() {
        if let permit = activeSubscriptionUsageDispatchPermit,
           permit.configurationGeneration < configurationWork.generation {
            invalidateSubscriptionUsageDispatchPermit(
                permit,
                requeue: true,
                scheduleStabilization: false
            )
        }
        if let permit = activeCodexResetCreditsDispatchPermit,
           permit.configurationGeneration < configurationWork.generation {
            invalidateSubscriptionUsageDispatchPermit(
                permit,
                requeue: true,
                scheduleStabilization: false
            )
        } else if let pendingCodexResetCreditsRefresh {
            requeueSubscriptionUsageDispatch(
                priority: pendingCodexResetCreditsRefresh.priority,
                source: pendingCodexResetCreditsRefresh.source
            )
            self.pendingCodexResetCreditsRefresh = nil
            pendingCodexResetCreditsProfileIDs.removeAll()
        }
    }

    private func configurationWorkBlocksSubscriptionUsageRefresh(
        source: SubscriptionUsageRefreshSource,
        allowsCompletedSourceHandoff: Bool = false
    ) -> Bool {
        if !pendingProxyConfigurationRestartReasons.isEmpty || proxyConfigurationRestartTask != nil {
            return true
        }
        if isServerActionInProgress,
           configurationWork.activeServerActionGeneration == nil {
            return true
        }
        if let activeGeneration = configurationWork.activeServerActionGeneration,
           source != .serverAction(activeGeneration) {
            return true
        }
        if let ownerSessionID = configurationWork.oauthRefreshOwnerSessionID,
           source != .oauth(ownerSessionID) {
            return true
        }
        switch source {
        case .automatic:
            return false
        case .serverAction(let generation):
            if configurationWork.activeServerActionGeneration == generation {
                return false
            }
            return !allowsCompletedSourceHandoff
                || configurationWork.activeServerActionGeneration != nil
        case .oauth(let sessionID):
            if configurationWork.oauthRefreshOwnerSessionID == sessionID {
                return false
            }
            return !allowsCompletedSourceHandoff
                || configurationWork.oauthRefreshOwnerSessionID != nil
        }
    }

    @discardableResult
    private func drainDeferredSubscriptionUsageRefresh(
        source: SubscriptionUsageRefreshSource
    ) async -> Bool {
        guard subscriptionUsageRefreshTask == nil,
              let deferredRefresh = configurationWork.deferredSubscriptionUsageRefresh,
              !configurationWorkBlocksSubscriptionUsageRefresh(source: source) else {
            return false
        }
        configurationWork.deferredSubscriptionUsageRefresh = nil
        let result = await refreshSubscriptionUsage(
            force: deferredRefresh.priority.isForced,
            pollingWakeReason: nil,
            source: source
        )
        return result == .completed
    }

    private func refreshSubscriptionUsage(
        force: Bool,
        pollingWakeReason: SubscriptionUsagePollingWakeReason?,
        source: SubscriptionUsageRefreshSource
    ) async -> SubscriptionUsageRefreshRequestResult {
        guard config.isSubscriptionUsageEnabled else {
            configurationWork.deferredSubscriptionUsageRefresh = nil
            setSubscriptionUsageStates(.disabled)
            return .completed
        }
        guard subscriptionUsageKeyStore.isConfigured() else {
            configurationWork.deferredSubscriptionUsageRefresh = nil
            setSubscriptionUsageStates(.managementKeyNotConfigured)
            return .completed
        }
        var priority: SubscriptionUsageRefreshPriority = force ? .forced : .automatic
        if configurationWorkBlocksSubscriptionUsageRefresh(source: source)
            || subscriptionUsageRefreshTask != nil {
            queueSubscriptionUsageRefresh(
                priority,
                reason: deferredSubscriptionUsageRefreshReason(for: source)
            )
            return .deferred
        }
        if let deferredRefresh = configurationWork.deferredSubscriptionUsageRefresh {
            priority = max(priority, deferredRefresh.priority)
            configurationWork.deferredSubscriptionUsageRefresh = nil
        }
        let effectiveForce = priority.isForced

        let enabledProfiles = authProfiles.filter(isSubscriptionUsageEnabled(for:))
        let usageProfiles: [AuthProfile]
        if effectiveForce {
            usageProfiles = enabledProfiles
        } else if pollingWakeReason == .resetCredits {
            usageProfiles = []
        } else {
            usageProfiles = refreshableSubscriptionUsageProfiles()
        }
        let resetCreditsNow = codexResetCreditsNow()
        if subscriptionQuotaClient is any ConcurrentSubscriptionQuotaFetching {
            _ = startCodexResetCreditsRefreshIfNeeded(
                force: effectiveForce,
                now: resetCreditsNow,
                source: source
            )
            guard !usageProfiles.isEmpty else {
                scheduleSubscriptionUsagePollingIfNeeded()
                return .completed
            }
            await refreshSubscriptionUsageOnly(
                profiles: usageProfiles,
                force: effectiveForce,
                source: source
            )
            return .completed
        }
        let resetCreditsProfileIDs = resetCreditsProfileIDs(
            for: enabledProfiles,
            force: effectiveForce,
            now: resetCreditsNow
        )
        let usageProfileIDs = Set(usageProfiles.map(\.id))
        let requestedProfileIDs = usageProfileIDs.union(resetCreditsProfileIDs)
        let requestedProfiles = enabledProfiles.filter { requestedProfileIDs.contains($0.id) }
        guard !requestedProfiles.isEmpty else {
            scheduleSubscriptionUsagePollingIfNeeded()
            return .completed
        }

        subscriptionUsageRefreshGeneration += 1
        let generation = subscriptionUsageRefreshGeneration
        isSubscriptionUsageRefreshInProgress = true
        codexResetCreditsInFlightProfileIDs.formUnion(resetCreditsProfileIDs)
        let previousStates = subscriptionUsageStates
        if !effectiveForce {
            let unavailableProfileIDs = Set(usageProfiles.compactMap { profile -> String? in
                previousStates[profile.id]?.snapshot == nil ? profile.id : nil
            })
            if !unavailableProfileIDs.isEmpty {
                setSubscriptionUsageStates(.loading, profileIDs: unavailableProfileIDs)
            }
        }
        let permit = makeSubscriptionUsageDispatchPermit(
            kind: .combined,
            source: source,
            priority: priority,
            profiles: requestedProfiles,
            usageProfileIDs: usageProfileIDs,
            resetCreditsProfileIDs: resetCreditsProfileIDs,
            attemptedAt: resetCreditsNow,
            usageRefreshGeneration: generation
        )
        let quotaClient = subscriptionQuotaClient
        activeSubscriptionUsageDispatchPermit = permit
        let refreshTask = Task { [weak self] in
            guard let self else { return }
            guard self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            let report = await quotaClient.fetchUsage(
                port: permit.port,
                profiles: permit.profiles,
                usageProfileIDs: permit.usageProfileIDs,
                resetCreditsProfileIDs: permit.resetCreditsProfileIDs
            )
            guard !Task.isCancelled,
                  self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            self.codexResetCreditsInFlightProfileIDs.subtract(permit.resetCreditsProfileIDs)
            self.commitCodexResetCreditAttemptMetadata(
                report,
                requestedProfileIDs: permit.resetCreditsProfileIDs,
                attemptedAt: permit.attemptedAt
            )
            self.applySubscriptionUsageReport(report, for: usageProfiles, previousStates: previousStates)
            self.rebuildProviderRows(claudeStatus: self.lastClaudeStatus, codexStatus: self.lastCodexStatus)
            self.scheduleSubscriptionUsagePollingIfNeeded(didRefreshUsage: !usageProfiles.isEmpty)
        }
        subscriptionUsageRefreshTask = refreshTask
        subscriptionUsageRefreshIsForced = effectiveForce
        await refreshTask.value
        if subscriptionUsageRefreshGeneration == generation,
           activeSubscriptionUsageDispatchPermit == permit {
            activeSubscriptionUsageDispatchPermit = nil
            subscriptionUsageRefreshTask = nil
            subscriptionUsageRefreshIsForced = false
            isSubscriptionUsageRefreshInProgress = false
            _ = await drainDeferredSubscriptionUsageRefresh(source: source)
        }
        return .completed
    }

    private func refreshSubscriptionUsageOnly(
        profiles: [AuthProfile],
        force: Bool,
        source: SubscriptionUsageRefreshSource
    ) async {
        guard subscriptionUsageRefreshTask == nil else {
            queueSubscriptionUsageRefresh(
                force ? .forced : .automatic,
                reason: deferredSubscriptionUsageRefreshReason(for: source)
            )
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
        let quotaClient = subscriptionQuotaClient
        let profileIDs = Set(profiles.map(\.id))
        let permit = makeSubscriptionUsageDispatchPermit(
            kind: .usage,
            source: source,
            priority: force ? .forced : .automatic,
            profiles: profiles,
            usageProfileIDs: profileIDs,
            resetCreditsProfileIDs: [],
            attemptedAt: codexResetCreditsNow(),
            usageRefreshGeneration: generation
        )
        activeSubscriptionUsageDispatchPermit = permit
        let refreshTask = Task { [weak self] in
            guard let self else { return }
            guard self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            let report = await quotaClient.fetchUsage(
                port: permit.port,
                profiles: permit.profiles,
                usageProfileIDs: permit.usageProfileIDs,
                resetCreditsProfileIDs: permit.resetCreditsProfileIDs
            )
            guard !Task.isCancelled,
                  self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            self.applySubscriptionUsageReport(report, for: profiles, previousStates: previousStates)
            self.rebuildProviderRows(claudeStatus: self.lastClaudeStatus, codexStatus: self.lastCodexStatus)
            self.scheduleSubscriptionUsagePollingIfNeeded(didRefreshUsage: true)
        }
        subscriptionUsageRefreshTask = refreshTask
        subscriptionUsageRefreshIsForced = force
        await refreshTask.value
        guard subscriptionUsageRefreshGeneration == generation,
              activeSubscriptionUsageDispatchPermit == permit else { return }
        activeSubscriptionUsageDispatchPermit = nil
        subscriptionUsageRefreshTask = nil
        subscriptionUsageRefreshIsForced = false
        isSubscriptionUsageRefreshInProgress = false
        _ = await drainDeferredSubscriptionUsageRefresh(source: source)
    }

    @discardableResult
    private func startCodexResetCreditsRefreshIfNeeded(
        force: Bool,
        now: Date,
        source: SubscriptionUsageRefreshSource
    ) -> Task<Void, Never>? {
        guard config.isSubscriptionUsageEnabled,
              subscriptionUsageKeyStore.isConfigured() else {
            return nil
        }
        let enabledProfiles = authProfiles.filter(isSubscriptionUsageEnabled(for:))
        let profileIDs = resetCreditsProfileIDs(
            for: enabledProfiles,
            force: force,
            now: now
        )
        guard !profileIDs.isEmpty else { return nil }
        if let activeTask = codexResetCreditsRefreshTask {
            pendingCodexResetCreditsProfileIDs.formUnion(profileIDs)
            let priority: SubscriptionUsageRefreshPriority = force ? .forced : .automatic
            if var pendingCodexResetCreditsRefresh {
                pendingCodexResetCreditsRefresh.merge(priority: priority, source: source)
                self.pendingCodexResetCreditsRefresh = pendingCodexResetCreditsRefresh
            } else {
                pendingCodexResetCreditsRefresh = PendingCodexResetCreditsRefresh(
                    priority: priority,
                    source: source
                )
            }
            return activeTask
        }

        let profiles = enabledProfiles.filter { profileIDs.contains($0.id) }
        codexResetCreditsRefreshGeneration += 1
        let generation = codexResetCreditsRefreshGeneration
        codexResetCreditsInFlightProfileIDs.formUnion(profileIDs)
        let permit = makeSubscriptionUsageDispatchPermit(
            kind: .resetCredits,
            source: source,
            priority: force ? .forced : .automatic,
            profiles: profiles,
            usageProfileIDs: [],
            resetCreditsProfileIDs: profileIDs,
            attemptedAt: now,
            resetCreditsRefreshGeneration: generation
        )
        let quotaClient = subscriptionQuotaClient
        activeCodexResetCreditsSourceAuthorization = .sourceOwned
        activeCodexResetCreditsDispatchPermit = permit
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishCodexResetCreditsRefresh(permit: permit) }
            guard self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            let report = await quotaClient.fetchUsage(
                port: permit.port,
                profiles: permit.profiles,
                usageProfileIDs: permit.usageProfileIDs,
                resetCreditsProfileIDs: permit.resetCreditsProfileIDs
            )
            guard !Task.isCancelled,
                  self.isSubscriptionUsageDispatchAuthorized(permit) else {
                self.rejectSupersededSubscriptionUsageDispatch(permit)
                return
            }
            self.commitCodexResetCreditAttemptMetadata(
                report,
                requestedProfileIDs: permit.resetCreditsProfileIDs,
                attemptedAt: permit.attemptedAt
            )
            let enabledProfileIDs = Set(self.authProfiles.filter {
                self.isSubscriptionUsageEnabled(for: $0)
            }.map(\.id))
            self.applyCodexResetCreditOutcomes(
                report.resetCreditsOutcomesByProfileID,
                enabledProfileIDs: enabledProfileIDs
            )
            self.rebuildProviderRows(claudeStatus: self.lastClaudeStatus, codexStatus: self.lastCodexStatus)
        }
        codexResetCreditsRefreshIsForced = force
        codexResetCreditsRefreshTask = task
        return task
    }

    private func finishCodexResetCreditsRefresh(
        permit: SubscriptionUsageDispatchPermit
    ) {
        guard activeCodexResetCreditsDispatchPermit == permit,
              codexResetCreditsRefreshGeneration == permit.resetCreditsRefreshGeneration else {
            return
        }
        activeCodexResetCreditsDispatchPermit = nil
        activeCodexResetCreditsSourceAuthorization = .sourceOwned
        codexResetCreditsRefreshTask = nil
        codexResetCreditsRefreshIsForced = false
        codexResetCreditsInFlightProfileIDs.subtract(permit.resetCreditsProfileIDs)
        let pendingRefresh = pendingCodexResetCreditsRefresh
        pendingCodexResetCreditsRefresh = nil
        pendingCodexResetCreditsProfileIDs.removeAll()
        if let pendingRefresh {
            _ = startCodexResetCreditsRefreshIfNeeded(
                force: pendingRefresh.priority.isForced,
                now: codexResetCreditsNow(),
                source: pendingRefresh.source
            )
        }
        scheduleSubscriptionUsagePollingIfNeeded()
    }

    private func commitCodexResetCreditAttemptMetadata(
        _ report: SubscriptionUsageReport,
        requestedProfileIDs: Set<String>,
        attemptedAt: Date
    ) {
        guard !requestedProfileIDs.isEmpty else { return }
        let classifiedProfileIDs = report.resetCreditsAttemptedProfileIDs
            .union(report.resetCreditsDeferredProfileIDs)
            .intersection(requestedProfileIDs)
        for profileID in classifiedProfileIDs {
            codexResetCreditsLastAttemptAt[profileID] = attemptedAt
        }
        if classifiedProfileIDs == requestedProfileIDs {
            codexResetCreditsRetryNotBefore = nil
        } else {
            codexResetCreditsRetryNotBefore = attemptedAt.addingTimeInterval(
                Self.codexResetCreditsPreflightRetryInterval
            )
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
        applyCodexResetCreditOutcomes(
            report.resetCreditsOutcomesByProfileID,
            enabledProfileIDs: enabledProfileIDs
        )
    }

    private func applyCodexResetCreditOutcomes(
        _ outcomes: [String: CodexResetCreditsRefreshOutcome],
        enabledProfileIDs: Set<String>
    ) {
        var changed = false
        for (profileID, outcome) in outcomes where enabledProfileIDs.contains(profileID) {
            guard case let .available(snapshot) = outcome else { continue }
            codexResetCreditsSnapshots[profileID] = snapshot
            changed = true
        }
        if changed {
            persistCodexResetCreditSnapshots()
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

    private var defersSubscriptionUsagePollingForConfigurationWork: Bool {
        configurationWork.oauthRefreshOwnerSessionID != nil
            || isServerActionInProgress
            || !pendingProxyConfigurationRestartReasons.isEmpty
            || proxyConfigurationRestartTask != nil
    }

    private func scheduleSubscriptionUsagePollingIfNeeded(didRefreshUsage: Bool = false) {
        subscriptionUsagePollingTask?.cancel()
        subscriptionUsagePollingTask = nil
        subscriptionUsagePollingWakeReason = nil
        subscriptionUsagePollingDeadline = nil
        guard !defersSubscriptionUsagePollingForConfigurationWork else { return }
        guard config.isSubscriptionUsageEnabled,
              subscriptionUsageKeyStore.isConfigured() else {
            subscriptionUsageNextUsageRefreshAt = nil
            return
        }

        let now = codexResetCreditsNow()
        let enabledProfiles = authProfiles.filter(isSubscriptionUsageEnabled(for:))
        let enabledProfileIDs = Set(enabledProfiles.map(\.id))
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

        if hasRefreshableAccount {
            if didRefreshUsage || subscriptionUsageNextUsageRefreshAt == nil {
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
                let usageDelay: UInt64
                if hasRetriableFailure {
                    usageDelay = subscriptionUsageRetryDelayNanoseconds
                    subscriptionUsageRetryDelayNanoseconds = min(subscriptionUsageRetryDelayNanoseconds * 2, 900_000_000_000)
                } else {
                    usageDelay = 300_000_000_000
                    subscriptionUsageRetryDelayNanoseconds = 60_000_000_000
                }
                subscriptionUsageNextUsageRefreshAt = now.addingTimeInterval(
                    TimeInterval(usageDelay) / 1_000_000_000
                )
            }
        } else {
            subscriptionUsageNextUsageRefreshAt = nil
        }

        let resetCreditsDeadline = nextCodexResetCreditsRefreshAt(
            for: enabledProfiles,
            now: now
        )
        let wake: (reason: SubscriptionUsagePollingWakeReason, deadline: Date)
        switch (subscriptionUsageNextUsageRefreshAt, resetCreditsDeadline) {
        case let (usage?, resetCredits?) where usage <= resetCredits:
            wake = (.usage, usage)
        case let (_?, resetCredits?):
            wake = (.resetCredits, resetCredits)
        case let (usage?, nil):
            wake = (.usage, usage)
        case let (nil, resetCredits?):
            wake = (.resetCredits, resetCredits)
        case (nil, nil):
            return
        }

        let delay = nanoseconds(until: wake.deadline, now: now)
        subscriptionUsagePollingWakeReason = wake.reason
        subscriptionUsagePollingDeadline = wake.deadline
        let sleep = subscriptionUsageSleep
        subscriptionUsagePollingTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                  self.subscriptionUsagePollingWakeReason == wake.reason,
                  self.subscriptionUsagePollingDeadline == wake.deadline else {
                return
            }
            self.subscriptionUsagePollingTask = nil
            self.subscriptionUsagePollingWakeReason = nil
            self.subscriptionUsagePollingDeadline = nil
            _ = await self.refreshSubscriptionUsage(
                force: false,
                pollingWakeReason: wake.reason,
                source: .automatic
            )
        }
    }

    private func nextCodexResetCreditsRefreshAt(
        for profiles: [AuthProfile],
        now: Date
    ) -> Date? {
        guard let deadline = profiles.compactMap({ profile -> Date? in
            guard profile.type == .codex,
                  !codexResetCreditsInFlightProfileIDs.contains(profile.id),
                  !pendingCodexResetCreditsProfileIDs.contains(profile.id) else {
                return nil
            }
            let reference = codexResetCreditsLastAttemptAt[profile.id]
                ?? codexResetCreditsSnapshots[profile.id]?.fetchedAt
            guard let reference else { return now }
            return reference.addingTimeInterval(Self.codexResetCreditsRefreshInterval)
        }).min() else {
            return nil
        }
        guard let retryNotBefore = codexResetCreditsRetryNotBefore else { return deadline }
        return max(deadline, retryNotBefore)
    }

    private func nanoseconds(until deadline: Date, now: Date) -> UInt64 {
        let interval = deadline.timeIntervalSince(now)
        guard interval.isFinite else {
            return UInt64(Self.maximumSubscriptionUsageSleepInterval * 1_000_000_000)
        }
        let boundedInterval = min(
            max(0, interval),
            Self.maximumSubscriptionUsageSleepInterval
        )
        return UInt64(ceil(boundedInterval * 1_000_000_000))
    }

    /// Called once on app launch. Auto-starts the server if the user opted in.
    func performAutostartIfEnabled() async {
        guard !isPreparingAPIUsageForTermination,
              !Task.isCancelled,
              config.autostartServer,
              !serverControlState.isRunning else { return }
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
                guard await restartServerAfterRequiredChange() else {
                    settingsMessage = "CLIProxyAPI update failed: \(serverStatus.message)"
                    return
                }
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
        applyCodexCredentialMigrationsIfNeeded()
        do {
            authProfiles = try authProfileStore.profiles()
        } catch {
            rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
            return
        }
        reconcileConfigWithAuthProfiles()
        let enabledProfileIDs = Set(authProfiles.filter(isSubscriptionUsageEnabled(for:)).map(\.id))
        subscriptionUsageStates = subscriptionUsageStates.filter { enabledProfileIDs.contains($0.key) }
        persistSuccessfulSubscriptionUsageSnapshots()
        let enabledCodexIDs = Set(authProfiles.filter {
            $0.type == .codex && isSubscriptionUsageEnabled(for: $0)
        }.map(\.id))
        codexResetCreditsSnapshots = codexResetCreditsSnapshots.filter { enabledCodexIDs.contains($0.key) }
        codexResetCreditsLastAttemptAt = codexResetCreditsLastAttemptAt.filter { enabledCodexIDs.contains($0.key) }
        persistCodexResetCreditSnapshots()
        rebuildProviderRows(claudeStatus: lastClaudeStatus, codexStatus: lastCodexStatus)
    }

    func clearSettingsMessage() {
        settingsMessageAutoClearTask?.cancel()
        settingsMessageAutoClearTask = nil
        settingsMessage = nil
    }

    func canMoveAccountUp(_ id: ProviderRowState.ID) -> Bool {
        guard let index = providerRows.firstIndex(where: { $0.id == id }) else { return false }
        return index > providerRows.startIndex
    }

    func canMoveAccountDown(_ id: ProviderRowState.ID) -> Bool {
        guard let index = providerRows.firstIndex(where: { $0.id == id }) else { return false }
        return index < providerRows.index(before: providerRows.endIndex)
    }

    func setAccountVisibleInUsageOverlay(
        _ id: ProviderRowState.ID,
        isVisible: Bool
    ) throws {
        guard let row = providerRows.first(where: { $0.id == id }) else { return }
        guard row.showsInUsageOverlay != isVisible else { return }

        var updatedConfig = config
        if isVisible {
            updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == id.rawValue }
        } else if !updatedConfig.usageOverlay.hiddenAccountIDs.contains(id.rawValue) {
            updatedConfig.usageOverlay.hiddenAccountIDs.append(id.rawValue)
        }

        do {
            try savePrivacyOnlyConfig(updatedConfig)
        } catch {
            throw UsageOverlayAccountVisibilitySaveError(underlyingError: error)
        }
    }

    func moveAccountUp(_ id: ProviderRowState.ID) {
        guard let index = providerRows.firstIndex(where: { $0.id == id }), index > 0 else { return }
        moveAccount(id, before: providerRows[index - 1].id)
    }

    func moveAccountDown(_ id: ProviderRowState.ID) {
        guard let index = providerRows.firstIndex(where: { $0.id == id }),
              index + 1 < providerRows.count else { return }
        let targetID = index + 2 < providerRows.count ? providerRows[index + 2].id : nil
        moveAccount(id, before: targetID)
    }

    func moveAccount(
        _ id: ProviderRowState.ID,
        before targetID: ProviderRowState.ID?
    ) {
        if let configWriteProtectionMessage {
            settingsMessage = configWriteProtectionMessage
            return
        }
        let movedRows = AccountOrdering.moving(providerRows, id: id, before: targetID)
        guard movedRows != providerRows else { return }

        let oldRows = providerRows
        let oldConfig = config
        var updatedConfig = config
        updatedConfig.accountOrder = movedRows.map(\.id.rawValue)

        providerRows = movedRows
        config = updatedConfig

        do {
            try configStore.save(updatedConfig)
            lastPersistedConfig = updatedConfig
        } catch {
            providerRows = oldRows
            config = oldConfig
            settingsMessage = "Account order could not be saved: \(error.localizedDescription)"
        }
    }

    func startOAuthLogin(_ provider: ProviderRowState.ID) {
        startOAuthLogin(providerType: oauthProviderType(for: provider))
    }

    func startOAuthLogin(providerType: AuthProfileType) {
        guard oauthLoginTask == nil else { return }
        let sessionID = UUID()
        let provider = providerID(for: providerType)
        beginOAuthLoginSession(sessionID)
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
        let cancelledSessionID = oauthLoginSessionID
        oauthLoginTask?.cancel()
        oauthLoginTask = nil
        var releasedOwnership = false
        if let cancelledSessionID,
           oauthLoginSessionID == cancelledSessionID {
            oauthLoginSession = nil
            releasedOwnership = releaseOAuthRefreshOwnership(for: cancelledSessionID)
            configurationWork.removeDeferredSubscriptionUsageRefreshReason(.oauthFinal)
        }
        activeOAuthLoginProvider = nil
        completedOAuthLoginProvider = nil
        completedOAuthLoginIsInitialSetup = true
        isProfileLoginInProgress = false

        if let cancelledProvider {
            settingsMessage = "\(oauthProviderName(cancelledProvider)) login was cancelled."
            refreshProfiles()
        }
        if releasedOwnership {
            scheduleConfigurationWorkStabilization()
        }
    }

    private func beginOAuthLoginSession(_ sessionID: UUID) {
        let actionGeneration = serverActionWaitsForReady
            ? configurationWork.activeServerActionGeneration
            : nil
        oauthLoginSession = OAuthLoginSessionState(
            id: sessionID,
            startedDuringServerActionGeneration: actionGeneration
        )
    }

    private func markOAuthLoginReconciled(sessionID: UUID) {
        guard let session = oauthLoginSession,
              session.id == sessionID,
              case .authenticating = session.phase else { return }
        oauthLoginSession?.phase = .reconciled
        configurationWork.oauthRefreshOwnerSessionID = sessionID
        queueSubscriptionUsageRefresh(.automatic, reason: .oauthFinal)
    }

    private func handOffCodexResetCreditsSourceAuthorizationIfNeeded(
        for source: SubscriptionUsageRefreshSource
    ) {
        guard activeCodexResetCreditsDispatchPermit?.source == source else { return }
        activeCodexResetCreditsSourceAuthorization = .independentHandoff
    }

    @discardableResult
    private func releaseOAuthRefreshOwnership(for sessionID: UUID) -> Bool {
        guard configurationWork.oauthRefreshOwnerSessionID == sessionID else { return false }
        configurationWork.oauthRefreshOwnerSessionID = nil
        return true
    }

    func connectProvider(_ provider: ProviderRowState.ID) async {
        guard oauthLoginTask == nil, isProfileLoginInProgress == false else { return }
        let providerType = oauthProviderType(for: provider)
        let sessionID = UUID()
        beginOAuthLoginSession(sessionID)
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
            _ = releaseOAuthRefreshOwnership(for: sessionID)
            if oauthLoginSessionID == sessionID {
                isProfileLoginInProgress = false
                activeOAuthLoginProvider = nil
                oauthLoginTask = nil
                oauthLoginSession = nil
            }
            scheduleConfigurationWorkStabilization()
        }

        let beforeProfiles = authProfiles
        let loginProvider: OAuthLoginProvider = providerType == .codex ? .codex : .claude
        let providerName = oauthProviderName(providerType)

        do {
            try await oauthLoginService.login(provider: loginProvider, port: config.port)
            try Task.checkCancellation()
            guard oauthLoginSessionID == sessionID else { return }
            applyCodexCredentialMigrationsIfNeeded()
            let completedID = reconcileOAuthLoginCompletion(providerType: providerType, beforeProfiles: beforeProfiles)
            refreshProfiles()
            markOAuthLoginReconciled(sessionID: sessionID)

            if oauthLoginSession?.observedServerActionCompletion?.succeeded == false {
                preserveOAuthConfigurationWorkAfterFailure(sessionID: sessionID)
                return
            }

            let pendingWorkSucceeded = await waitForPendingProxyConfigurationWork()
            try Task.checkCancellation()
            guard oauthLoginSessionID == sessionID else { return }
            guard pendingWorkSucceeded else {
                preserveOAuthConfigurationWorkAfterFailure(sessionID: sessionID)
                return
            }

            if serverStatus.severity == .ready {
                _ = await refreshSubscriptionUsage(
                    force: false,
                    pollingWakeReason: nil,
                    source: .oauth(sessionID)
                )
                try Task.checkCancellation()
                guard oauthLoginSessionID == sessionID else { return }
                if configurationWork.deferredCollectorUpdate {
                    configurationWork.deferredCollectorUpdate = false
                    scheduleAPIUsageCollectorUpdateIfStarted()
                }
            }
            handOffCodexResetCreditsSourceAuthorizationIfNeeded(for: .oauth(sessionID))
            _ = releaseOAuthRefreshOwnership(for: sessionID)
            completedOAuthLoginProvider = completedID
            completedOAuthLoginIsInitialSetup = isInitialSetup
            settingsMessage = "\(providerName) connection was updated."
        } catch is CancellationError {
            guard oauthLoginSessionID == sessionID else { return }
            let releasedOwnership = releaseOAuthRefreshOwnership(for: sessionID)
            configurationWork.removeDeferredSubscriptionUsageRefreshReason(.oauthFinal)
            settingsMessage = "\(providerName) login was cancelled."
            refreshProfiles()
            if releasedOwnership {
                await stabilizeConfigurationWorkIfPossible()
            }
        } catch {
            guard oauthLoginSessionID == sessionID else { return }
            _ = releaseOAuthRefreshOwnership(for: sessionID)
            settingsMessage = "\(providerName) login failed: \(error.localizedDescription)"
            refreshProfiles()
        }
    }

    private func preserveOAuthConfigurationWorkAfterFailure(sessionID: UUID) {
        guard oauthLoginSessionID == sessionID else { return }
        requestProxyConfigurationRestart(reason: .configuration)
        queueSubscriptionUsageRefresh(.automatic, reason: .oauthFinal)
        _ = releaseOAuthRefreshOwnership(for: sessionID)
    }

    private func reconcileOAuthLoginCompletion(providerType: AuthProfileType, beforeProfiles: [AuthProfile]) -> ProviderRowState.ID {
        let beforeIDs = Set(beforeProfiles.map(\.id))
        let candidates = authProfiles.filter { $0.type == providerType }
        let selectedProfile = candidates.first(where: { !beforeIDs.contains($0.id) }) ?? candidates.first
        guard let selectedProfile else { return providerID(for: providerType) }

        var updatedConfig = AppConfigMigration.reconcile(
            loadResult: .canonical(config),
            authProfiles: authProfiles
        ).config
        if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.authProfileID == selectedProfile.id }) {
            updatedConfig.oauthCommandProfiles[index].isEnabled = true
        }
        enableAuthProfile(selectedProfile)
        let completedID = updatedConfig.oauthCommandProfiles.first(where: { $0.authProfileID == selectedProfile.id })?.id ?? selectedProfile.type.rawValue
        try? saveConfig(updatedConfig)
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
        let authProfileID = authProfileID(for: provider)
        do {
            let deleted = try removeAuthProfile(for: provider)
            if deleted {
                removeCodexResetCreditState(for: authProfileID)
            }
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
        let authProfileID = authProfileID(for: provider)

        do {
            let deleted = try removeAuthProfile(for: provider)
            if deleted {
                removeCodexResetCreditState(for: authProfileID)
            }
            try resetProviderSettings(provider)
            refreshProfiles()
            settingsMessage = deleted
                ? "\(providerName) account was removed."
                : "\(providerName) auth file was not found."
        } catch {
            refreshProfiles()
            settingsMessage = "\(providerName) account removal failed: \(error.localizedDescription)"
        }
    }

    func setProviderEnabled(_ provider: ProviderRowState.ID, enabled: Bool) {
        let providerName = oauthProviderName(oauthProviderType(for: provider))
        cancelSubscriptionUsageWork()
        let priorConfig = config
        let authProfileID = authProfileID(for: provider)
        let priorAuthDisabled = authProfiles.first { $0.id == authProfileID }?.disabled

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
            if !enabled {
                removeCodexResetCreditState(for: authProfileID)
            }
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

        settingsMessage = "Account privacy update failed: command profile was not found."
    }

    func commandNameAvailability(provider: ProviderRowState.ID, functionName: String) async -> CommandNameAvailability {
        let normalizedName = normalizeCommandName(functionName)
        do {
            try ShellCommandNameValidator.validate(normalizedName)
            var updatedConfig = config
            if let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
                updatedConfig.oauthCommandProfiles[index].commandName = normalizedName
            } else if let index = updatedConfig.apiKeyProfiles.firstIndex(where: { $0.id == provider.rawValue }) {
                updatedConfig.apiKeyProfiles[index].commandName = normalizedName
            } else {
                let providerType = provider.inferredProviderType
                let draft = AppConfig.APIKeyProfile(
                    id: provider.rawValue,
                    provider: providerType,
                    secretReference: SecretReference.apiKeyProfile(provider.rawValue)
                        ?? (providerType == .claude ? .claudeAPIKey : .codexAPIKey),
                    commandName: normalizedName
                )
                updatedConfig.apiKeyProfiles.append(draft)
            }
            try ShellCommandNameValidator.validate(activeFunctionNames(in: updatedConfig))
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
        guard let claudeProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.claude }) else {
            throw CLIProxyManagerCommandError.prerequisite("Claude command profile was not found.")
        }
        try saveClaudeOAuthSettings(
            provider: ProviderRowState.ID(rawValue: claudeProfile.id),
            functionName: functionName,
            nickname: claudeProfile.nickname,
            dangerousPermissionsEnabled: claudeProfile.dangerousPermissionsEnabled
        )
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
        guard let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) else {
            throw CLIProxyManagerCommandError.prerequisite("Claude command profile was not found.")
        }
        updatedConfig.oauthCommandProfiles[index].commandName = normalizedFunctionName
        updatedConfig.oauthCommandProfiles[index].nickname = nickname
        updatedConfig.oauthCommandProfiles[index].dangerousPermissionsEnabled = dangerousPermissionsEnabled
        if let connectionMode {
            updatedConfig.oauthCommandProfiles[index].connectionMode = connectionMode
        }
        if let claudeRouting {
            updatedConfig.oauthCommandProfiles[index].claude = claudeRouting
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

    func apiKeyProfile(id: String) -> AppConfig.APIKeyProfile? {
        if let profile = config.apiKeyProfiles.first(where: { $0.id == id }) {
            return profile
        }
        guard id == "claude-api" || id == "codex-api" else { return nil }
        let provider: AuthProfileType = id == "claude-api" ? .claude : .codex
        let legacyProfile = AppConfig.APIKeyProfile.legacy(provider: provider)
        return isAPIKeyConfigured(legacyProfile.secretReference) ? legacyProfile : nil
    }

    func newAPIKeyProfile(provider: AuthProfileType) -> AppConfig.APIKeyProfile {
        .new(provider: provider)
    }

    func isAPIKeyConfigured(_ key: SecretReference) -> Bool {
        (try? secretStore.get(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ?? false
    }

    func isAPIKeyConfigured(profileID: String) -> Bool {
        guard let profile = apiKeyProfile(id: profileID) else { return false }
        return isAPIKeyConfigured(profile.secretReference)
    }

    func saveClaudeAPISettings(
        profileID: String = "claude-api",
        secretReference: SecretReference = .claudeAPIKey,
        functionName: String,
        nickname: String = "",
        claudeRouting: ClaudeRouting? = nil,
        dangerousPermissionsEnabled: Bool,
        key: String?
    ) throws {
        let existing = apiKeyProfile(id: profileID)
        let profile = AppConfig.APIKeyProfile(
            id: profileID,
            provider: .claude,
            secretReference: existing?.secretReference ?? secretReference,
            commandName: normalizeCommandName(functionName),
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            dangerousPermissionsEnabled: dangerousPermissionsEnabled,
            claude: claudeRouting ?? existing?.effectiveClaudeRouting ?? .automatic
        )
        try saveAPIKeyProfile(profile, replacementKey: key)
    }

    func saveCodexAPISettings(
        profileID: String = "codex-api",
        secretReference: SecretReference = .codexAPIKey,
        functionName: String,
        nickname: String = "",
        codex: AppConfig.Codex,
        dangerousPermissionsEnabled: Bool,
        key: String?
    ) throws {
        let existing = apiKeyProfile(id: profileID)
        let profile = AppConfig.APIKeyProfile(
            id: profileID,
            provider: .codex,
            secretReference: existing?.secretReference ?? secretReference,
            commandName: normalizeCommandName(functionName),
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            dangerousPermissionsEnabled: dangerousPermissionsEnabled,
            codex: CodexAPIModelOptions.normalized(codex)
        )
        try saveAPIKeyProfile(profile, replacementKey: key)
    }

    private func saveAPIKeyProfile(
        _ profile: AppConfig.APIKeyProfile,
        replacementKey: String?
    ) throws {
        let isNewProfile = apiKeyProfile(id: profile.id) == nil
        if isNewProfile,
           replacementKey == nil,
           profile.id != "claude-api",
           profile.id != "codex-api" {
            throw CLIProxyManagerCommandError.prerequisite("An API key is required for a new profile.")
        }
        let saveSettings = {
            var updatedConfig = self.config
            if let index = updatedConfig.apiKeyProfiles.firstIndex(where: { $0.id == profile.id }) {
                updatedConfig.apiKeyProfiles[index] = profile
            } else {
                updatedConfig.apiKeyProfiles.append(profile)
            }
            try self.saveConfig(
                updatedConfig,
                validateShellFunctions: true,
                shellProfileValidationNames: [profile.commandName]
            )
        }
        if let replacementKey {
            let credentialChanged = try withAPIKeyTransaction(
                key: profile.secretReference,
                replacement: replacementKey,
                operation: saveSettings
            )
            if credentialChanged || isNewProfile {
                requestProxyConfigurationRestart(reason: .apiKey)
                scheduleAPIUsageCollectorUpdateIfStarted()
            }
        } else {
            try saveSettings()
        }
    }

    private func saveAPIKey(_ value: String, for key: SecretReference) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIProxyManagerCommandError.emptySecret(key.rawValue)
        }
        try secretStore.set(trimmed, for: key)
    }

    private func withAPIKeyTransaction(
        key: SecretReference,
        replacement: String?,
        operation: () throws -> Void
    ) throws -> Bool {
        let previousValue: String?
        do {
            previousValue = try secretStore.get(key)
        } catch SecretStoreError.missingSecret {
            previousValue = nil
        } catch {
            throw error
        }
        let normalizedReplacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialChanged = normalizedReplacement != previousValue
        do {
            if let replacement {
                try saveAPIKey(replacement, for: key)
            } else {
                try secretStore.delete(key)
            }
            try operation()
            return credentialChanged
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
        let shouldRetainForExplicitRecovery: Bool
        if case .error = serverControlState {
            shouldRetainForExplicitRecovery = true
        } else {
            shouldRetainForExplicitRecovery = false
        }
        guard serverControlState.isRunning
            || isServerActionInProgress
            || serverControlState.isTransitioning
            || shouldRetainForExplicitRecovery else {
            return
        }
        configurationWork.generation &+= 1
        invalidateSupersededSubscriptionUsageDispatches()
        pendingProxyConfigurationRestartReasons.insert(reason)
        schedulePendingProxyConfigurationRestartIfNeeded()
    }

    private func requestServerRestartAfterConfigChange() {
        requestProxyConfigurationRestart(reason: .configuration)
    }

    private func restartForPendingConfigurationChanges() async {
        defer {
            proxyConfigurationRestartTask = nil
            schedulePendingProxyConfigurationRestartIfNeeded()
            scheduleConfigurationWorkStabilization()
        }
        _ = await drainPendingProxyConfigurationRestarts()
    }

    private func drainPendingProxyConfigurationRestarts() async -> ProxyConfigurationDrainResult {
        var performedRestart = false
        while !pendingProxyConfigurationRestartReasons.isEmpty, serverControlState.isRunning {
            performedRestart = true
            let reasons = pendingProxyConfigurationRestartReasons
            let attemptedGeneration = configurationWork.generation
            pendingProxyConfigurationRestartReasons.removeAll()
            do {
                try await restartProxyAndRefresh()
                markProxyConfigurationGenerationApplied(
                    attemptedGeneration,
                    reasons: reasons
                )
            } catch {
                let failure = ConfigurationRestartFailure(
                    generation: attemptedGeneration,
                    reasons: reasons,
                    message: error.localizedDescription
                )
                let hasNewerExplicitWork = configurationWork.generation > attemptedGeneration
                    && !pendingProxyConfigurationRestartReasons.isEmpty
                guard !hasNewerExplicitWork else {
                    serverControlState = .running
                    continue
                }
                pendingProxyConfigurationRestartReasons.formUnion(reasons)
                handleProxyConfigurationRestartFailure(failure)
                return ProxyConfigurationDrainResult(
                    terminal: .failed(failure),
                    performedRestart: performedRestart
                )
            }
        }
        if proxyRuntimeCertainty == .confirmedStopped {
            pendingProxyConfigurationRestartReasons.removeAll()
            return ProxyConfigurationDrainResult(
                terminal: .stopped,
                performedRestart: performedRestart
            )
        }
        if pendingProxyConfigurationRestartReasons.isEmpty,
           serverStatus.severity == .ready,
           serverControlState.isRunning {
            return ProxyConfigurationDrainResult(
                terminal: .stable(
                    appliedGeneration: configurationWork.lastAppliedGeneration,
                    reasons: configurationWork.lastAppliedReasons
                ),
                performedRestart: performedRestart
            )
        }
        let failure = configurationWork.ownedRestartFailure ?? ConfigurationRestartFailure(
            generation: configurationWork.generation,
            reasons: pendingProxyConfigurationRestartReasons,
            message: serverStatus.message.isEmpty ? "Could not connect to the server." : serverStatus.message
        )
        return ProxyConfigurationDrainResult(
            terminal: .failed(failure),
            performedRestart: performedRestart
        )
    }

    private func schedulePendingProxyConfigurationRestartIfNeeded() {
        guard proxyConfigurationRestartTask == nil,
              !pendingProxyConfigurationRestartReasons.isEmpty,
              serverControlState.isRunning,
              !isServerActionInProgress,
              !serverControlState.isTransitioning else { return }
        proxyConfigurationRestartTask = Task { await self.restartForPendingConfigurationChanges() }
    }

    private func scheduleConfigurationWorkStabilization() {
        Task { [weak self] in
            await self?.stabilizeConfigurationWorkIfPossible()
        }
    }

    private func stabilizeConfigurationWorkIfPossible() async {
        guard !configurationWorkBlocksSubscriptionUsageRefresh(source: .automatic),
              serverStatus.severity == .ready,
              serverControlState.isRunning else {
            return
        }
        _ = await drainDeferredSubscriptionUsageRefresh(source: .automatic)
        guard !configurationWorkBlocksSubscriptionUsageRefresh(source: .automatic),
              serverStatus.severity == .ready,
              serverControlState.isRunning else {
            return
        }
        if configurationWork.deferredCollectorUpdate {
            configurationWork.deferredCollectorUpdate = false
            scheduleAPIUsageCollectorUpdateIfStarted()
        }
        scheduleSubscriptionUsagePollingIfNeeded()
    }

    private func handleProxyConfigurationRestartFailure(
        _ failure: ConfigurationRestartFailure
    ) {
        configurationWork.ownedRestartFailure = failure
        updateStatuses(
            serverStatus: DiagnosticStatus(
                severity: .error,
                title: "Failed to restart CLIProxyAPI",
                message: failure.message
            ),
            claudeStatus: nil
        )
        serverControlState = .error(failure.message)
        if let failureMessage = failure.ownedSettingsMessage {
            settingsMessage = failureMessage
        }
    }

    private func markProxyConfigurationGenerationApplied(
        _ generation: Int,
        reasons: Set<ProxyConfigurationRestartReason>
    ) {
        if generation >= configurationWork.lastAppliedGeneration {
            configurationWork.lastAppliedGeneration = generation
            configurationWork.lastAppliedReasons = reasons
        }
        guard let ownedFailure = configurationWork.ownedRestartFailure,
              ownedFailure.generation <= generation else {
            return
        }
        if let ownedMessage = ownedFailure.ownedSettingsMessage,
           settingsMessage == ownedMessage {
            settingsMessage = nil
        }
        configurationWork.ownedRestartFailure = nil
    }

    func removeAPIProvider(_ provider: ProviderRowState.ID) {
        let profile = apiKeyProfile(id: provider.rawValue)
            ?? availableAPIKeyProfiles(in: config).first { $0.id == provider.rawValue }
        guard let profile else {
            settingsMessage = "API key removal failed: profile was not found."
            return
        }
        do {
            _ = try withAPIKeyTransaction(
                key: profile.secretReference,
                replacement: nil
            ) {
                var updatedConfig = config
                updatedConfig.apiKeyProfiles.removeAll { $0.id == profile.id }
                updatedConfig.accountOrder.removeAll { $0 == profile.id }
                updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == profile.id }
                try saveConfig(updatedConfig, validateShellFunctions: true)
            }
            availableClaudeModelOptionsByProvider.removeValue(forKey: provider)
            availableCodexAPIModelOptionsByProvider.removeValue(forKey: provider)
            persistClaudeModelOptions()
            requestProxyConfigurationRestart(reason: .apiKey)
            scheduleAPIUsageCollectorUpdateIfStarted()
        } catch {
            settingsMessage = "API key removal failed: \(error.localizedDescription)"
        }
    }

    func saveCodexSettings(functionName: String, codex: AppConfig.Codex) throws {
        guard let commandProfile = config.oauthCommandProfiles.first(where: { $0.provider == AuthProfileType.codex }) else {
            throw CLIProxyManagerCommandError.prerequisite("Codex command profile was not found.")
        }
        try saveCodexSettings(
            provider: ProviderRowState.ID(rawValue: commandProfile.id),
            functionName: functionName,
            nickname: commandProfile.nickname,
            codex: codex,
            dangerousPermissionsEnabled: commandProfile.dangerousPermissionsEnabled
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
        guard let index = updatedConfig.oauthCommandProfiles.firstIndex(where: { $0.id == provider.rawValue }) else {
            throw CLIProxyManagerCommandError.prerequisite("Codex command profile was not found.")
        }
        updatedConfig.oauthCommandProfiles[index].commandName = normalizedFunctionName
        updatedConfig.oauthCommandProfiles[index].nickname = nickname
        updatedConfig.oauthCommandProfiles[index].codex = codex
        updatedConfig.oauthCommandProfiles[index].dangerousPermissionsEnabled = dangerousPermissionsEnabled
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
        scheduleAPIUsageCollectorUpdateIfStarted()
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
        guard !codexModelLoadingState.isLoading else { return }
        await waitForConfigurationRestartIfNeeded()
        guard !isServerActionInProgress else { return }

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
        serverControlState = .starting
        defer {
            isServerActionInProgress = false
            schedulePendingProxyConfigurationRestartIfNeeded()
        }
        do {
            try await proxyService.start(port: config.port)
            await refreshUntilServerIsReady()
            serverControlState = serverStatus.severity == .ready ? .running : .stopped
            if serverControlState.isRunning {
                _ = await drainPendingProxyConfigurationRestarts()
            } else {
                pendingProxyConfigurationRestartReasons.removeAll()
            }
            return serverControlState.isRunning
        } catch {
            pendingProxyConfigurationRestartReasons.removeAll()
            throw error
        }
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

    func prepareCodexAPIModels(for provider: ProviderRowState.ID = .codexAPI) async {
        guard availableCodexAPIModelOptionsByProvider[provider]?.isEmpty != false else { return }
        _ = try? await refreshCodexAPIModels(for: provider)
    }

    func refreshCodexAPIModels(
        for provider: ProviderRowState.ID = .codexAPI
    ) async throws -> [CodexModelOption] {
        await waitForConfigurationRestartIfNeeded()
        guard !isServerActionInProgress else {
            return availableCodexAPIModelOptionsByProvider[provider] ?? []
        }

        if !serverControlState.isRunning {
            codexModelLoadingState = .startingServer
            do {
                guard try await prepareModelServer() else {
                    codexModelLoadingState = .idle
                    return availableCodexAPIModelOptionsByProvider[provider] ?? []
                }
            } catch {
                codexModelLoadingState = .failed(error.localizedDescription)
                throw error
            }
        }

        codexModelLoadingState = .loadingModels
        do {
            let models = try await codexAPIModels(for: provider)
            codexModelLoadingState = .idle
            return models
        } catch {
            codexModelLoadingState = .failed(error.localizedDescription)
            throw error
        }
    }

    func codexAPIModels(for provider: ProviderRowState.ID = .codexAPI) async throws -> [CodexModelOption] {
        let profile = apiKeyProfile(id: provider.rawValue)
            ?? (provider == .codexAPI ? .legacy(provider: .codex) : nil)
        guard let profile, profile.provider == .codex else { return [] }
        let models = try await modelClient.codexModelOptions(
            port: config.port,
            modelPrefix: profile.modelPrefix
        )
        availableCodexAPIModelOptionsByProvider[provider] = models
        if provider == .codexAPI { availableCodexAPIModelOptions = models }
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
        availableClaudeModelOptionsByProvider = Dictionary(
            uniqueKeysWithValues: cached.map { key, value in
                (ProviderRowState.ID(rawValue: key), value)
            }
        )
        availableClaudeAPIModelOptions = availableClaudeModelOptionsByProvider[.claudeAPI] ?? []
    }

    private func persistClaudeModelOptions() {
        let cached = Dictionary(
            uniqueKeysWithValues: availableClaudeModelOptionsByProvider.map { ($0.key.rawValue, $0.value) }
        )
        try? claudeModelOptionsCache.save(cached)
    }

    func prepareClaudeModels(for provider: ProviderRowState.ID) async {
        if let profile = apiKeyProfile(id: provider.rawValue), profile.provider == .claude {
            guard availableClaudeModelOptionsByProvider[provider]?.isEmpty != false,
                  isAPIKeyConfigured(profile.secretReference),
                  (try? await prepareModelServer()) == true else { return }
            _ = try? await claudeAPIModels(for: provider)
            return
        }

        guard availableClaudeModelOptionsByProvider[provider]?.isEmpty != false,
              config.oauthCommandProfiles.contains(where: {
                  $0.id == provider.rawValue && $0.provider == .claude && $0.connectionMode == .proxy
              }),
              (try? await prepareModelServer()) == true else { return }
        _ = try? await claudeModels(for: provider)
    }

    func claudeAPIModels(for provider: ProviderRowState.ID = .claudeAPI) async throws -> [ClaudeModelOption] {
        let profile = apiKeyProfile(id: provider.rawValue)
            ?? (provider == .claudeAPI ? .legacy(provider: .claude) : nil)
        guard let profile, profile.provider == .claude else { return [] }
        let models = try await modelClient.claudeModelOptions(
            port: config.port,
            modelPrefix: profile.modelPrefix
        )
        availableClaudeModelOptionsByProvider[provider] = models
        if provider == .claudeAPI { availableClaudeAPIModelOptions = models }
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
                    defaultReasoning = supported.isEmpty ? .auto : nil
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
        Self.roundRobinModelPrefixes(
            for: profile,
            authProfiles: authProfiles,
            commandProfiles: config.oauthCommandProfiles
        )
    }

    static func roundRobinModelPrefixes(
        for profile: AppConfig.RoundRobinProfile,
        authProfiles: [AuthProfile],
        commandProfiles: [AppConfig.OAuthCommandProfile]
    ) -> [String] {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        let commandProfilesByAuthID = commandProfiles.reduce(into: [:]) { result, commandProfile in
            result[commandProfile.authProfileID] = commandProfile
        }
        return profile.includedAuthProfileIDs.compactMap { authProfileID in
            guard let authProfile = authProfilesByID[authProfileID] else { return nil }
            return routingPrefix(
                authProfile: authProfile,
                commandProfile: commandProfilesByAuthID[authProfileID]
            )
        }
    }

    private func handleCodexModelLoadingFailure(_ error: Error? = nil) {
        availableCodexModelOptions = []
        let fallbackMessage = "Codex is connected, but the app could not load models through the local proxy server. Start the server and refresh, or keep the saved model."
        codexModelLoadingState = .failed(error?.localizedDescription ?? fallbackMessage)
    }

    private func normalizeCommandName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func availableAPIKeyProfiles(in config: AppConfig) -> [AppConfig.APIKeyProfile] {
        var profiles = config.apiKeyProfiles
        for provider in [AuthProfileType.claude, .codex] {
            let legacyProfile = AppConfig.APIKeyProfile.legacy(provider: provider)
            guard !profiles.contains(where: { $0.id == legacyProfile.id }),
                  isAPIKeyConfigured(legacyProfile.secretReference) else {
                continue
            }
            profiles.append(legacyProfile)
        }
        return profiles
    }

    private static func removingEmptyLegacyAPIKeyProfiles(
        from config: AppConfig,
        secretStore: any SecretStore
    ) -> AppConfig {
        var config = config
        config.apiKeyProfiles.removeAll { profile in
            guard profile.id == "claude-api" || profile.id == "codex-api",
                  isDefaultLegacyAPIKeyProfile(profile) else {
                return false
            }
            do {
                return try secretStore.get(profile.secretReference)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            } catch SecretStoreError.missingSecret {
                return true
            } catch {
                return false
            }
        }
        return config
    }

    private static func isDefaultLegacyAPIKeyProfile(_ profile: AppConfig.APIKeyProfile) -> Bool {
        guard profile.commandName.isEmpty,
              profile.nickname.isEmpty,
              !profile.dangerousPermissionsEnabled else {
            return false
        }
        switch profile.provider {
        case .claude:
            return profile.effectiveClaudeRouting == .automatic
        case .codex:
            return profile.effectiveCodex == .default
        }
    }

    static func availableConfig(_ config: AppConfig) -> AppConfig {
        var config = config
        config.showNotifications = false
        config.roundRobinEnabled = false
        return config
    }

    private static func persistedConfig(_ config: AppConfig) -> AppConfig {
        AppConfigMigration.recomputingModelPrefixes(in: availableConfig(config))
    }

    private struct CodexCredentialMigrationResult {
        let config: AppConfig
        let profiles: Result<[AuthProfile], Error>
        let mapping: [String: String]
    }

    private static func applyPreparedCodexCredentialMigrations(
        to config: AppConfig,
        authProfileStore: any AuthProfileManaging,
        configStore: any AppConfigStoring,
        subscriptionUsageSnapshotCache: any SubscriptionUsageSnapshotCaching,
        resetCreditsSnapshotCache: any CodexResetCreditsSnapshotCaching
    ) -> CodexCredentialMigrationResult {
        let migrations: [AuthProfileMigration]
        do {
            migrations = try authProfileStore.prepareCodexCredentialMigrations()
        } catch {
            return CodexCredentialMigrationResult(config: config, profiles: .failure(error), mapping: [:])
        }
        guard !migrations.isEmpty else {
            return CodexCredentialMigrationResult(
                config: config,
                profiles: Result { try authProfileStore.profiles() },
                mapping: [:]
            )
        }

        let mapping = migrationMapping(migrations)
        let migratedConfig = remappingAuthProfileIDs(in: config, using: mapping)
        let originalSnapshots = subscriptionUsageSnapshotCache.load()
        let originalResetSnapshots = resetCreditsSnapshotCache.load()
        do {
            try configStore.save(migratedConfig)
            try remapSubscriptionUsageSnapshots(
                originalSnapshots,
                using: mapping,
                cache: subscriptionUsageSnapshotCache
            )
            try remapCodexResetCreditSnapshots(
                originalResetSnapshots,
                using: mapping,
                cache: resetCreditsSnapshotCache
            )
            try authProfileStore.finalizeCodexCredentialMigrations(migrations)
            return CodexCredentialMigrationResult(
                config: migratedConfig,
                profiles: Result { try authProfileStore.profiles() },
                mapping: mapping
            )
        } catch {
            try? configStore.save(config)
            try? subscriptionUsageSnapshotCache.save(originalSnapshots)
            try? resetCreditsSnapshotCache.save(originalResetSnapshots)
            authProfileStore.rollbackCodexCredentialMigrations(migrations)
            return CodexCredentialMigrationResult(
                config: config,
                profiles: Result { try authProfileStore.profiles() },
                mapping: [:]
            )
        }
    }

    private func applyCodexCredentialMigrationsIfNeeded() {
        guard configWriteProtectionMessage == nil else { return }
        let result = Self.applyPreparedCodexCredentialMigrations(
            to: config,
            authProfileStore: authProfileStore,
            configStore: configStore,
            subscriptionUsageSnapshotCache: subscriptionUsageSnapshotCache,
            resetCreditsSnapshotCache: codexResetCreditsSnapshotCache
        )
        let configChanged = result.config != config
        if configChanged {
            config = result.config
            lastPersistedConfig = result.config
        }
        if !result.mapping.isEmpty {
            subscriptionUsageStates = Self.remappingSubscriptionUsageStates(
                subscriptionUsageStates,
                using: result.mapping
            )
            codexResetCreditsSnapshots = Self.remappingCodexResetCreditSnapshots(
                codexResetCreditsSnapshots,
                using: result.mapping
            )
            codexResetCreditsLastAttemptAt = Self.remappingAttemptDates(
                codexResetCreditsLastAttemptAt,
                using: result.mapping
            )
        }
        switch result.profiles {
        case .success(let profiles):
            authProfiles = profiles
        case .failure where !result.mapping.isEmpty:
            authProfiles = Self.remappingAuthProfiles(authProfiles, using: result.mapping)
        case .failure:
            break
        }
        if configChanged {
            cards = ProfileCard.makeDefaultCards(config: result.config)
            rebuildOptionRows()
        }
    }

    private static func migrationMapping(_ migrations: [AuthProfileMigration]) -> [String: String] {
        Dictionary(
            migrations.map { ($0.oldID, $0.newID) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    static func authProfileIDMapping(from oldConfig: AppConfig, to newConfig: AppConfig) -> [String: String] {
        let oldByCommandID = Dictionary(
            oldConfig.oauthCommandProfiles.map { ($0.id, $0.authProfileID) },
            uniquingKeysWith: { first, _ in first }
        )
        return newConfig.oauthCommandProfiles.reduce(into: [String: String]()) { result, profile in
            guard let oldID = oldByCommandID[profile.id],
                  oldID != profile.authProfileID,
                  result[oldID] == nil else {
                return
            }
            result[oldID] = profile.authProfileID
        }
    }

    private static func remappingAuthProfiles(
        _ profiles: [AuthProfile],
        using mapping: [String: String]
    ) -> [AuthProfile] {
        guard !mapping.isEmpty else { return profiles }
        var remapped: [AuthProfile] = []
        var indexByID: [String: Int] = [:]
        for profile in profiles {
            let profileID = mapping[profile.id] ?? profile.id
            let updated = AuthProfile(
                fileName: profileID,
                type: profile.type,
                email: profile.email,
                accountID: profile.accountID,
                expired: profile.expired,
                disabled: profile.disabled,
                prefix: profile.prefix
            )
            if let existingIndex = indexByID[profileID] {
                if mapping[profile.id] == nil {
                    remapped[existingIndex] = updated
                }
            } else {
                indexByID[profileID] = remapped.count
                remapped.append(updated)
            }
        }
        return remapped
    }

    private static func remappingAuthProfileIDs(
        in config: AppConfig,
        using mapping: [String: String]
    ) -> AppConfig {
        guard !mapping.isEmpty else { return config }
        var updated = config
        updated.oauthCommandProfiles = config.oauthCommandProfiles.map { profile in
            var profile = profile
            profile.authProfileID = mapping[profile.authProfileID] ?? profile.authProfileID
            return profile
        }
        updated.roundRobinProfiles = config.roundRobinProfiles.map { profile in
            var profile = profile
            var seen: Set<String> = []
            profile.includedAuthProfileIDs = profile.includedAuthProfileIDs.compactMap { profileID in
                let remapped = mapping[profileID] ?? profileID
                return seen.insert(remapped).inserted ? remapped : nil
            }
            return profile
        }
        return updated
    }

    private static func remapSubscriptionUsageSnapshots(
        _ snapshots: [String: SubscriptionUsageSnapshot],
        using mapping: [String: String],
        cache: any SubscriptionUsageSnapshotCaching
    ) throws {
        guard !mapping.isEmpty else { return }
        var remapped: [String: SubscriptionUsageSnapshot] = [:]
        for (key, snapshot) in snapshots {
            let profileID = mapping[key] ?? mapping[snapshot.profileID] ?? snapshot.profileID
            let updated = SubscriptionUsageSnapshot(
                profileID: profileID,
                provider: snapshot.provider,
                windows: snapshot.windows,
                fetchedAt: snapshot.fetchedAt
            )
            if let existing = remapped[profileID], existing.fetchedAt >= updated.fetchedAt {
                continue
            }
            remapped[profileID] = updated
        }
        if remapped != snapshots {
            try cache.save(remapped)
        }
    }

    private static func remapCodexResetCreditSnapshots(
        _ snapshots: [String: CodexResetCreditsSnapshot],
        using mapping: [String: String],
        cache: any CodexResetCreditsSnapshotCaching
    ) throws {
        guard !mapping.isEmpty else { return }
        let remapped = remappingCodexResetCreditSnapshots(snapshots, using: mapping)
        if remapped != snapshots {
            try cache.save(remapped)
        }
    }

    private static func remappingCodexResetCreditSnapshots(
        _ snapshots: [String: CodexResetCreditsSnapshot],
        using mapping: [String: String]
    ) -> [String: CodexResetCreditsSnapshot] {
        guard !mapping.isEmpty else { return snapshots }
        var remapped: [String: CodexResetCreditsSnapshot] = [:]
        for (key, snapshot) in snapshots {
            let profileID = mapping[key] ?? mapping[snapshot.profileID] ?? snapshot.profileID
            let updated = CodexResetCreditsSnapshot(
                profileID: profileID,
                reportedAvailableCount: snapshot.reportedAvailableCount,
                reportedTotalEarnedCount: snapshot.reportedTotalEarnedCount,
                credits: snapshot.credits,
                fetchedAt: snapshot.fetchedAt
            )
            if let existing = remapped[profileID], existing.fetchedAt >= updated.fetchedAt {
                continue
            }
            remapped[profileID] = updated
        }
        return remapped
    }

    private static func remappingAttemptDates(
        _ dates: [String: Date],
        using mapping: [String: String]
    ) -> [String: Date] {
        dates.reduce(into: [:]) { result, entry in
            let profileID = mapping[entry.key] ?? entry.key
            result[profileID] = max(result[profileID] ?? .distantPast, entry.value)
        }
    }

    static func remappingSubscriptionUsageStates(
        _ states: [String: AccountSubscriptionUsageState],
        using mapping: [String: String]
    ) -> [String: AccountSubscriptionUsageState] {
        guard !mapping.isEmpty else { return states }
        var remapped: [String: AccountSubscriptionUsageState] = [:]
        for (key, state) in states {
            let targetID = mapping[key] ?? key
            let updatedState: AccountSubscriptionUsageState
            switch state {
            case .available(let snapshot):
                updatedState = .available(remapping(snapshot, profileID: targetID))
            case .stale(let snapshot, let issue):
                updatedState = .stale(remapping(snapshot, profileID: targetID), issue)
            case .disabled, .managementKeyNotConfigured, .loading, .unavailable:
                updatedState = state
            }
            if let existing = remapped[targetID], let existingSnapshot = existing.snapshot {
                guard let updatedSnapshot = updatedState.snapshot,
                      updatedSnapshot.fetchedAt > existingSnapshot.fetchedAt else {
                    continue
                }
            }
            remapped[targetID] = updatedState
        }
        return remapped
    }

    private static func remapping(
        _ snapshot: SubscriptionUsageSnapshot,
        profileID: String
    ) -> SubscriptionUsageSnapshot {
        SubscriptionUsageSnapshot(
            profileID: profileID,
            provider: snapshot.provider,
            windows: snapshot.windows,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func reconcileConfigWithAuthProfiles() {
        guard configWriteProtectionMessage == nil else { return }
        let result = AppConfigMigration.reconcile(
            loadResult: .canonical(config),
            authProfiles: authProfiles
        )
        if result.config != config {
            config = result.config
            cards = ProfileCard.makeDefaultCards(config: result.config)
            rebuildOptionRows()
            do {
                try configStore.save(result.config)
                lastPersistedConfig = result.config
            } catch {
                settingsMessage = "Config migration failed: \(error.localizedDescription)"
            }
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
        updatedConfig.usageOverlay.hiddenAccountIDs.removeAll { $0 == provider.rawValue }
        updatedConfig.oauthCommandProfiles.removeAll { $0.id == provider.rawValue }
        try saveConfig(updatedConfig, validateShellFunctions: true)
    }

    private func codexFastConfigurationInput(config: AppConfig) -> CodexFastConfigurationInput {
        let oauth: [CodexFastConfigurationInput.Configuration] = config.oauthCommandProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return .init(profile.codex ?? .default)
        }
        let roundRobin: [CodexFastConfigurationInput.Configuration] = config.roundRobinProfiles.compactMap { profile in
            guard profile.provider == .codex, profile.isEnabled else { return nil }
            return .init(profile.codex ?? .default)
        }
        let apiKeys = config.apiKeyProfiles.compactMap { profile -> CodexFastConfigurationInput.Configuration? in
            guard profile.provider == .codex else { return nil }
            return .init(profile.effectiveCodex)
        }
        return CodexFastConfigurationInput(
            oauth: oauth,
            roundRobin: roundRobin,
            apiKeys: apiKeys
        )
    }

    private func codexFastConfiguration(from input: CodexFastConfigurationInput) throws -> CodexFastConfiguration {
        var snapshotConfig = AppConfig.default
        snapshotConfig.oauthCommandProfiles = input.oauth.enumerated().map { index, configuration in
            .init(
                id: "fast-snapshot-oauth-\(index)",
                provider: .codex,
                authProfileID: "fast-snapshot-oauth-\(index).json",
                codex: configuration.codex,
                modelPrefix: "fast-snapshot-oauth-\(index)"
            )
        }
        snapshotConfig.roundRobinProfiles = input.roundRobin.enumerated().map { index, configuration in
            .init(
                id: "fast-snapshot-round-robin-\(index)",
                provider: .codex,
                isEnabled: true,
                codex: configuration.codex
            )
        }
        snapshotConfig.apiKeyProfiles = input.apiKeys.enumerated().map { index, configuration in
            let id = "fast-snapshot-api-\(index)"
            return AppConfig.APIKeyProfile(
                id: id,
                provider: .codex,
                secretReference: SecretReference.apiKeyProfile(id)!,
                codex: configuration.codex
            )
        }
        return try CodexFastConfiguration(config: snapshotConfig)
    }

    private func validateAPIKeyProfiles(_ profiles: [AppConfig.APIKeyProfile]) throws {
        var profileIDs: Set<String> = []
        var secretReferences: Set<SecretReference> = []
        for profile in profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw CLIProxyManagerCommandError.prerequisite("Duplicate API key profile ID: \(profile.id)")
            }
            guard secretReferences.insert(profile.secretReference).inserted else {
                throw CLIProxyManagerCommandError.prerequisite(
                    "API key profiles must use separate secret references."
                )
            }
            guard profile.hasValidIdentity else {
                throw CLIProxyManagerCommandError.prerequisite(
                    "API key profile `\(profile.id)` has an invalid identity or secret reference."
                )
            }
        }
    }

    private func saveConfig(
        _ updatedConfig: AppConfig,
        validateShellFunctions: Bool = false,
        shellProfileValidationNames: [String]? = nil,
        preservingUnavailableRoundRobinProfiles: Bool = false
    ) throws {
        if let configWriteProtectionMessage {
            throw CLIProxyManagerCommandError.prerequisite(configWriteProtectionMessage)
        }
        let persistedConfig = preservingUnavailableRoundRobinProfiles
            ? updatedConfig
            : removingUnavailableRoundRobinProfiles(from: updatedConfig)
        var updatedConfig = Self.persistedConfig(persistedConfig)
        try validateAPIKeyProfiles(updatedConfig.apiKeyProfiles)
        _ = try CodexFastConfiguration(config: updatedConfig)
        let oldFastInput = codexFastConfigurationInput(config: config)
        let newFastInput = codexFastConfigurationInput(config: updatedConfig)
        let fastConfigurationChanged: Bool
        if oldFastInput == newFastInput {
            fastConfigurationChanged = false
        } else {
            let newFastConfiguration = try codexFastConfiguration(from: newFastInput)
            let oldFastConfiguration = try? codexFastConfiguration(from: oldFastInput)
            fastConfigurationChanged = oldFastConfiguration != newFastConfiguration
        }
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
        updatedConfig = config

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

    private func savePrivacyOnlyConfig(_ updatedConfig: AppConfig) throws {
        if let configWriteProtectionMessage {
            throw CLIProxyManagerCommandError.prerequisite(configWriteProtectionMessage)
        }
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
        let configToSave = config

        var prefixRollbacks: [AuthProfilePrefixRollback] = []
        do {
            prefixRollbacks = try syncAuthProfilePrefixesForSave()
            try configStore.save(configToSave)
            lastPersistedConfig = configToSave
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
        let apiKeyProfileIDs = Set(config.apiKeyProfiles.compactMap { profile in
            let commandName = profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
            return commandName.isEmpty ? nil : profile.id
        })
        return AutomaticShellInstallService.EnabledFunctions(
            claudeOAuth: enabledProfiles.contains { $0.provider == .claude } || enabledRoundRobinProfiles.contains { $0.provider == .claude },
            codex: enabledProfiles.contains { $0.provider == .codex } || enabledRoundRobinProfiles.contains { $0.provider == .codex },
            apiKeyProfileIDs: apiKeyProfileIDs
        )
    }

    private func activeFunctionNames(in config: AppConfig) -> [String] {
        let oauthNames = renderableOAuthCommandProfiles(in: config)
            .map { normalizeCommandName($0.commandName) }
        let roundRobinNames = config.roundRobinProfiles
            .filter(\.isEnabled)
            .map { normalizeCommandName($0.commandName) }
        let apiNames = config.apiKeyProfiles.map { profile in
            normalizeCommandName(profile.commandName)
        }
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
            guard let commandProfile = commandProfilesByAuthID[authProfileID],
                  let authProfile = authProfilesByID[authProfileID],
                  authProfile.type == profile.provider,
                  !authProfile.disabled,
                  commandProfile.isEnabled,
                  (profile.provider != .claude || commandProfile.connectionMode != .direct),
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
                existing.codex = AppConfig.Codex.default
            }
            return existing
        }
        return AppConfig.RoundRobinProfile(
            id: defaultID,
            provider: providerType,
            isEnabled: false,
            commandName: "",
            includedAuthProfileIDs: roundRobinAccountOptions(for: providerType).filter { $0.isEnabled && $0.hasPrefix }.map(\.id),
            codex: providerType == .codex ? AppConfig.Codex.default : nil
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
        Self.routingPrefix(authProfile: authProfile, commandProfile: commandProfile)
    }

    private static func routingPrefix(
        authProfile: AuthProfile,
        commandProfile: AppConfig.OAuthCommandProfile?
    ) -> String? {
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

    private var apiUsageCollectorConfiguration: APIUsageCollectorConfiguration {
        let profiles = availableAPIKeyProfiles(in: config).compactMap { profile -> APIUsageProfileDescriptor? in
            guard isAPIKeyConfigured(profile.secretReference) else { return nil }
            return APIUsageProfileDescriptor(
                profileID: profile.id,
                provider: profile.provider == .claude ? .claude : .openAI,
                modelPrefix: profile.modelPrefix
            )
        }
        return APIUsageCollectorConfiguration(
            usageEnabled: config.isUsageEnabled,
            proxyReady: serverStatus.severity == .ready,
            port: config.port,
            profiles: profiles,
            reportingTimeZoneID: TimeZone.current.identifier
        )
    }

    private var enabledAPIUsageProfileIDs: Set<String> {
        Set(apiUsageCollectorConfiguration.profiles.map(\.profileID))
    }

    private var defaultSubscriptionUsageState: AccountSubscriptionUsageState {
        config.isUsageEnabled ? .managementKeyNotConfigured : .disabled
    }

    private var defaultAPICostUsageState: APICostUsageState {
        config.isUsageEnabled ? .loading : .disabled
    }

    private func showsInUsageOverlay(_ id: ProviderRowState.ID) -> Bool {
        !config.usageOverlay.hiddenAccountIDs.contains(id.rawValue)
    }

    private func rebuildProviderRows(claudeStatus: DiagnosticStatus?, codexStatus: DiagnosticStatus?) {
        let authProfilesByID = Dictionary(uniqueKeysWithValues: authProfiles.map { ($0.id, $0) })
        var rows: [ProviderRowState] = config.oauthCommandProfiles.compactMap { commandProfile in
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
                usageState: .subscription(subscriptionUsageStates[authProfile.id] ?? defaultSubscriptionUsageState),
                resetCreditsSnapshot: commandProfile.provider == .codex
                    ? codexResetCreditsSnapshots[authProfile.id]
                    : nil,
                showsInUsageOverlay: showsInUsageOverlay(ProviderRowState.ID(rawValue: commandProfile.id))
            )
        }

        for profile in availableAPIKeyProfiles(in: config) {
            let id = ProviderRowState.ID(rawValue: profile.id)
            let configured = isAPIKeyConfigured(profile.secretReference)
            rows.append(ProviderRowState(
                id: id,
                providerType: profile.provider,
                credentialKind: .apiKey,
                authProfileID: profile.id,
                commandProfileID: profile.id,
                name: profile.provider == .claude ? "Claude API Key" : "OpenAI API Key",
                nickname: profile.nickname,
                functionName: profile.commandName,
                connectionTitle: configured ? "Configured" : "API key missing",
                connectionDetail: configured ? "CLIProxyAPI" : "Open settings to add the API key.",
                isConnected: configured,
                accountDetailHidden: true,
                usageState: .apiCost(apiCostUsageStates[profile.id] ?? defaultAPICostUsageState),
                showsUsage: true,
                showsInUsageOverlay: showsInUsageOverlay(id)
            ))
        }
        let orderedRows = AccountOrdering.orderedRows(rows, storedIDs: config.accountOrder)
        providerRows = orderedRows
        config.accountOrder = orderedRows.map { $0.id.rawValue }
    }

    private func rebuildOptionRows() {
        let functionNames = (
            config.oauthCommandProfiles.map(\.commandName)
                + config.roundRobinProfiles.map(\.commandName)
                + config.apiKeyProfiles.map(\.commandName)
        )
        .map(normalizeCommandName)
        .filter { !$0.isEmpty }
        let dangerousPermissionsEnabled = config.oauthCommandProfiles.contains { $0.dangerousPermissionsEnabled }
            || config.roundRobinProfiles.contains { $0.dangerousPermissionsEnabled }
            || config.apiKeyProfiles.contains { $0.dangerousPermissionsEnabled }
        optionRows = [
            DashboardOptionRow(id: "port", title: "Port", value: "\(config.port)", detail: "App-managed CLIProxyAPI server"),
            DashboardOptionRow(id: "functions", title: "Shell Functions", value: functionNames.joined(separator: " / "), detail: "Terminal commands"),
            DashboardOptionRow(id: "models", title: "Models", value: "Claude + Codex mappings", detail: "Model, reasoning, context window"),
            DashboardOptionRow(id: "permissions", title: "Permissions", value: dangerousPermissionsEnabled ? "Dangerous skip enabled" : "Safe mode", detail: "Claude Code permission behavior"),
            DashboardOptionRow(id: "install", title: "Shell Install", value: shellInstaller.isInstalled() ? "Installed" : "Not installed", detail: "Managed .zshrc source block")
        ]
    }

    private func performServerAction(
        title: String,
        transitionState: ServerControlState,
        waitForReady: Bool = false,
        action: () async throws -> Void
    ) async {
        await waitForConfigurationRestartIfNeeded()
        while isServerActionInProgress {
            _ = await waitForServerActionCompletion()
        }
        _ = await executeServerAction(
            title: title,
            transitionState: transitionState,
            waitForReady: waitForReady,
            action: action
        )
    }

    @discardableResult
    private func restartServerAfterRequiredChange() async -> Bool {
        await waitForConfigurationRestartIfNeeded()
        while isServerActionInProgress {
            _ = await waitForServerActionCompletion()
        }
        return await executeServerAction(
            title: "Failed to restart CLIProxyAPI",
            transitionState: .starting,
            waitForReady: true
        ) {
            try await proxyService.restart(port: config.port)
        }
    }

    private func waitForConfigurationRestartIfNeeded() async {
        if let proxyConfigurationRestartTask {
            await proxyConfigurationRestartTask.value
        }
    }

    private func waitForPendingProxyConfigurationWork() async -> Bool {
        if let completion = oauthLoginSession?.observedServerActionCompletion,
           !completion.succeeded {
            return false
        }
        while true {
            if let proxyConfigurationRestartTask {
                await proxyConfigurationRestartTask.value
                guard serverStatus.severity == .ready,
                      serverControlState.isRunning else { return false }
                continue
            }
            if isServerActionInProgress {
                let completion = await waitForServerActionCompletion()
                guard completion.succeeded else { return false }
                continue
            }
            if !pendingProxyConfigurationRestartReasons.isEmpty {
                guard serverControlState.isRunning else { return false }
                let drainResult = await drainPendingProxyConfigurationRestarts()
                guard drainResult.succeeded else { return false }
                continue
            }
            return true
        }
    }

    private func waitForServerActionCompletion() async -> ServerActionCompletion {
        guard isServerActionInProgress,
              configurationWork.activeServerActionGeneration != nil else {
            return ServerActionCompletion(
                generation: configurationWork.nextServerActionGeneration,
                terminal: .stable(
                    appliedGeneration: configurationWork.lastAppliedGeneration,
                    reasons: configurationWork.lastAppliedReasons
                )
            )
        }
        return await withCheckedContinuation { continuation in
            serverActionCompletionWaiters.append(continuation)
        }
    }

    private func finishServerAction(_ completion: ServerActionCompletion) {
        if completion.succeeded {
            handOffCodexResetCreditsSourceAuthorizationIfNeeded(
                for: .serverAction(completion.generation)
            )
        }
        if configurationWork.activeServerActionGeneration == completion.generation {
            configurationWork.activeServerActionGeneration = nil
        }
        if oauthLoginSession?.startedDuringServerActionGeneration == completion.generation,
           oauthLoginSession?.observedServerActionCompletion == nil {
            oauthLoginSession?.observedServerActionCompletion = completion
        }
        isServerActionInProgress = false
        serverActionWaitsForReady = false
        schedulePendingProxyConfigurationRestartIfNeeded()
        let waiters = serverActionCompletionWaiters
        serverActionCompletionWaiters.removeAll()
        waiters.forEach { $0.resume(returning: completion) }
        scheduleConfigurationWorkStabilization()
    }

    private func serverActionTerminalResult(
        succeeded: Bool
    ) -> ProxyConfigurationDrainResult.Terminal {
        if succeeded {
            if proxyRuntimeCertainty == .confirmedStopped || !serverControlState.isRunning {
                return .stopped
            }
            return .stable(
                appliedGeneration: configurationWork.lastAppliedGeneration,
                reasons: configurationWork.lastAppliedReasons
            )
        }
        if let failure = configurationWork.ownedRestartFailure {
            return .failed(failure)
        }
        return .failed(ConfigurationRestartFailure(
            generation: configurationWork.generation,
            reasons: pendingProxyConfigurationRestartReasons,
            message: serverStatus.message.isEmpty ? "Could not connect to the server." : serverStatus.message
        ))
    }

    @discardableResult
    private func executeServerAction(
        title: String,
        transitionState: ServerControlState,
        waitForReady: Bool,
        action: () async throws -> Void
    ) async -> Bool {
        guard !isPreparingAPIUsageForTermination, !Task.isCancelled else { return false }
        configurationWork.nextServerActionGeneration &+= 1
        let actionGeneration = configurationWork.nextServerActionGeneration
        let reasonsAppliedByAction = waitForReady ? pendingProxyConfigurationRestartReasons : []
        let configurationGenerationAppliedByAction = configurationWork.generation
        var actionSucceeded = false
        var performedConfigurationRestart = false
        isServerActionInProgress = true
        serverActionWaitsForReady = waitForReady
        configurationWork.activeServerActionGeneration = actionGeneration
        proxyRuntimeCertainty = .mayBeRunning
        serverControlState = transitionState
        defer {
            finishServerAction(ServerActionCompletion(
                generation: actionGeneration,
                terminal: serverActionTerminalResult(succeeded: actionSucceeded)
            ))
        }

        do {
            try await action()
            guard !isPreparingAPIUsageForTermination, !Task.isCancelled else { return false }
            if waitForReady {
                await refreshUntilServerIsReady()
                guard serverStatus.severity == .ready else {
                    let message = serverStatus.message.isEmpty
                        ? "Could not connect to the server."
                        : serverStatus.message
                    throw ProxyRestartReadinessError(message: message)
                }
                proxyRuntimeCertainty = .mayBeRunning
                serverControlState = .running
                if configurationWork.generation == configurationGenerationAppliedByAction {
                    pendingProxyConfigurationRestartReasons.subtract(reasonsAppliedByAction)
                }
                markProxyConfigurationGenerationApplied(
                    configurationGenerationAppliedByAction,
                    reasons: reasonsAppliedByAction
                )
                if !reasonsAppliedByAction.isEmpty {
                    performedConfigurationRestart = true
                    configurationWork.deferredCollectorUpdate = true
                }

                while true {
                    if !pendingProxyConfigurationRestartReasons.isEmpty {
                        performedConfigurationRestart = true
                    }
                    let restartResult = await drainPendingProxyConfigurationRestarts()
                    guard restartResult.succeeded,
                          serverStatus.severity == .ready,
                          serverControlState.isRunning else {
                        return false
                    }

                    let refreshResult = await refreshSubscriptionUsage(
                        force: false,
                        pollingWakeReason: nil,
                        source: .serverAction(actionGeneration)
                    )
                    guard !isPreparingAPIUsageForTermination, !Task.isCancelled else { return false }
                    if !pendingProxyConfigurationRestartReasons.isEmpty {
                        continue
                    }
                    if configurationWork.oauthRefreshOwnerSessionID != nil {
                        queueSubscriptionUsageRefresh(.automatic, reason: .serverActionHandback)
                        if !performedConfigurationRestart {
                            configurationWork.deferredCollectorUpdate = true
                        }
                        actionSucceeded = true
                        return true
                    }
                    if refreshResult == .deferred {
                        if !performedConfigurationRestart {
                            configurationWork.deferredCollectorUpdate = true
                        }
                        actionSucceeded = true
                        return true
                    }
                    if !performedConfigurationRestart {
                        scheduleAPIUsageCollectorUpdateIfStarted()
                    }
                    actionSucceeded = true
                    return true
                }
            }

            await refresh()
            proxyRuntimeCertainty = transitionState == .stopping
                ? .confirmedStopped
                : .mayBeRunning
            // After action completes, derive final state from the latest health.
            serverControlState = serverStatus.severity == .ready ? .running : .stopped
            if serverControlState.isRunning {
                if !pendingProxyConfigurationRestartReasons.isEmpty {
                    performedConfigurationRestart = true
                }
                let drainResult = await drainPendingProxyConfigurationRestarts()
                actionSucceeded = drainResult.succeeded
            } else {
                if proxyRuntimeCertainty == .confirmedStopped {
                    pendingProxyConfigurationRestartReasons.removeAll()
                }
                actionSucceeded = true
            }
            return actionSucceeded
        } catch {
            guard !isPreparingAPIUsageForTermination, !Task.isCancelled else { return false }
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
            if waitForReady, !reasonsAppliedByAction.isEmpty {
                let failure = ConfigurationRestartFailure(
                    generation: configurationGenerationAppliedByAction,
                    reasons: reasonsAppliedByAction,
                    message: message
                )
                configurationWork.ownedRestartFailure = failure
                if let failureMessage = failure.ownedSettingsMessage {
                    settingsMessage = failureMessage
                }
            }
            return false
        }
    }

    private func restartProxyAndRefresh() async throws {
        try await proxyService.restart(port: config.port)
        await refreshUntilServerIsReady()
        guard serverStatus.severity == .ready else {
            let message = serverStatus.message.isEmpty ? "Could not connect to the server." : serverStatus.message
            throw ProxyRestartReadinessError(message: message)
        }
        proxyRuntimeCertainty = .mayBeRunning
        serverControlState = .running
        configurationWork.deferredCollectorUpdate = true
    }

    private func scheduleAPIUsageCollectorUpdateIfStarted() {
        guard hasStartedAPIUsageCollector,
              !isPreparingAPIUsageForTermination else { return }
        let generation = invalidateAPIUsageLifecycle()
        let collector = apiUsageCollector
        let configuration = apiUsageCollectorConfiguration
        enqueueAPIUsageLifecycle(generation: generation) { [weak self] generation in
            guard let self,
                  self.isCurrentAPIUsageLifecycle(
                    generation: generation,
                    configuration: configuration
                  ) else { return }
            let report = await collector.update(configuration: configuration)
            self.acceptAPIUsageReport(
                report,
                configuration: configuration,
                generation: generation
            )
        }
    }

    private func stableServerStatus() async -> DiagnosticStatus {
        let firstStatus = await proxyHealthClient.status(port: config.port)
        guard firstStatus.severity == .error else { return firstStatus }

        try? await Task.sleep(nanoseconds: serverStatusRetryDelayNanoseconds)
        return await proxyHealthClient.status(port: config.port)
    }

    private func updateProxyRuntimeCertainty(from status: DiagnosticStatus) {
        proxyRuntimeCertainty = status.title == "CLIProxyAPI Stopped"
            ? .confirmedStopped
            : .mayBeRunning
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

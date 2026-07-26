import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case error
    case warn
    case info
    case debug
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
        case direct
        case proxy
    }

    public struct ClaudeAPI: Codable, Equatable, Sendable {
        public var commandName: String
        public var claude: ClaudeRouting
        public var nickname: String
        public var dangerousPermissionsEnabled: Bool

        public var connectionMode: ConnectionMode { .proxy }

        public init(
            commandName: String = "",
            claude: ClaudeRouting = .automatic,
            nickname: String = "",
            dangerousPermissionsEnabled: Bool = false
        ) {
            self.commandName = commandName
            self.claude = claude
            self.nickname = nickname
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case commandName, connectionMode, claude, nickname, dangerousPermissionsEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.commandName = try container.decodeIfPresent(String.self, forKey: .commandName) ?? ""
            _ = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode)
            self.claude = try container.decodeIfPresent(ClaudeRouting.self, forKey: .claude) ?? .automatic
            self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
            self.dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(commandName, forKey: .commandName)
            try container.encode(claude, forKey: .claude)
            try container.encode(nickname, forKey: .nickname)
            try container.encode(dangerousPermissionsEnabled, forKey: .dangerousPermissionsEnabled)
        }
    }

    public enum CodexReasoning: String, Codable, CaseIterable, Sendable {
        case auto
        case low
        case medium
        case high
        case xhigh
        case max
    }

    public struct CodexRole: Codable, Equatable, Sendable {
        public var model: String
        public var reasoning: CodexReasoning
        public var detectedContextWindow: Int?
        public var fastModeEnabled: Bool

        public init(
            model: String,
            reasoning: CodexReasoning,
            detectedContextWindow: Int? = nil,
            fastModeEnabled: Bool = false
        ) {
            self.model = model
            self.reasoning = reasoning
            self.detectedContextWindow = detectedContextWindow
            self.fastModeEnabled = fastModeEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case model, reasoning, detectedContextWindow, fastModeEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            reasoning = try container.decode(CodexReasoning.self, forKey: .reasoning)
            detectedContextWindow = try container.decodeIfPresent(Int.self, forKey: .detectedContextWindow)
            fastModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .fastModeEnabled) ?? false
        }

        public var modelIdentifier: String {
            let base = CodexFastMode.modelIdentifier(
                model: model,
                reasoning: reasoning,
                fastModeEnabled: fastModeEnabled
            )
            guard let detectedContextWindow, detectedContextWindow > 200_000 else { return base }
            return base + "[1m]"
        }
    }

    public struct Codex: Codable, Equatable, Sendable {
        public static let `default` = Codex(
            opus: CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh),
            sonnet: CodexRole(model: "gpt-5.6-terra", reasoning: .medium),
            haiku: CodexRole(model: "gpt-5.6-terra", reasoning: .low)
        )

        public var opus: CodexRole
        public var sonnet: CodexRole
        public var haiku: CodexRole

        public init(opus: CodexRole, sonnet: CodexRole, haiku: CodexRole) {
            self.opus = opus
            self.sonnet = sonnet
            self.haiku = haiku
        }
    }

    public struct CodexAPI: Codable, Equatable, Sendable {
        public var commandName: String
        public var codex: Codex
        public var nickname: String
        public var dangerousPermissionsEnabled: Bool

        public init(
            commandName: String = "",
            codex: Codex = .default,
            nickname: String = "",
            dangerousPermissionsEnabled: Bool = false
        ) {
            self.commandName = commandName
            self.codex = codex
            self.nickname = nickname
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case commandName, codex, nickname, dangerousPermissionsEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.commandName = try container.decodeIfPresent(String.self, forKey: .commandName) ?? ""
            self.codex = try container.decodeIfPresent(Codex.self, forKey: .codex) ?? .default
            self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
            self.dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
        }
    }

    public struct OAuthCommandProfile: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var provider: AuthProfileType
        public var authProfileID: String
        public var commandName: String
        public var nickname: String
        public var accountDetailHidden: Bool
        public var dangerousPermissionsEnabled: Bool
        public var claude: ClaudeRouting?
        public var codex: Codex?
        public var modelPrefix: String
        public var connectionMode: ConnectionMode
        public var isEnabled: Bool

        public init(
            id: String,
            provider: AuthProfileType,
            authProfileID: String,
            commandName: String = "",
            nickname: String = "",
            accountDetailHidden: Bool = true,
            dangerousPermissionsEnabled: Bool = false,
            claude: ClaudeRouting? = nil,
            codex: Codex? = nil,
            modelPrefix: String = "",
            connectionMode: ConnectionMode = .proxy,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.provider = provider
            self.authProfileID = authProfileID
            self.commandName = commandName
            self.nickname = nickname
            self.accountDetailHidden = accountDetailHidden
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
            self.claude = claude
            self.codex = codex
            self.modelPrefix = modelPrefix
            self.connectionMode = connectionMode
            self.isEnabled = isEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case id, provider, authProfileID, commandName, nickname, accountDetailHidden
            case dangerousPermissionsEnabled, claude, codex, modelPrefix, connectionMode, isEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.provider = try container.decode(AuthProfileType.self, forKey: .provider)
            self.authProfileID = try container.decode(String.self, forKey: .authProfileID)
            self.commandName = try container.decodeIfPresent(String.self, forKey: .commandName) ?? ""
            self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
            self.accountDetailHidden = try container.decodeIfPresent(Bool.self, forKey: .accountDetailHidden) ?? true
            self.dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
            self.claude = try container.decodeIfPresent(ClaudeRouting.self, forKey: .claude)
            self.codex = try container.decodeIfPresent(Codex.self, forKey: .codex)
            self.modelPrefix = try container.decodeIfPresent(String.self, forKey: .modelPrefix) ?? ""
            self.connectionMode = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode) ?? .proxy
            self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        }

        public var effectiveClaudeRouting: ClaudeRouting {
            provider == .claude ? (claude ?? .automatic) : .automatic
        }
    }

    public struct RoundRobinProfile: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var provider: AuthProfileType
        public var isEnabled: Bool
        public var commandName: String
        public var nickname: String
        public var includedAuthProfileIDs: [String]
        public var accountDetailHidden: Bool
        public var dangerousPermissionsEnabled: Bool
        public var codex: Codex?

        public init(
            id: String,
            provider: AuthProfileType,
            isEnabled: Bool = false,
            commandName: String = "",
            nickname: String = "",
            includedAuthProfileIDs: [String] = [],
            accountDetailHidden: Bool = true,
            dangerousPermissionsEnabled: Bool = false,
            codex: Codex? = nil
        ) {
            self.id = id
            self.provider = provider
            self.isEnabled = isEnabled
            self.commandName = commandName
            self.nickname = nickname
            self.includedAuthProfileIDs = includedAuthProfileIDs
            self.accountDetailHidden = accountDetailHidden
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
            self.codex = codex
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case provider
            case isEnabled
            case commandName
            case nickname
            case includedAuthProfileIDs
            case accountDetailHidden
            case dangerousPermissionsEnabled
            case codex
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.provider = try c.decode(AuthProfileType.self, forKey: .provider)
            self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            self.commandName = try c.decodeIfPresent(String.self, forKey: .commandName) ?? ""
            self.nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
            self.includedAuthProfileIDs = try c.decodeIfPresent([String].self, forKey: .includedAuthProfileIDs) ?? []
            self.accountDetailHidden = try c.decodeIfPresent(Bool.self, forKey: .accountDetailHidden) ?? true
            self.dangerousPermissionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
            self.codex = try c.decodeIfPresent(Codex.self, forKey: .codex)
        }
    }

    public struct SubscriptionUsage: Codable, Equatable, Sendable {
        public var showInMenuBar: Bool

        public init(showInMenuBar: Bool = false) {
            self.showInMenuBar = showInMenuBar
        }

        private enum CodingKeys: String, CodingKey {
            case showInMenuBar
            case isEnabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) {
                self.showInMenuBar = showInMenuBar
            } else {
                self.showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(showInMenuBar, forKey: .showInMenuBar)
        }
    }

    public struct UsageOverlay: Codable, Equatable, Sendable {
        public enum DisplayMode: String, Codable, Equatable, Sendable {
            case expanded
            case compact
        }

        public var isVisible: Bool
        public var alwaysOnTop: Bool
        public var backgroundOpacity: Double
        public var displayMode: DisplayMode
        public var hiddenAccountIDs: [String]

        public init(
            isVisible: Bool = false,
            alwaysOnTop: Bool = false,
            backgroundOpacity: Double = 0.9,
            displayMode: DisplayMode = .expanded,
            hiddenAccountIDs: [String] = []
        ) {
            self.isVisible = isVisible
            self.alwaysOnTop = alwaysOnTop
            self.backgroundOpacity = min(max(backgroundOpacity, 0.2), 1)
            self.displayMode = displayMode
            self.hiddenAccountIDs = Self.uniqued(hiddenAccountIDs)
        }

        private enum CodingKeys: String, CodingKey {
            case isVisible, alwaysOnTop, backgroundOpacity, displayMode, hiddenAccountIDs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
            self.alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
            self.backgroundOpacity = min(
                max(try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.9, 0.2),
                1
            )
            self.displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .expanded
            self.hiddenAccountIDs = Self.uniqued(
                try container.decodeIfPresent([String].self, forKey: .hiddenAccountIDs) ?? []
            )
        }

        private static func uniqued(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.filter { seen.insert($0).inserted }
        }
    }

    public var schemaVersion: Int
    public var port: Int
    public var claudeAPI: ClaudeAPI
    public var codexAPI: CodexAPI
    public var startAtLogin: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool
    public var showNotifications: Bool
    public var appearance: AppearanceMode
    public var subscriptionUsage: SubscriptionUsage
    public var usageOverlay: UsageOverlay

    public var isSubscriptionUsageEnabled: Bool {
        subscriptionUsage.showInMenuBar || usageOverlay.isVisible
    }

    public var oauthCommandProfiles: [OAuthCommandProfile]
    public var roundRobinProfiles: [RoundRobinProfile]
    public var accountOrder: [String]
    public var bindAddress: String
    public var autostartServer: Bool
    public var roundRobinEnabled: Bool
    public var logLevel: LogLevel

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        port: Int,
        claudeAPI: ClaudeAPI = ClaudeAPI(),
        codexAPI: CodexAPI = CodexAPI(),
        startAtLogin: Bool,
        showDockIcon: Bool,
        showMenuBarIcon: Bool,
        showNotifications: Bool = false,
        appearance: AppearanceMode = .system,
        subscriptionUsage: SubscriptionUsage = SubscriptionUsage(),
        usageOverlay: UsageOverlay = UsageOverlay(),
        oauthCommandProfiles: [OAuthCommandProfile] = [],
        roundRobinProfiles: [RoundRobinProfile] = [],
        accountOrder: [String] = [],
        bindAddress: String = "127.0.0.1",
        autostartServer: Bool = false,
        roundRobinEnabled: Bool = false,
        logLevel: LogLevel = .info
    ) {
        self.schemaVersion = schemaVersion
        self.port = port
        self.claudeAPI = claudeAPI
        self.codexAPI = codexAPI
        self.startAtLogin = startAtLogin
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
        self.showNotifications = showNotifications
        self.appearance = appearance
        self.subscriptionUsage = subscriptionUsage
        self.usageOverlay = usageOverlay
        self.oauthCommandProfiles = oauthCommandProfiles
        self.roundRobinProfiles = roundRobinProfiles
        self.accountOrder = accountOrder
        self.bindAddress = bindAddress
        self.autostartServer = autostartServer
        self.roundRobinEnabled = roundRobinEnabled
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case port
        case claudeAPI
        case codexAPI
        case startAtLogin
        case showDockIcon
        case showMenuBarIcon
        case showNotifications
        case appearance
        case subscriptionUsage
        case usageOverlay
        case oauthCommandProfiles
        case roundRobinProfiles
        case accountOrder
        case bindAddress
        case autostartServer
        case roundRobinEnabled
        case logLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = AppConfig(
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AppConfig.currentSchemaVersion,
            port: try c.decode(Int.self, forKey: .port),
            claudeAPI: try c.decodeIfPresent(ClaudeAPI.self, forKey: .claudeAPI) ?? ClaudeAPI(),
            codexAPI: try c.decodeIfPresent(CodexAPI.self, forKey: .codexAPI) ?? CodexAPI(),
            startAtLogin: try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false,
            showDockIcon: try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true,
            showMenuBarIcon: try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true,
            showNotifications: false,
            appearance: try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system,
            subscriptionUsage: try c.decodeIfPresent(SubscriptionUsage.self, forKey: .subscriptionUsage) ?? SubscriptionUsage(),
            usageOverlay: try c.decodeIfPresent(UsageOverlay.self, forKey: .usageOverlay) ?? UsageOverlay(),
            oauthCommandProfiles: try c.decodeIfPresent([OAuthCommandProfile].self, forKey: .oauthCommandProfiles) ?? [],
            roundRobinProfiles: try c.decodeIfPresent([RoundRobinProfile].self, forKey: .roundRobinProfiles) ?? [],
            accountOrder: try c.decodeIfPresent([String].self, forKey: .accountOrder) ?? [],
            bindAddress: try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1",
            autostartServer: try c.decodeIfPresent(Bool.self, forKey: .autostartServer) ?? false,
            roundRobinEnabled: false,
            logLevel: try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(AppConfig.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(port, forKey: .port)
        try c.encode(claudeAPI, forKey: .claudeAPI)
        try c.encode(codexAPI, forKey: .codexAPI)
        try c.encode(startAtLogin, forKey: .startAtLogin)
        try c.encode(showDockIcon, forKey: .showDockIcon)
        try c.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try c.encode(showNotifications, forKey: .showNotifications)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(subscriptionUsage, forKey: .subscriptionUsage)
        try c.encode(usageOverlay, forKey: .usageOverlay)
        try c.encode(oauthCommandProfiles, forKey: .oauthCommandProfiles)
        try c.encode(roundRobinProfiles, forKey: .roundRobinProfiles)
        try c.encode(accountOrder, forKey: .accountOrder)
        try c.encode(bindAddress, forKey: .bindAddress)
        try c.encode(autostartServer, forKey: .autostartServer)
        try c.encode(roundRobinEnabled, forKey: .roundRobinEnabled)
        try c.encode(logLevel, forKey: .logLevel)
    }

    #if DEBUG
    private static let defaultPort = 18_318
    #else
    private static let defaultPort = 18_317
    #endif

    public static let `default` = AppConfig(
        port: defaultPort,
        startAtLogin: false,
        showDockIcon: true,
        showMenuBarIcon: true,
        appearance: .system
    )
}

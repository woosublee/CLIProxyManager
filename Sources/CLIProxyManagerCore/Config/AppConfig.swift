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
    public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
        case direct
        case proxy
    }

    public struct Commands: Codable, Equatable, Sendable {
        public var cc: String
        public var ccapi: String
        public var ccodex: String
        public var ccodexapi: String

        public init(cc: String, ccapi: String, ccodex: String, ccodexapi: String = "") {
            self.cc = cc
            self.ccapi = ccapi
            self.ccodex = ccodex
            self.ccodexapi = ccodexapi
        }

        private enum CodingKeys: String, CodingKey {
            case cc, ccapi, ccodex, ccodexapi
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.cc = try container.decodeIfPresent(String.self, forKey: .cc) ?? ""
            self.ccapi = try container.decodeIfPresent(String.self, forKey: .ccapi) ?? ""
            self.ccodex = try container.decodeIfPresent(String.self, forKey: .ccodex) ?? ""
            self.ccodexapi = try container.decodeIfPresent(String.self, forKey: .ccodexapi) ?? ""
        }
    }

    public struct ClaudeAPI: Codable, Equatable, Sendable {
        public var claude: ClaudeRouting
        public var nickname: String
        public var dangerousPermissionsEnabled: Bool

        public var connectionMode: ConnectionMode { .proxy }

        public init(
            claude: ClaudeRouting = .automatic,
            nickname: String = "",
            dangerousPermissionsEnabled: Bool = false
        ) {
            self.claude = claude
            self.nickname = nickname
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case connectionMode, claude, nickname, dangerousPermissionsEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decodeIfPresent(ConnectionMode.self, forKey: .connectionMode)
            self.claude = try container.decodeIfPresent(ClaudeRouting.self, forKey: .claude) ?? .automatic
            self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
            self.dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
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

    public enum CodexContextWindow: String, Codable, CaseIterable, Sendable {
        case auto
        case context200k = "200k"
        case context400k = "400k"
        case context1m = "1m"
    }

    public struct CodexRole: Codable, Equatable, Sendable {
        public var model: String
        public var reasoning: CodexReasoning
        public var contextWindow: CodexContextWindow

        public init(model: String, reasoning: CodexReasoning, contextWindow: CodexContextWindow) {
            self.model = model
            self.reasoning = reasoning
            self.contextWindow = contextWindow
        }

        public var modelIdentifier: String {
            switch reasoning {
            case .auto:
                model
            case .low, .medium, .high, .xhigh, .max:
                "\(model)(\(reasoning.rawValue))"
            }
        }
    }

    public struct Codex: Codable, Equatable, Sendable {
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
        public var codex: Codex
        public var nickname: String
        public var dangerousPermissionsEnabled: Bool

        public init(codex: Codex, nickname: String = "", dangerousPermissionsEnabled: Bool = false) {
            self.codex = codex
            self.nickname = nickname
            self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case codex, nickname, dangerousPermissionsEnabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.codex = try container.decode(Codex.self, forKey: .codex)
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

    public struct Nicknames: Codable, Equatable, Sendable {
        public var cc: String
        public var ccodex: String

        public init(cc: String = "", ccodex: String = "") {
            self.cc = cc
            self.ccodex = ccodex
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

        public init(
            isVisible: Bool = false,
            alwaysOnTop: Bool = false,
            backgroundOpacity: Double = 0.9,
            displayMode: DisplayMode = .expanded
        ) {
            self.isVisible = isVisible
            self.alwaysOnTop = alwaysOnTop
            self.backgroundOpacity = min(max(backgroundOpacity, 0.2), 1)
            self.displayMode = displayMode
        }

        private enum CodingKeys: String, CodingKey {
            case isVisible, alwaysOnTop, backgroundOpacity, displayMode
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
        }
    }

    public struct AccountPrivacy: Codable, Equatable, Sendable {
        public var claudeHidden: Bool
        public var codexHidden: Bool

        public init(claudeHidden: Bool = true, codexHidden: Bool = true) {
            self.claudeHidden = claudeHidden
            self.codexHidden = codexHidden
        }

        private enum CodingKeys: String, CodingKey {
            case claudeHidden, codexHidden
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.claudeHidden = try c.decodeIfPresent(Bool.self, forKey: .claudeHidden) ?? true
            self.codexHidden = try c.decodeIfPresent(Bool.self, forKey: .codexHidden) ?? true
        }
    }

    public var port: Int
    public var commands: Commands
    public var ccapi: ClaudeAPI
    public var ccodex: Codex
    public var codexAPI: CodexAPI
    public var includeDangerouslySkipPermissions: Bool
    public var startAtLogin: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool
    public var showNotifications: Bool
    public var appearance: AppearanceMode
    public var nicknames: Nicknames
    public var accountPrivacy: AccountPrivacy
    public var subscriptionUsage: SubscriptionUsage
    public var usageOverlay: UsageOverlay

    public var isSubscriptionUsageEnabled: Bool {
        subscriptionUsage.showInMenuBar || usageOverlay.isVisible
    }

    public var oauthCommandProfiles: [OAuthCommandProfile]
    public var roundRobinProfiles: [RoundRobinProfile]
    public var bindAddress: String
    public var autostartServer: Bool
    public var roundRobinEnabled: Bool
    public var logLevel: LogLevel

    public init(
        port: Int,
        commands: Commands,
        ccapi: ClaudeAPI,
        ccodex: Codex,
        codexAPI: CodexAPI? = nil,
        includeDangerouslySkipPermissions: Bool,
        startAtLogin: Bool,
        showDockIcon: Bool,
        showMenuBarIcon: Bool,
        showNotifications: Bool = false,
        appearance: AppearanceMode = .system,
        nicknames: Nicknames = Nicknames(),
        accountPrivacy: AccountPrivacy = AccountPrivacy(),
        subscriptionUsage: SubscriptionUsage = SubscriptionUsage(),
        usageOverlay: UsageOverlay = UsageOverlay(),
        oauthCommandProfiles: [OAuthCommandProfile] = [],
        roundRobinProfiles: [RoundRobinProfile] = [],
        bindAddress: String = "127.0.0.1",
        autostartServer: Bool = false,
        roundRobinEnabled: Bool = false,
        logLevel: LogLevel = .info
    ) {
        self.port = port
        self.commands = commands
        self.ccapi = ccapi
        self.ccodex = ccodex
        self.codexAPI = codexAPI ?? CodexAPI(codex: ccodex)
        self.includeDangerouslySkipPermissions = includeDangerouslySkipPermissions
        self.startAtLogin = startAtLogin
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
        self.showNotifications = showNotifications
        self.appearance = appearance
        self.nicknames = nicknames
        self.accountPrivacy = accountPrivacy
        self.subscriptionUsage = subscriptionUsage
        self.usageOverlay = usageOverlay
        self.oauthCommandProfiles = oauthCommandProfiles
        self.roundRobinProfiles = roundRobinProfiles
        self.bindAddress = bindAddress
        self.autostartServer = autostartServer
        self.roundRobinEnabled = roundRobinEnabled
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case port, commands, ccapi, ccodex, codexAPI
        case includeDangerouslySkipPermissions
        case startAtLogin, showDockIcon, showMenuBarIcon
        case showNotifications
        case appearance
        case nicknames
        case accountPrivacy
        case subscriptionUsage
        case usageOverlay
        case oauthCommandProfiles
        case roundRobinProfiles
        case bindAddress, autostartServer, roundRobinEnabled
        case logLevel
    }

    private enum CodexAPIProbeKeys: String, CodingKey {
        case codex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try c.decode(Int.self, forKey: .port)
        self.commands = try c.decode(Commands.self, forKey: .commands)
        self.ccapi = try c.decode(ClaudeAPI.self, forKey: .ccapi)
        self.ccodex = try c.decode(Codex.self, forKey: .ccodex)
        if c.contains(.codexAPI) {
            let probe = try c.nestedContainer(keyedBy: CodexAPIProbeKeys.self, forKey: .codexAPI)
            if probe.contains(.codex) {
                self.codexAPI = try c.decode(CodexAPI.self, forKey: .codexAPI)
            } else {
                self.codexAPI = CodexAPI(codex: try c.decode(Codex.self, forKey: .codexAPI))
            }
        } else {
            self.codexAPI = CodexAPI(codex: self.ccodex)
        }
        self.includeDangerouslySkipPermissions = try c.decode(Bool.self, forKey: .includeDangerouslySkipPermissions)
        self.startAtLogin = try c.decode(Bool.self, forKey: .startAtLogin)
        self.showDockIcon = try c.decode(Bool.self, forKey: .showDockIcon)
        self.showMenuBarIcon = try c.decode(Bool.self, forKey: .showMenuBarIcon)
        self.showNotifications = false
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.nicknames = try c.decodeIfPresent(Nicknames.self, forKey: .nicknames) ?? Nicknames()
        self.accountPrivacy = try c.decodeIfPresent(AccountPrivacy.self, forKey: .accountPrivacy) ?? AccountPrivacy()
        self.subscriptionUsage = try c.decodeIfPresent(SubscriptionUsage.self, forKey: .subscriptionUsage) ?? SubscriptionUsage()
        self.usageOverlay = try c.decodeIfPresent(UsageOverlay.self, forKey: .usageOverlay) ?? UsageOverlay()
        self.oauthCommandProfiles = try c.decodeIfPresent([OAuthCommandProfile].self, forKey: .oauthCommandProfiles) ?? []
        self.roundRobinProfiles = try c.decodeIfPresent([RoundRobinProfile].self, forKey: .roundRobinProfiles) ?? []
        self.bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        self.autostartServer = try c.decodeIfPresent(Bool.self, forKey: .autostartServer) ?? false
        self.roundRobinEnabled = false
        self.logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
    }

    #if DEBUG
    private static let defaultPort = 18_318
    #else
    private static let defaultPort = 18_317
    #endif

    public static let `default` = AppConfig(
        port: defaultPort,
        commands: Commands(cc: "", ccapi: "", ccodex: ""),
        ccapi: ClaudeAPI(),
        ccodex: Codex(
            opus: CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh, contextWindow: .auto),
            sonnet: CodexRole(model: "gpt-5.6-terra", reasoning: .medium, contextWindow: .auto),
            haiku: CodexRole(model: "gpt-5.6-terra", reasoning: .low, contextWindow: .auto)
        ),
        includeDangerouslySkipPermissions: false,
        startAtLogin: false,
        showDockIcon: true,
        showMenuBarIcon: true,
        appearance: .system
    )
}

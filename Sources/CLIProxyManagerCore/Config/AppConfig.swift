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
    public struct Commands: Codable, Equatable, Sendable {
        public var cc: String
        public var ccapi: String
        public var ccodex: String

        public init(cc: String, ccapi: String, ccodex: String) {
            self.cc = cc
            self.ccapi = ccapi
            self.ccodex = ccodex
        }
    }

    public struct ClaudeAPI: Codable, Equatable, Sendable {
        public var model: String

        public init(model: String) {
            self.model = model
        }
    }

    public enum CodexReasoning: String, Codable, CaseIterable, Sendable {
        case auto
        case low
        case medium
        case high
        case xhigh
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
            case .low, .medium, .high, .xhigh:
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

    public struct Nicknames: Codable, Equatable, Sendable {
        public var cc: String
        public var ccodex: String

        public init(cc: String = "", ccodex: String = "") {
            self.cc = cc
            self.ccodex = ccodex
        }
    }

    public var port: Int
    public var commands: Commands
    public var ccapi: ClaudeAPI
    public var ccodex: Codex
    public var includeDangerouslySkipPermissions: Bool
    public var startAtLogin: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool
    public var showNotifications: Bool
    public var appearance: AppearanceMode
    public var nicknames: Nicknames
    public var bindAddress: String
    public var autostartServer: Bool
    public var roundRobinEnabled: Bool
    public var logLevel: LogLevel

    public init(
        port: Int,
        commands: Commands,
        ccapi: ClaudeAPI,
        ccodex: Codex,
        includeDangerouslySkipPermissions: Bool,
        startAtLogin: Bool,
        showDockIcon: Bool,
        showMenuBarIcon: Bool,
        showNotifications: Bool = true,
        appearance: AppearanceMode = .system,
        nicknames: Nicknames = Nicknames(),
        bindAddress: String = "127.0.0.1",
        autostartServer: Bool = false,
        roundRobinEnabled: Bool = false,
        logLevel: LogLevel = .info
    ) {
        self.port = port
        self.commands = commands
        self.ccapi = ccapi
        self.ccodex = ccodex
        self.includeDangerouslySkipPermissions = includeDangerouslySkipPermissions
        self.startAtLogin = startAtLogin
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
        self.showNotifications = showNotifications
        self.appearance = appearance
        self.nicknames = nicknames
        self.bindAddress = bindAddress
        self.autostartServer = autostartServer
        self.roundRobinEnabled = roundRobinEnabled
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case port, commands, ccapi, ccodex
        case includeDangerouslySkipPermissions
        case startAtLogin, showDockIcon, showMenuBarIcon
        case showNotifications
        case appearance
        case nicknames
        case bindAddress, autostartServer, roundRobinEnabled
        case logLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try c.decode(Int.self, forKey: .port)
        self.commands = try c.decode(Commands.self, forKey: .commands)
        self.ccapi = try c.decode(ClaudeAPI.self, forKey: .ccapi)
        self.ccodex = try c.decode(Codex.self, forKey: .ccodex)
        self.includeDangerouslySkipPermissions = try c.decode(Bool.self, forKey: .includeDangerouslySkipPermissions)
        self.startAtLogin = try c.decode(Bool.self, forKey: .startAtLogin)
        self.showDockIcon = try c.decode(Bool.self, forKey: .showDockIcon)
        self.showMenuBarIcon = try c.decode(Bool.self, forKey: .showMenuBarIcon)
        // Backwards-compat: existing config.json files won't have these keys.
        self.showNotifications = try c.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.nicknames = try c.decodeIfPresent(Nicknames.self, forKey: .nicknames) ?? Nicknames()
        self.bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        self.autostartServer = try c.decodeIfPresent(Bool.self, forKey: .autostartServer) ?? false
        self.roundRobinEnabled = try c.decodeIfPresent(Bool.self, forKey: .roundRobinEnabled) ?? false
        self.logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
    }

    public static let `default` = AppConfig(
        port: 18_317,
        commands: Commands(cc: "cc", ccapi: "ccapi", ccodex: "ccodex"),
        ccapi: ClaudeAPI(model: "claude-opus-4-7"),
        ccodex: Codex(
            opus: CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto),
            sonnet: CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
            haiku: CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
        ),
        includeDangerouslySkipPermissions: false,
        startAtLogin: false,
        showDockIcon: true,
        showMenuBarIcon: true,
        appearance: .system
    )
}

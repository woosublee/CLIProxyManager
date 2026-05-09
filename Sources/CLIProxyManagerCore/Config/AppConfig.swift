import Foundation

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

    public var port: Int
    public var commands: Commands
    public var ccapi: ClaudeAPI
    public var ccodex: Codex
    public var includeDangerouslySkipPermissions: Bool
    public var startAtLogin: Bool
    public var showDockIcon: Bool
    public var showMenuBarIcon: Bool

    public init(
        port: Int,
        commands: Commands,
        ccapi: ClaudeAPI,
        ccodex: Codex,
        includeDangerouslySkipPermissions: Bool,
        startAtLogin: Bool,
        showDockIcon: Bool,
        showMenuBarIcon: Bool
    ) {
        self.port = port
        self.commands = commands
        self.ccapi = ccapi
        self.ccodex = ccodex
        self.includeDangerouslySkipPermissions = includeDangerouslySkipPermissions
        self.startAtLogin = startAtLogin
        self.showDockIcon = showDockIcon
        self.showMenuBarIcon = showMenuBarIcon
    }

    public static let `default` = AppConfig(
        port: 18_317,
        commands: Commands(cc: "ccm", ccapi: "ccmapi", ccodex: "ccmcodex"),
        ccapi: ClaudeAPI(model: "claude-opus-4-7"),
        ccodex: Codex(
            opus: CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto),
            sonnet: CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto),
            haiku: CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto)
        ),
        includeDangerouslySkipPermissions: false,
        startAtLogin: false,
        showDockIcon: true,
        showMenuBarIcon: true
    )
}

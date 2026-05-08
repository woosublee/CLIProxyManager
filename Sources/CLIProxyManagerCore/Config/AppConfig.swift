import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public struct Commands: Codable, Equatable, Sendable {
        public var cc: String
        public var ccapi: String
        public var ccodex: String
    }

    public struct ClaudeAPI: Codable, Equatable, Sendable {
        public var model: String
    }

    public struct Codex: Codable, Equatable, Sendable {
        public var opusModel: String
        public var sonnetModel: String
        public var haikuModel: String
    }

    public var port: Int
    public var commands: Commands
    public var ccapi: ClaudeAPI
    public var ccodex: Codex
    public var includeDangerouslySkipPermissions: Bool

    public init(
        port: Int,
        commands: Commands,
        ccapi: ClaudeAPI,
        ccodex: Codex,
        includeDangerouslySkipPermissions: Bool
    ) {
        self.port = port
        self.commands = commands
        self.ccapi = ccapi
        self.ccodex = ccodex
        self.includeDangerouslySkipPermissions = includeDangerouslySkipPermissions
    }

    public static let `default` = AppConfig(
        port: 8317,
        commands: Commands(cc: "cc", ccapi: "ccapi", ccodex: "ccodex"),
        ccapi: ClaudeAPI(model: "claude-opus-4-7"),
        ccodex: Codex(
            opusModel: "gpt-5.5(xhigh)",
            sonnetModel: "gpt-5.5(xhigh)",
            haikuModel: "gpt-5.5(low)"
        ),
        includeDangerouslySkipPermissions: false
    )
}

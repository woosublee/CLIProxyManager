import Foundation

public protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
}

public protocol ProxyHealthChecking: Sendable {
    func status(port: Int) async -> DiagnosticStatus
}

extension ProxyHealthClient: ProxyHealthChecking {}

public struct ProxyHealthSummary: Codable, Equatable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public struct ProxyRuntimeStatus: Codable, Equatable, Sendable {
    public let port: Int
    public let running: Bool
    public let health: ProxyHealthSummary
    public let activeVersion: String?
    public let pendingVersion: String?

    public init(
        port: Int,
        running: Bool,
        health: ProxyHealthSummary,
        activeVersion: String?,
        pendingVersion: String?
    ) {
        self.port = port
        self.running = running
        self.health = health
        self.activeVersion = activeVersion
        self.pendingVersion = pendingVersion
    }
}

public protocol ProxyRuntimeServicing: Sendable {
    func status() async throws -> ProxyRuntimeStatus
    func start() async throws -> ProxyRuntimeStatus
    func stop() async throws -> ProxyRuntimeStatus
    func restart() async throws -> ProxyRuntimeStatus
}

public protocol ProxyLogServicing: Sendable {
    func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot
    func follow() throws
}

public struct ProxyLogSnapshot: Equatable, Sendable {
    public let fileURL: URL
    public let text: String

    public init(fileURL: URL, text: String) {
        self.fileURL = fileURL
        self.text = text
    }
}

public protocol LogFollowing: Sendable {
    func follow(fileURL: URL) throws
}

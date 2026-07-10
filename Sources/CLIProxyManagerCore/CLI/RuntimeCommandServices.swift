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

// MARK: - App lifecycle

public struct AppLifecycleStatus: Codable, Equatable, Sendable {
    public let installed: Bool
    public let running: Bool
    public let path: String?
    public let version: String?
    public let build: String?

    public init(installed: Bool, running: Bool, path: String?, version: String?, build: String?) {
        self.installed = installed
        self.running = running
        self.path = path
        self.version = version
        self.build = build
    }
}

public protocol AppLifecycleControlling: Sendable {
    func status() async throws -> AppLifecycleStatus
    func start() async throws -> AppLifecycleStatus
    func stop() async throws -> AppLifecycleStatus
    func restart() async throws -> AppLifecycleStatus
}

public protocol AppProcessInspecting: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

// MARK: - Status reporting

public struct CPMStatus: Codable, Equatable, Sendable {
    public let proxy: ProxyRuntimeStatus
    public let app: AppLifecycleStatus

    public init(proxy: ProxyRuntimeStatus, app: AppLifecycleStatus) {
        self.proxy = proxy
        self.app = app
    }
}

public protocol StatusReporting: Sendable {
    func status() async throws -> CPMStatus
}

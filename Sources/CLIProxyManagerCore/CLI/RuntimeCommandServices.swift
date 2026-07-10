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

    public static let ready = ProxyHealthSummary(title: "Running", message: "Ready")
    public static let stopped = ProxyHealthSummary(title: "Stopped", message: "Not running")
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

// MARK: - Helper inspection

public struct HelperStatus: Equatable, Sendable {
    public let path: String
    public let installed: Bool
    public let matchesBundled: Bool

    public init(path: String, installed: Bool, matchesBundled: Bool) {
        self.path = path
        self.installed = installed
        self.matchesBundled = matchesBundled
    }
}

public protocol HelperInspecting: Sendable {
    func inspect() -> HelperStatus
}

// MARK: - Status reporting

public struct CPMStatus: Codable, Equatable, Sendable {
    public let app: App
    public let helper: Helper
    public let proxy: Proxy

    public init(app: App, helper: Helper, proxy: Proxy) {
        self.app = app
        self.helper = helper
        self.proxy = proxy
    }

    public struct App: Codable, Equatable, Sendable {
        public let installed: Bool
        public let path: String?
        public let version: String?
        public let build: String?
        public let running: Bool
        public let stagedVersion: String?

        public init(installed: Bool, path: String?, version: String?, build: String?, running: Bool, stagedVersion: String?) {
            self.installed = installed
            self.path = path
            self.version = version
            self.build = build
            self.running = running
            self.stagedVersion = stagedVersion
        }
    }

    public struct Helper: Codable, Equatable, Sendable {
        public let path: String
        public let installed: Bool
        public let matchesBundled: Bool

        public init(path: String, installed: Bool, matchesBundled: Bool) {
            self.path = path
            self.installed = installed
            self.matchesBundled = matchesBundled
        }
    }

    public struct Proxy: Codable, Equatable, Sendable {
        public let port: Int
        public let running: Bool
        public let activeVersion: String?
        public let pendingVersion: String?
        public let stagedVersion: String?
        public let logsPath: String

        public init(port: Int, running: Bool, activeVersion: String?, pendingVersion: String?, stagedVersion: String?, logsPath: String) {
            self.port = port
            self.running = running
            self.activeVersion = activeVersion
            self.pendingVersion = pendingVersion
            self.stagedVersion = stagedVersion
            self.logsPath = logsPath
        }
    }
}

public protocol StatusReporting: Sendable {
    func status() async throws -> CPMStatus
}

// MARK: - Proxy update

public protocol ProxyUpdating: Sendable {
    func check() async throws -> ProxyUpdateCheckResult
    func stage() async throws -> ProxyUpdateStageResult
    func apply() async throws -> ProxyUpdateApplyResult
}

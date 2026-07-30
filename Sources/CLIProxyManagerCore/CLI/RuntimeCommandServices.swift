import Foundation

public protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
    func reconcileConfiguration(port: Int) async throws -> Bool
}

public extension ProxyServiceControlling {
    // Preserves source compatibility for test doubles; runtime implementations must override
    // this method or local-only reconciliation is intentionally reported as not performed.
    func reconcileConfiguration(port: Int) async throws -> Bool { false }
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
    public let compatibility: Compatibility

    public init(
        app: App,
        helper: Helper,
        proxy: Proxy,
        compatibility: Compatibility = .allowed
    ) {
        self.app = app
        self.helper = helper
        self.proxy = proxy
        self.compatibility = compatibility
    }

    public struct Compatibility: Codable, Equatable, Sendable {
        public struct Finding: Codable, Equatable, Sendable {
            public let code: String
            public let disposition: CompatibilityDisposition
            public let recovery: String

            public init(code: String, disposition: CompatibilityDisposition, recovery: String) {
                self.code = code
                self.disposition = disposition
                self.recovery = recovery
            }
        }

        public let disposition: CompatibilityDisposition
        public let findings: [Finding]

        public init(disposition: CompatibilityDisposition, findings: [Finding]) {
            self.disposition = disposition
            self.findings = findings
        }

        public init(report: RuntimeCompatibilityReport) {
            disposition = report.decision(for: .startProxy).disposition
            findings = report.findings.map(Self.finding)
        }

        public static let allowed = Self(disposition: .allowed, findings: [])

        private static func finding(_ finding: CompatibilityFinding) -> Finding {
            switch finding {
            case .unsupportedOperatingSystem:
                Finding(
                    code: "unsupportedOperatingSystem",
                    disposition: .blocked,
                    recovery: RuntimeCompatibilityBlocker.unsupportedOperatingSystem.recoveryMessage
                )
            case .unsupportedArchitecture:
                Finding(
                    code: "unsupportedArchitecture",
                    disposition: .blocked,
                    recovery: RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage
                )
            case .unsupportedArtifactTarget:
                Finding(
                    code: "unsupportedArtifactTarget",
                    disposition: .blocked,
                    recovery: RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage
                )
            case .unsupportedLoginShell:
                Finding(
                    code: "unsupportedLoginShell",
                    disposition: .allowedWithWarnings,
                    recovery: "Use zsh as the login shell before installing generated functions."
                )
            case .unavailableClaudeCode:
                Finding(
                    code: "unavailableClaudeCode",
                    disposition: .allowedWithWarnings,
                    recovery: "Install Claude Code, then refresh compatibility status."
                )
            case .unverifiedClaudeCode:
                Finding(
                    code: "unverifiedClaudeCode",
                    disposition: .allowedWithWarnings,
                    recovery: "Verify the Claude Code installation, then refresh compatibility status."
                )
            case .unverifiedClaudeCodeVersion:
                Finding(
                    code: "unverifiedClaudeCodeVersion",
                    disposition: .allowedWithWarnings,
                    recovery: "Update Claude Code or continue with caution; refresh after updating."
                )
            }
        }
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

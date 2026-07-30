import Foundation

public struct CLIProxyAPIArtifactTarget: Codable, Equatable, Sendable {
    public enum OperatingSystem: String, Codable, Sendable {
        case darwin
    }

    public enum Architecture: String, Codable, Sendable {
        case arm64
        case x86_64
    }

    public let operatingSystem: OperatingSystem
    public let architecture: Architecture

    public init(operatingSystem: OperatingSystem, architecture: Architecture) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static let darwinArm64 = Self(operatingSystem: .darwin, architecture: .arm64)
}

public enum CompatibilityAction: String, CaseIterable, Codable, Sendable {
    case inspect
    case stopProxy
    case startProxy
    case restartProxy
    case prepareOAuthLogin
    case prepareModelServer
    case stageProxyUpdate
    case applyProxyUpdate
    case scheduleProxyUpdate
    case installShellFunctions
    case recoverProxyArtifact
}

public enum CompatibilityDisposition: String, Codable, Sendable {
    case allowed
    case allowedWithWarnings
    case blocked
}

public struct RuntimeCompatibilityEnvironment: Codable, Equatable, Sendable {
    public enum OperatingSystem: Codable, Equatable, Sendable {
        case macOS(major: Int, minor: Int)
    }

    public typealias Architecture = CLIProxyAPIArtifactTarget.Architecture

    public let operatingSystem: OperatingSystem
    public let architecture: Architecture
    public let isTranslated: Bool
    public let loginShell: String

    public init(
        operatingSystem: OperatingSystem,
        architecture: Architecture,
        isTranslated: Bool = false,
        loginShell: String
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.isTranslated = isTranslated
        self.loginShell = loginShell.isEmpty ? "" : URL(fileURLWithPath: loginShell).lastPathComponent
    }
}

public typealias RuntimeEnvironmentSnapshot = RuntimeCompatibilityEnvironment

public enum RuntimeCompatibilityArtifact: Codable, Equatable, Sendable {
    case explicit(CLIProxyAPIArtifactTarget)
    case legacy
}

public struct RuntimeCompatibilityArtifacts: Codable, Equatable, Sendable {
    public let bundled: RuntimeCompatibilityArtifact?
    public let active: RuntimeCompatibilityArtifact?
    public let pending: RuntimeCompatibilityArtifact?

    public init(
        bundled: RuntimeCompatibilityArtifact?,
        active: RuntimeCompatibilityArtifact?,
        pending: RuntimeCompatibilityArtifact?
    ) {
        self.bundled = bundled
        self.active = active
        self.pending = pending
    }
}

public typealias CompatibilityArtifacts = RuntimeCompatibilityArtifacts

public enum ClaudeCodeObservation: Codable, Equatable, Sendable {
    case notChecked
    case version(String)
    case unavailable
    case unverified
}

public typealias RuntimeCompatibilityClaude = ClaudeCodeObservation

public enum CompatibilityFinding: Codable, Equatable, Sendable {
    case unsupportedOperatingSystem(minimumMajor: Int, actualMajor: Int)
    case unsupportedArchitecture(
        expected: CLIProxyAPIArtifactTarget.Architecture,
        actual: CLIProxyAPIArtifactTarget.Architecture
    )
    case unsupportedArtifactTarget(
        expected: CLIProxyAPIArtifactTarget,
        actual: CLIProxyAPIArtifactTarget
    )
    case unsupportedLoginShell(expectedBasename: String, actualBasename: String)
    case unavailableClaudeCode
    case unverifiedClaudeCode
    case unverifiedClaudeCodeVersion(expected: String, actual: String)
}

public struct CompatibilityDecision: Codable, Equatable, Sendable {
    public let action: CompatibilityAction
    public let disposition: CompatibilityDisposition

    public init(action: CompatibilityAction, disposition: CompatibilityDisposition) {
        self.action = action
        self.disposition = disposition
    }
}

public struct RuntimeCompatibilityReport: Codable, Equatable, Sendable {
    public let findings: [CompatibilityFinding]
    private let decisions: [CompatibilityAction: CompatibilityDecision]

    public init(
        findings: [CompatibilityFinding],
        decisions: [CompatibilityAction: CompatibilityDecision]
    ) {
        self.findings = findings
        self.decisions = decisions
    }

    public func decision(for action: CompatibilityAction) -> CompatibilityDecision {
        decisions[action] ?? CompatibilityDecision(action: action, disposition: .blocked)
    }
}

public struct RuntimeCompatibilityPolicy: Equatable, Sendable {
    public let minimumMacOSMajor: Int
    public let supportedArtifactTarget: CLIProxyAPIArtifactTarget
    public let requiredLoginShellPath: String
    public let lastVerifiedClaudeCodeVersion: String

    public init(
        minimumMacOSMajor: Int,
        supportedArtifactTarget: CLIProxyAPIArtifactTarget,
        requiredLoginShellPath: String,
        lastVerifiedClaudeCodeVersion: String
    ) {
        self.minimumMacOSMajor = minimumMacOSMajor
        self.supportedArtifactTarget = supportedArtifactTarget
        self.requiredLoginShellPath = requiredLoginShellPath
        self.lastVerifiedClaudeCodeVersion = lastVerifiedClaudeCodeVersion
    }

    public static let current = Self(
        minimumMacOSMajor: 15,
        supportedArtifactTarget: .darwinArm64,
        requiredLoginShellPath: "/bin/zsh",
        lastVerifiedClaudeCodeVersion: "2.1.220"
    )

    public func report(
        environment: RuntimeCompatibilityEnvironment,
        artifacts: RuntimeCompatibilityArtifacts,
        claude: RuntimeCompatibilityClaude
    ) -> RuntimeCompatibilityReport {
        let findings = findings(
            environment: environment,
            artifacts: artifacts,
            claude: claude
        )
        let hasWarnings = !findings.isEmpty
        let decisions = Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
            let blockingFindings = findings.filter { isBlocking($0, for: action) }
            let disposition: CompatibilityDisposition
            if allowsRecovery(action) {
                disposition = hasWarnings ? .allowedWithWarnings : .allowed
            } else if !blockingFindings.isEmpty {
                disposition = .blocked
            } else {
                disposition = hasWarnings ? .allowedWithWarnings : .allowed
            }

            return (action, CompatibilityDecision(action: action, disposition: disposition))
        })

        return RuntimeCompatibilityReport(findings: findings, decisions: decisions)
    }

    private func findings(
        environment: RuntimeCompatibilityEnvironment,
        artifacts: RuntimeCompatibilityArtifacts,
        claude: RuntimeCompatibilityClaude
    ) -> [CompatibilityFinding] {
        var findings: [CompatibilityFinding] = []

        if case let .macOS(major, _) = environment.operatingSystem, major < minimumMacOSMajor {
            findings.append(.unsupportedOperatingSystem(minimumMajor: minimumMacOSMajor, actualMajor: major))
        }

        if environment.architecture != supportedArtifactTarget.architecture {
            findings.append(
                .unsupportedArchitecture(
                    expected: supportedArtifactTarget.architecture,
                    actual: environment.architecture
                )
            )
        }

        for artifact in [artifacts.bundled, artifacts.active, artifacts.pending].compactMap({ $0 }) {
            let target = inferredTarget(for: artifact)
            if target != supportedArtifactTarget {
                findings.append(
                    .unsupportedArtifactTarget(expected: supportedArtifactTarget, actual: target)
                )
            }
        }

        let expectedShellBasename = URL(fileURLWithPath: requiredLoginShellPath).lastPathComponent
        let actualShellBasename = URL(fileURLWithPath: environment.loginShell).lastPathComponent
        if actualShellBasename != expectedShellBasename {
            findings.append(
                .unsupportedLoginShell(
                    expectedBasename: expectedShellBasename,
                    actualBasename: actualShellBasename
                )
            )
        }

        switch claude {
        case let .version(actualVersion) where actualVersion != lastVerifiedClaudeCodeVersion:
            findings.append(
                .unverifiedClaudeCodeVersion(
                    expected: lastVerifiedClaudeCodeVersion,
                    actual: actualVersion
                )
            )
        case .unavailable:
            findings.append(.unavailableClaudeCode)
        case .unverified:
            findings.append(.unverifiedClaudeCode)
        case .notChecked, .version:
            break
        }

        return findings
    }

    private func inferredTarget(for artifact: RuntimeCompatibilityArtifact) -> CLIProxyAPIArtifactTarget {
        switch artifact {
        case let .explicit(target):
            return target
        case .legacy:
            return supportedArtifactTarget
        }
    }

    private func isBlocking(_ finding: CompatibilityFinding) -> Bool {
        switch finding {
        case .unsupportedOperatingSystem, .unsupportedArchitecture, .unsupportedArtifactTarget:
            return true
        case .unsupportedLoginShell,
             .unavailableClaudeCode,
             .unverifiedClaudeCode,
             .unverifiedClaudeCodeVersion:
            return false
        }
    }

    private func isBlocking(_ finding: CompatibilityFinding, for action: CompatibilityAction) -> Bool {
        if isBlocking(finding) {
            return true
        }

        if case .unsupportedLoginShell = finding {
            return action == .installShellFunctions
        }

        return false
    }

    private func allowsRecovery(_ action: CompatibilityAction) -> Bool {
        switch action {
        case .inspect, .stopProxy, .recoverProxyArtifact:
            return true
        case .startProxy,
             .restartProxy,
             .prepareOAuthLogin,
             .prepareModelServer,
             .stageProxyUpdate,
             .applyProxyUpdate,
             .scheduleProxyUpdate,
             .installShellFunctions:
            return false
        }
    }
}

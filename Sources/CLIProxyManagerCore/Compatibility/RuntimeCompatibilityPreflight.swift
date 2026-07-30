import Darwin
import Foundation

public protocol RuntimeCompatibilityAuthorizing: Sendable {
    func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport
    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport
    func require(_ action: CompatibilityAction, artifacts: CompatibilityArtifacts) throws
}

public protocol RuntimeEnvironmentProviding: Sendable {
    func snapshot() -> RuntimeEnvironmentSnapshot
}

public enum RuntimeCompatibilityError: Error, Equatable, Sendable {
    case actionBlocked(CompatibilityAction)
}

public struct LiveRuntimeEnvironmentProvider: RuntimeEnvironmentProviding, Sendable {
    private let operatingSystem: @Sendable () -> RuntimeEnvironmentSnapshot.OperatingSystem
    private let nativeArchitecture: @Sendable () -> RuntimeEnvironmentSnapshot.Architecture
    private let translationState: @Sendable () -> Bool
    private let loginShell: @Sendable () -> String

    public init() {
        operatingSystem = { Self.currentOperatingSystem() }
        nativeArchitecture = { Self.currentNativeArchitecture() }
        translationState = { Self.currentTranslationState() }
        loginShell = { Self.currentLoginShell() }
    }

    public init(
        operatingSystem: @escaping @Sendable () -> RuntimeEnvironmentSnapshot.OperatingSystem,
        nativeArchitecture: @escaping @Sendable () -> RuntimeEnvironmentSnapshot.Architecture,
        isTranslated: @escaping @Sendable () -> Bool,
        loginShell: @escaping @Sendable () -> String
    ) {
        self.operatingSystem = operatingSystem
        self.nativeArchitecture = nativeArchitecture
        translationState = isTranslated
        self.loginShell = loginShell
    }

    public func snapshot() -> RuntimeEnvironmentSnapshot {
        RuntimeEnvironmentSnapshot(
            operatingSystem: operatingSystem(),
            architecture: nativeArchitecture(),
            isTranslated: translationState(),
            loginShell: loginShell()
        )
    }

    private static func currentOperatingSystem() -> RuntimeEnvironmentSnapshot.OperatingSystem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return .macOS(major: version.majorVersion, minor: version.minorVersion)
    }

    private static func currentNativeArchitecture() -> RuntimeEnvironmentSnapshot.Architecture {
        var arm64Available: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm64Available, &size, nil, 0) == 0,
           arm64Available == 1
        {
            return .arm64
        }
        return .x86_64
    }

    private static func currentTranslationState() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }

    private static func currentLoginShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? ""
    }

}

public struct RuntimeCompatibilityPreflight: RuntimeCompatibilityAuthorizing, Sendable {
    private let policy: RuntimeCompatibilityPolicy
    private let environment: RuntimeEnvironmentProviding
    private let claudeInspector: ClaudeCodeInspecting

    public init(
        policy: RuntimeCompatibilityPolicy = .current,
        environment: RuntimeEnvironmentProviding = LiveRuntimeEnvironmentProvider(),
        claudeInspector: ClaudeCodeInspecting = ClaudeCodeInspector()
    ) {
        self.policy = policy
        self.environment = environment
        self.claudeInspector = claudeInspector
    }

    public func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        policy.report(
            environment: environment.snapshot(),
            artifacts: artifacts,
            claude: .notChecked
        )
    }

    public func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        policy.report(
            environment: environment.snapshot(),
            artifacts: artifacts,
            claude: await claudeInspector.observeVersion()
        )
    }

    public func require(_ action: CompatibilityAction, artifacts: CompatibilityArtifacts) throws {
        guard staticReport(artifacts: artifacts).decision(for: action).disposition != .blocked else {
            throw RuntimeCompatibilityError.actionBlocked(action)
        }
    }
}

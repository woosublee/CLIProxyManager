import Foundation

public enum OAuthLoginProvider: Equatable, Sendable {
    case claude
    case codex

    public var authProfileType: AuthProfileType {
        switch self {
        case .claude:
            .claude
        case .codex:
            .codex
        }
    }

    var loginFlag: String {
        switch self {
        case .claude:
            "-claude-login"
        case .codex:
            "-codex-login"
        }
    }

    var displayName: String {
        switch self {
        case .claude:
            "Claude OAuth"
        case .codex:
            "Codex OAuth"
        }
    }
}

public enum OAuthLoginError: LocalizedError, Equatable {
    case failed(provider: OAuthLoginProvider, exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(provider, exitCode, message):
            let detail = message.isEmpty ? "The process exited without an error message." : message
            return "\(provider.displayName) login failed(exit \(exitCode)): \(detail)"
        }
    }
}

public struct OAuthLoginService: Sendable {
    private let paths: ManagedPaths
    private let runtimePreparer: any ProxyRuntimePreparing
    private let runner: any ProcessRunning

    public init(
        paths: ManagedPaths = ManagedPaths(),
        runtimePreparer: any ProxyRuntimePreparing,
        runner: any ProcessRunning = ProcessRunner(timeout: 300)
    ) {
        self.paths = paths
        self.runtimePreparer = runtimePreparer
        self.runner = runner
    }

    public func login(provider: OAuthLoginProvider, port: Int) async throws {
        try runtimePreparer.prepare(port: port)

        let result = await runner.run(
            paths.clipProxyBinary.path,
            ["--config", paths.clipProxyConfigFile.path, provider.loginFlag]
        )
        try Task.checkCancellation()

        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OAuthLoginError.failed(provider: provider, exitCode: result.exitCode, message: message)
        }
    }
}

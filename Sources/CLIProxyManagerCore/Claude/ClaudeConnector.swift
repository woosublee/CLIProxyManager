import Foundation

public protocol ClaudeCodeInspecting: Sendable {
    func observeVersion() async -> ClaudeCodeObservation
}

private func userLocalClaudeExecutablePaths() -> [String] {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        homeDirectory.appendingPathComponent(".local/bin/claude").path,
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]
    return candidates.filter(FileManager.default.isExecutableFile(atPath:))
}

private func claudeExecutableCandidates(
    pathLookupSucceeded: Bool,
    fallbackPaths: [String]
) -> [String] {
    var candidates = pathLookupSucceeded ? ["claude"] : []
    for path in fallbackPaths where !candidates.contains(path) {
        candidates.append(path)
    }
    return candidates
}

private func runClaude(
    using runner: any ProcessRunning,
    executable: String,
    arguments: [String]
) async -> ProcessResult {
    guard executable.contains("/") else {
        return await runner.run("/usr/bin/env", [executable] + arguments)
    }
    let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return await runner.run(
        "/usr/bin/env",
        ["PATH=\(directory):\(inheritedPath)", executable] + arguments
    )
}

public struct ClaudeCodeInspector: ClaudeCodeInspecting, Sendable {
    private static let maximumVersionOutputLength = 512

    private let runner: ProcessRunning
    private let fallbackExecutablePaths: @Sendable () -> [String]

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.init(
            runner: runner,
            fallbackExecutablePaths: { userLocalClaudeExecutablePaths() }
        )
    }

    init(
        runner: ProcessRunning,
        fallbackExecutablePaths: @escaping @Sendable () -> [String]
    ) {
        self.runner = runner
        self.fallbackExecutablePaths = fallbackExecutablePaths
    }

    public func observeVersion() async -> ClaudeCodeObservation {
        let which = await runner.run("/usr/bin/env", ["which", "claude"])
        let candidates = claudeExecutableCandidates(
            pathLookupSucceeded: which.exitCode == 0,
            fallbackPaths: fallbackExecutablePaths()
        )
        guard !candidates.isEmpty else { return .unavailable }

        for executable in candidates {
            let version = await runClaude(using: runner, executable: executable, arguments: ["--version"])
            guard version.exitCode == 0 else { continue }
            return semanticVersion(in: version.stdout).map(ClaudeCodeObservation.version) ?? .unverified
        }
        return .unverified
    }

    private func semanticVersion(in output: String) -> String? {
        let boundedOutput = String(output.prefix(Self.maximumVersionOutputLength))
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![0-9])([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])"#
        ) else {
            return nil
        }
        let range = NSRange(boundedOutput.startIndex..., in: boundedOutput)
        guard let match = expression.firstMatch(in: boundedOutput, range: range),
              let versionRange = Range(match.range(at: 1), in: boundedOutput)
        else {
            return nil
        }
        return String(boundedOutput[versionRange])
    }
}

public struct ClaudeConnector: Sendable {
    private let runner: ProcessRunning
    private let fallbackExecutablePaths: @Sendable () -> [String]

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.init(
            runner: runner,
            fallbackExecutablePaths: { userLocalClaudeExecutablePaths() }
        )
    }

    init(
        runner: ProcessRunning,
        fallbackExecutablePaths: @escaping @Sendable () -> [String]
    ) {
        self.runner = runner
        self.fallbackExecutablePaths = fallbackExecutablePaths
    }

    public func status() async -> DiagnosticStatus {
        let which = await runner.run("/usr/bin/env", ["which", "claude"])
        if which.timedOut {
            return DiagnosticStatus(
                severity: .error,
                title: "Claude Code Check Timed Out",
                message: timeoutMessage(from: which)
            )
        }

        let candidates = claudeExecutableCandidates(
            pathLookupSucceeded: which.exitCode == 0,
            fallbackPaths: fallbackExecutablePaths()
        )
        guard !candidates.isEmpty else {
            return DiagnosticStatus(
                severity: .error,
                title: "Claude Code Not Installed",
                message: "Install the Claude Code CLI, then check again."
            )
        }

        var selectedExecutable: String?
        var lastVersionResult: ProcessResult?
        for executable in candidates {
            let version = await runClaude(using: runner, executable: executable, arguments: ["--version"])
            lastVersionResult = version
            if version.exitCode == 0 {
                selectedExecutable = executable
                break
            }
        }
        guard let selectedExecutable, let version = lastVersionResult else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude Code Check Failed",
                message: lastVersionResult.map(versionFailureMessage(from:))
                    ?? "Could not determine the Claude Code version."
            )
        }

        let auth = await runClaude(
            using: runner,
            executable: selectedExecutable,
            arguments: ["auth", "status"]
        )
        guard auth.exitCode == 0 else {
            if auth.timedOut {
                return DiagnosticStatus(
                    severity: .warning,
                    title: "Claude Login Check Timed Out",
                    message: timeoutMessage(from: auth)
                )
            }
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude Login Required",
                message: "Click the login button in the app to run claude auth login."
            )
        }

        return DiagnosticStatus(
            severity: .ready,
            title: "Claude Code Connected",
            message: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func loginCommand() -> [String] {
        ["claude", "auth", "login"]
    }

    public func logoutCommand() -> [String] {
        ["claude", "auth", "logout"]
    }

    private func versionFailureMessage(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty == false {
            return stdout
        }

        return "Could not determine the Claude Code version."
    }

    private func timeoutMessage(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        return "The command timed out."
    }
}

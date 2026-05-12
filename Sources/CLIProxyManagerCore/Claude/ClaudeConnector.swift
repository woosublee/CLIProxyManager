import Foundation

public struct ClaudeConnector: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func status() async -> DiagnosticStatus {
        let which = await runner.run("/usr/bin/env", ["which", "claude"])
        guard which.exitCode == 0 else {
            if which.timedOut {
                return DiagnosticStatus(
                    severity: .error,
                    title: "Claude Code Check Timed Out",
                    message: timeoutMessage(from: which)
                )
            }
            return DiagnosticStatus(
                severity: .error,
                title: "Claude Code Not Installed",
                message: "Install the Claude Code CLI, then check again."
            )
        }

        let version = await runner.run("/usr/bin/env", ["claude", "--version"])
        guard version.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude Code Check Failed",
                message: versionFailureMessage(from: version)
            )
        }

        let auth = await runner.run("/usr/bin/env", ["claude", "auth", "status"])
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

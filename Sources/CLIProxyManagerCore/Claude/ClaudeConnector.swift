import Foundation

public struct ClaudeConnector: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func status() async -> DiagnosticStatus {
        let which = await runner.run("/usr/bin/env", ["which", "claude"])
        guard which.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .error,
                title: "Claude Code 미설치",
                message: "Claude Code CLI를 설치한 뒤 다시 확인하세요."
            )
        }

        let version = await runner.run("/usr/bin/env", ["claude", "--version"])
        guard version.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude Code 확인 실패",
                message: version.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let auth = await runner.run("/usr/bin/env", ["claude", "auth", "status"])
        guard auth.exitCode == 0 else {
            return DiagnosticStatus(
                severity: .warning,
                title: "Claude 로그인 필요",
                message: "앱에서 로그인 버튼을 눌러 claude auth login을 실행하세요."
            )
        }

        return DiagnosticStatus(
            severity: .ready,
            title: "Claude Code 연결됨",
            message: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func loginCommand() -> [String] {
        ["claude", "auth", "login"]
    }

    public func logoutCommand() -> [String] {
        ["claude", "auth", "logout"]
    }
}

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
                    title: "Claude Code 확인 시간 초과",
                    message: timeoutMessage(from: which)
                )
            }
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
                message: versionFailureMessage(from: version)
            )
        }

        let auth = await runner.run("/usr/bin/env", ["claude", "auth", "status"])
        guard auth.exitCode == 0 else {
            if auth.timedOut {
                return DiagnosticStatus(
                    severity: .warning,
                    title: "Claude 로그인 상태 확인 시간 초과",
                    message: timeoutMessage(from: auth)
                )
            }
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

    private func versionFailureMessage(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty == false {
            return stdout
        }

        return "Claude Code 버전을 확인하지 못했습니다."
    }

    private func timeoutMessage(from result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty == false {
            return stderr
        }

        return "명령 실행 시간이 초과되었습니다."
    }
}

public struct ProfileCard: Equatable, Identifiable, Sendable {
    public let id: String
    public let command: String
    public let title: String
    public let subtitle: String
    public let status: DiagnosticStatus

    public init(command: String, title: String, subtitle: String, status: DiagnosticStatus) {
        self.id = command
        self.command = command
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }

    public func updatingStatus(_ status: DiagnosticStatus) -> ProfileCard {
        ProfileCard(command: command, title: title, subtitle: subtitle, status: status)
    }

    public static func makeDefaultCards(config: AppConfig) -> [ProfileCard] {
        let pendingStatus = DiagnosticStatus(
            severity: .warning,
            title: "확인 필요",
            message: "상태 확인 전입니다."
        )

        return [
            ProfileCard(
                command: config.commands.cc,
                title: "Claude 구독",
                subtitle: "Claude Code 공식 로그인 사용",
                status: pendingStatus
            ),
            ProfileCard(
                command: config.commands.ccodex,
                title: "OpenAI/Codex",
                subtitle: "CLIProxyAPI 경유",
                status: pendingStatus
            )
        ]
    }
}

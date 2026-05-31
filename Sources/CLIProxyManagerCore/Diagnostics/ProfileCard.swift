public struct ProfileCard: Equatable, Identifiable, Sendable {
    public static let claudeID = "claude"
    public static let codexID = "codex"

    public let id: String
    public let command: String
    public let title: String
    public let subtitle: String
    public let status: DiagnosticStatus

    public init(id: String? = nil, command: String, title: String, subtitle: String, status: DiagnosticStatus) {
        self.id = id ?? command
        self.command = command
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }

    public func updatingStatus(_ status: DiagnosticStatus) -> ProfileCard {
        ProfileCard(id: id, command: command, title: title, subtitle: subtitle, status: status)
    }

    public static func makeDefaultCards(config: AppConfig) -> [ProfileCard] {
        let pendingStatus = DiagnosticStatus(
            severity: .warning,
            title: "Needs check",
            message: "Status has not been checked yet."
        )

        return [
            ProfileCard(
                id: Self.claudeID,
                command: config.commands.cc,
                title: "Claude Subscription",
                subtitle: "Uses the official Claude Code login",
                status: pendingStatus
            ),
            ProfileCard(
                id: Self.codexID,
                command: config.commands.ccodex,
                title: "OpenAI/Codex",
                subtitle: "Routed through CLIProxyAPI",
                status: pendingStatus
            )
        ]
    }
}

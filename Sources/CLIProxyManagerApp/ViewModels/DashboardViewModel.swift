import Combine
import CLIProxyManagerCore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus

    private let config: AppConfig
    private let proxyHealthClient: ProxyHealthClient
    private let claudeConnector: ClaudeConnector

    init(
        config: AppConfig = .default,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        claudeConnector: ClaudeConnector = ClaudeConnector()
    ) {
        self.config = config
        self.proxyHealthClient = proxyHealthClient
        self.claudeConnector = claudeConnector
        cards = ProfileCard.makeDefaultCards(config: config)
        serverStatus = DiagnosticStatus(
            severity: .warning,
            title: "확인 필요",
            message: "서버 상태 확인 전입니다."
        )
    }

    func refresh() async {
        let updatedServerStatus = await proxyHealthClient.status(port: config.port)
        let claudeStatus = await claudeConnector.status()
        serverStatus = updatedServerStatus

        cards = cards.map { card in
            switch card.command {
            case config.commands.cc:
                card.updatingStatus(claudeStatus)
            case config.commands.ccodex:
                card.updatingStatus(updatedServerStatus)
            default:
                card
            }
        }
    }
}

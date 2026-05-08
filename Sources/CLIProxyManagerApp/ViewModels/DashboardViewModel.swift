import Combine
import CLIProxyManagerCore

protocol ProxyServiceStarting: Sendable {
    func start(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceStarting {}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus

    private let config: AppConfig
    private let proxyHealthClient: ProxyHealthClient
    private let proxyService: any ProxyServiceStarting
    private let claudeConnector: ClaudeConnector

    init(
        config: AppConfig = .default,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        proxyService: any ProxyServiceStarting = BundledProxyBinary.serviceManager(),
        claudeConnector: ClaudeConnector = ClaudeConnector()
    ) {
        self.config = config
        self.proxyHealthClient = proxyHealthClient
        self.proxyService = proxyService
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
        updateStatuses(serverStatus: updatedServerStatus, claudeStatus: claudeStatus)
    }

    func startServer() async {
        do {
            try await proxyService.start(port: config.port)
            await refresh()
        } catch {
            updateStatuses(
                serverStatus: DiagnosticStatus(
                    severity: .error,
                    title: "CLIProxyAPI 시작 실패",
                    message: error.localizedDescription
                ),
                claudeStatus: nil
            )
        }
    }

    private func updateStatuses(serverStatus updatedServerStatus: DiagnosticStatus, claudeStatus: DiagnosticStatus?) {
        serverStatus = updatedServerStatus

        cards = cards.map { card in
            switch card.command {
            case config.commands.cc:
                if let claudeStatus {
                    card.updatingStatus(claudeStatus)
                } else {
                    card
                }
            case config.commands.ccodex:
                card.updatingStatus(updatedServerStatus)
            default:
                card
            }
        }
    }
}

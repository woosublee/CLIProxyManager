import Combine
import CLIProxyManagerCore

protocol ProxyServiceControlling: Sendable {
    func start(port: Int) async throws
    func stop() async throws
    func restart(port: Int) async throws
}

extension ProxyServiceManager: ProxyServiceControlling {}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var cards: [ProfileCard]
    @Published var serverStatus: DiagnosticStatus
    @Published var isServerActionInProgress = false

    private let config: AppConfig
    private let proxyHealthClient: ProxyHealthClient
    private let proxyService: any ProxyServiceControlling
    private let claudeConnector: ClaudeConnector

    init(
        config: AppConfig = .default,
        proxyHealthClient: ProxyHealthClient = ProxyHealthClient(),
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
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
        await performServerAction(title: "CLIProxyAPI 시작 실패") {
            try await proxyService.start(port: config.port)
        }
    }

    func stopServer() async {
        await performServerAction(title: "CLIProxyAPI 중지 실패") {
            try await proxyService.stop()
        }
    }

    func restartServer() async {
        await performServerAction(title: "CLIProxyAPI 재시작 실패") {
            try await proxyService.restart(port: config.port)
        }
    }

    private func performServerAction(title: String, action: () async throws -> Void) async {
        guard isServerActionInProgress == false else { return }

        isServerActionInProgress = true
        defer { isServerActionInProgress = false }

        do {
            try await action()
            await refresh()
        } catch {
            updateStatuses(
                serverStatus: DiagnosticStatus(
                    severity: .error,
                    title: title,
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

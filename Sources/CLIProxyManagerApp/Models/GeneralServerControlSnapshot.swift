import CLIProxyManagerCore

struct GeneralServerControlSnapshot: Equatable {
    let title = "CLIProxyAPI Server"
    let statusTitle: String
    let statusDetail: String
    let isRunning: Bool

    var actionTitle: String {
        isRunning ? "Stop Server" : "Start Server"
    }

    init(status: DiagnosticStatus) {
        statusTitle = status.title
        statusDetail = status.message
        isRunning = status.severity == .ready
    }
}

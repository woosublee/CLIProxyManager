import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class MenuBarStatusSnapshotTests: XCTestCase {
    func testSnapshotShowsServerStatusAndConnectedProviderFunctionNames() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Connected",
                    connectionDetail: "codex@example.com",
                    isConnected: true
                )
            ]
        )

        XCTAssertEqual(snapshot.serverTitle, "CLIProxyAPI Running")
        XCTAssertEqual(snapshot.serverDetail, "Models are available on port 18317.")
        XCTAssertTrue(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Stop Server")
        XCTAssertEqual(snapshot.endpointTitle, "localhost:18317")
        XCTAssertEqual(snapshot.connectedProviders.map { $0.name }, ["Claude OAuth", "Codex OAuth"])
        XCTAssertEqual(snapshot.connectedProviders.map { $0.functionName }, ["ccm", "ccmcodex"])
        XCTAssertEqual(snapshot.connectedProviders.map { $0.connectionDetail }, ["claude@example.com", "codex@example.com"])
    }

    func testSnapshotShowsEmptyMessageWhenNoProviderIsConnected() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .warning,
                title: "Needs check",
                message: "Server status has not been checked yet."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Needs check",
                    connectionDetail: "Check the Claude Code OAuth status.",
                    isConnected: false
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders, [])
        XCTAssertFalse(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Start Server")
        XCTAssertEqual(snapshot.endpointTitle, nil)
        XCTAssertEqual(snapshot.emptyProviderMessage, "No connected accounts")
    }

    func testSnapshotCountsErroredProvidersFromStructuredState() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Authentication failed",
                    connectionDetail: "The token has expired.",
                    isConnected: false,
                    isErrored: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Needs connection",
                    connectionDetail: "Connect the Codex OAuth profile.",
                    isConnected: false
                )
            ]
        )

        XCTAssertEqual(snapshot.erroredCount, 1)
    }
}

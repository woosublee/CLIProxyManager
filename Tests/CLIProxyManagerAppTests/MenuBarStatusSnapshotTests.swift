import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class MenuBarStatusSnapshotTests: XCTestCase {
    func testSnapshotShowsServerStatusAndConnectedProviderFunctionNames() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI 실행 중",
                message: "포트 18317에서 모델 목록을 불러올 수 있습니다."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    functionName: "ccm",
                    connectionTitle: "연결됨",
                    connectionDetail: "woosub@classting.com",
                    isConnected: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    functionName: "ccmcodex",
                    connectionTitle: "연결됨",
                    connectionDetail: "codex@example.com",
                    isConnected: true
                )
            ]
        )

        XCTAssertEqual(snapshot.serverTitle, "CLIProxyAPI 실행 중")
        XCTAssertEqual(snapshot.serverDetail, "포트 18317에서 모델 목록을 불러올 수 있습니다.")
        XCTAssertTrue(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Stop Server")
        XCTAssertEqual(snapshot.endpointTitle, "localhost:18317")
        XCTAssertEqual(snapshot.connectedProviders.map(\.name), ["Claude OAuth", "Codex OAuth"])
        XCTAssertEqual(snapshot.connectedProviders.map(\.functionName), ["ccm", "ccmcodex"])
        XCTAssertEqual(snapshot.connectedProviders.map(\.connectionDetail), ["woosub@classting.com", "codex@example.com"])
    }

    func testSnapshotShowsEmptyMessageWhenNoProviderIsConnected() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .warning,
                title: "확인 필요",
                message: "서버 상태 확인 전입니다."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude",
                    functionName: "ccm",
                    connectionTitle: "확인 필요",
                    connectionDetail: "Claude Code OAuth 상태를 확인하세요.",
                    isConnected: false
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders, [])
        XCTAssertFalse(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Start Server")
        XCTAssertEqual(snapshot.endpointTitle, nil)
        XCTAssertEqual(snapshot.emptyProviderMessage, "연결된 계정 없음")
    }
}

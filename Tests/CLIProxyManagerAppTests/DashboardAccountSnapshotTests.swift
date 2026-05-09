import XCTest
@testable import CLIProxyManagerApp

final class DashboardAccountSnapshotTests: XCTestCase {
    func testConnectedProviderRowMapsToAccountCard() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "연결됨",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.title, "Claude OAuth")
        XCTAssertEqual(snapshot.commandName, "ccm")
        XCTAssertEqual(snapshot.commandSlug, "$ ccm")
        XCTAssertEqual(snapshot.detail, "claude@example.com")
        XCTAssertEqual(snapshot.status, DashboardAccountSnapshot.Status.connected)
        XCTAssertEqual(snapshot.primaryActionTitle, "Settings")
        XCTAssertTrue(snapshot.showsMoreMenu)
    }

    func testDisconnectedProviderRowMapsToConnectAction() {
        let row = ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            nickname: "",
            functionName: "ccmcodex",
            connectionTitle: "연결 필요",
            connectionDetail: "번들 CLIProxyAPI의 Codex OAuth profile을 연결하세요.",
            isConnected: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertEqual(snapshot.title, "Codex OAuth")
        XCTAssertEqual(snapshot.commandName, "ccmcodex")
        XCTAssertEqual(snapshot.commandSlug, "$ ccmcodex")
        XCTAssertEqual(snapshot.status, DashboardAccountSnapshot.Status.disconnected)
        XCTAssertEqual(snapshot.primaryActionTitle, "Connect")
        XCTAssertFalse(snapshot.showsMoreMenu)
    }
}

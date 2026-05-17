import XCTest
@testable import CLIProxyManagerApp

final class DashboardAccountSnapshotTests: XCTestCase {
    func testConnectedProviderRowMapsToAccountCard() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
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
            connectionTitle: "Needs connection",
            connectionDetail: "Connect the bundled CLIProxyAPI Codex OAuth profile.",
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

    func testConnectedProviderShowsPrivacyToggleAndHiddenState() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertTrue(snapshot.isAccountDetailHidden)
        XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
    }

    func testConnectedProviderPreservesVisiblePrivacyState() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true,
            accountDetailHidden: false
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertFalse(snapshot.isAccountDetailHidden)
        XCTAssertTrue(snapshot.showsAccountPrivacyToggle)
    }

    func testDisconnectedProviderDoesNotShowPrivacyToggle() {
        let row = ProviderRowState(
            id: .codex,
            name: "Codex OAuth",
            nickname: "",
            functionName: "ccmcodex",
            connectionTitle: "Needs connection",
            connectionDetail: "Connect the bundled CLIProxyAPI Codex OAuth profile.",
            isConnected: false,
            accountDetailHidden: true
        )

        let snapshot = DashboardAccountSnapshot(provider: row)

        XCTAssertTrue(snapshot.isAccountDetailHidden)
        XCTAssertFalse(snapshot.showsAccountPrivacyToggle)
    }

    func testWhitespaceOnlyNicknameFallsBackToProviderName() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "  \n  ",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        XCTAssertEqual(row.displayTitle, "Claude OAuth")
    }

    func testDisplayTitleUsesTrimmedNickname() {
        let row = ProviderRowState(
            id: .claude,
            name: "Claude OAuth",
            nickname: "  Work  \n",
            functionName: "ccm",
            connectionTitle: "Connected",
            connectionDetail: "claude@example.com",
            isConnected: true
        )

        XCTAssertEqual(row.displayTitle, "Work")
    }
}

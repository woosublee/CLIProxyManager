import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class UsageOverlayAccountPresentationTests: XCTestCase {
    func testPresentationFiltersHiddenAccountsAndPreservesSelectedOrder() {
        let presentation = makePresentation(rows: [
            row(id: "first", showsInUsageOverlay: true),
            row(id: "hidden", showsInUsageOverlay: false),
            row(id: "last", showsInUsageOverlay: true)
        ])

        XCTAssertEqual(presentation.providers.map(\.id.rawValue), ["first", "last"])
        XCTAssertNil(presentation.emptyMessage)
    }

    func testPresentationKeepsSelectedAPIKeyAccount() {
        let presentation = makePresentation(rows: [
            ProviderRowState(
                id: .claudeAPI,
                providerType: .claude,
                name: "Claude API Key",
                nickname: "API",
                functionName: "ccapi",
                connectionTitle: "Configured",
                connectionDetail: "CLIProxyAPI",
                isConnected: true,
                subscriptionUsageState: .disabled,
                showsSubscriptionUsage: false,
                showsInUsageOverlay: true
            )
        ])

        XCTAssertEqual(presentation.providers.map(\.id), [.claudeAPI])
    }

    func testPresentationShowsNoAccountsSelectedWhenAllRegisteredAccountsAreHidden() {
        let presentation = makePresentation(rows: [
            row(id: "hidden", showsInUsageOverlay: false)
        ])

        XCTAssertEqual(presentation.providers, [])
        XCTAssertEqual(presentation.emptyMessage, "No accounts selected")
    }

    func testPresentationShowsNoConnectedAccountsWhenSelectedAccountsAreUnavailable() {
        let presentation = makePresentation(rows: [
            row(id: "disabled", isConnected: false, isDisabled: true, showsInUsageOverlay: true),
            row(id: "disconnected", isConnected: false, showsInUsageOverlay: true)
        ])

        XCTAssertEqual(presentation.providers, [])
        XCTAssertEqual(presentation.emptyMessage, "No connected accounts")
    }

    func testPresentationKeepsExistingEmptyCopyWhenNoAccountsAreRegistered() {
        let presentation = makePresentation(rows: [])

        XCTAssertEqual(presentation.providers, [])
        XCTAssertEqual(presentation.emptyMessage, "No connected accounts")
    }

    private func makePresentation(rows: [ProviderRowState]) -> UsageOverlayAccountPresentation {
        UsageOverlayAccountPresentation(
            serverStatus: DiagnosticStatus(severity: .ready, title: "Running", message: "Ready"),
            serverControlState: .running,
            providerRows: rows,
            port: 18_317
        )
    }

    private func row(
        id: ProviderRowState.ID,
        isConnected: Bool = true,
        isDisabled: Bool = false,
        showsInUsageOverlay: Bool
    ) -> ProviderRowState {
        ProviderRowState(
            id: id,
            name: "Claude OAuth",
            nickname: id.rawValue,
            functionName: "cmd-\(id.rawValue)",
            connectionTitle: isDisabled ? "Disabled" : isConnected ? "Connected" : "Disconnected",
            connectionDetail: "account@example.com",
            isConnected: isConnected,
            isDisabled: isDisabled,
            showsInUsageOverlay: showsInUsageOverlay
        )
    }
}

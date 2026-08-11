import XCTest

final class AccountReauthenticationUITests: XCTestCase {
    func testOAuthAccountMenusPutReloginBeforeStateChangeAndDestructiveRemoval() throws {
        let source = try dashboardSource()
        let connectedMenu = try sourceSection(
            in: source,
            after: "if account.status == .connected {",
            before: "} else if account.status == .disabled {"
        )
        let disabledMenu = try sourceSection(
            in: source,
            after: "} else if account.status == .disabled {",
            before: "} else {"
        )

        XCTAssertTrue(connectedMenu.contains("Label(\"Re-login\", systemImage: \"arrow.clockwise\")"))
        XCTAssertTrue(disabledMenu.contains("Label(\"Re-login\", systemImage: \"arrow.clockwise\")"))
        XCTAssertLessThan(try offset(of: "Label(\"Re-login\"", in: connectedMenu), try offset(of: "Label(\"Disable account\"", in: connectedMenu))
        XCTAssertLessThan(try offset(of: "Label(\"Disable account\"", in: connectedMenu), try offset(of: "Button(role: .destructive)", in: connectedMenu))
        XCTAssertLessThan(try offset(of: "Label(\"Re-login\"", in: disabledMenu), try offset(of: "Label(\"Enable account\"", in: disabledMenu))
        XCTAssertLessThan(try offset(of: "Label(\"Enable account\"", in: disabledMenu), try offset(of: "Button(role: .destructive)", in: disabledMenu))
    }

    func testDashboardDoesNotOfferReloginForAPIKeyOrDisconnectedAccounts() throws {
        let source = try dashboardSource()
        XCTAssertTrue(source.contains("if !account.isAPIKeyProfile"))
        let disconnectedMenu = try sourceSection(in: source, after: "} else {", before: "\n        }\n    }\n\n}")
        XCTAssertFalse(disconnectedMenu.contains("Re-login"))
    }

    func testDashboardUsesDedicatedReauthenticationSheetAndClosesItAfterLoginStops() throws {
        let source = try dashboardSource()
        let modalSource = try addProviderModalSource()

        XCTAssertTrue(source.contains("case reauthenticate(ProviderRowState.ID, accountTitle: String)"))
        XCTAssertTrue(source.contains("viewModel.startOAuthReauthentication(account.id)"))
        XCTAssertTrue(source.contains("OAuthLoginProgressSheet"))
        XCTAssertTrue(source.contains("case .reauthenticate"))
        XCTAssertTrue(modalSource.contains("struct OAuthLoginProgressSheet: View"))
        XCTAssertTrue(modalSource.contains("Re-login"))
    }

    func testDashboardDisablesReloginWhileOAuthLoginIsActive() throws {
        XCTAssertTrue(try dashboardSource().contains(".disabled(isOAuthLoginInProgress)"))
    }

    private func sourceSection(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker, options: .backwards)?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func offset(of marker: String, in source: String) throws -> Int {
        let range = try XCTUnwrap(source.range(of: marker))
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }

    private func dashboardSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DashboardView.swift")
    }

    private func addProviderModalSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/AddProviderModal.swift")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

import Foundation
import XCTest

final class DashboardAccountCardLayoutUITests: XCTestCase {
    func testDashboardCentersProviderAvatarWithinAccountCardContent() throws {
        let cardBody = try providerAccountCardBody()
        let avatar = try sourceSection(
            in: cardBody,
            after: "ProviderAvatar(providerID: account.id, providerType: account.providerType)",
            before: "\n\n            VStack"
        )

        XCTAssertTrue(
            avatar.contains(".frame(maxHeight: .infinity, alignment: .center)")
        )
    }

    private func providerAccountCardBody() throws -> String {
        let providerCard = try sourceSection(
            in: dashboardSource(),
            after: "struct ProviderAccountCardView: View {",
            before: "private struct ProviderAccountDragPreview: View"
        )
        return try sourceSection(
            in: providerCard,
            after: "var body: some View {",
            before: "private var trailingControls: some View"
        )
    }

    private func dashboardSource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

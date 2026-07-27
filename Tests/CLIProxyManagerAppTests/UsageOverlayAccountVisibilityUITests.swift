import Foundation
import XCTest

final class UsageOverlayAccountVisibilityUITests: XCTestCase {
    func testDashboardConnectsUsageHUDButtonToPersistentSaveAction() throws {
        let source = try dashboardSource()

        XCTAssertTrue(source.contains("private var usageOverlayButton"))
        XCTAssertTrue(source.contains("account.usageOverlayButtonPresentation"))
        XCTAssertTrue(source.contains("setAccountVisibleInUsageOverlay"))
        XCTAssertTrue(source.contains("isVisible: !account.showsInUsageOverlay"))
    }

    func testDashboardShowsUsageHUDButtonInEveryAccountActionBranch() throws {
        let actions = try sourceSection(
            in: dashboardSource(),
            after: "private var actions: some View {",
            before: "\n    }\n\n}"
        )
        let connectedActions = try sourceSection(
            in: actions,
            after: "if account.status == .connected {",
            before: "} else if account.status == .disabled {"
        )
        let disabledActions = try sourceSection(
            in: actions,
            after: "} else if account.status == .disabled {",
            before: "} else {"
        )
        let disconnectedActions = try sourceSuffix(in: actions, after: "} else {")

        XCTAssertEqual(usageOverlayButtonCount(in: connectedActions), 1)
        XCTAssertEqual(usageOverlayButtonCount(in: disabledActions), 1)
        XCTAssertEqual(usageOverlayButtonCount(in: disconnectedActions), 1)
    }

    func testUsageHUDButtonUsesQuietWindowPresentationAndKeepsInteractionContract() throws {
        let button = try sourceSection(
            in: dashboardSource(),
            after: "private var usageOverlayButton: some View {",
            before: "\n    }\n\n    @ViewBuilder"
        )

        XCTAssertTrue(button.contains(".frame(width: 26, height: 26)"))
        XCTAssertTrue(button.contains("BrandPalette.accent"))
        XCTAssertTrue(button.contains("Color.primary.opacity(hovering ? 0.65 : 0.38)"))
        XCTAssertFalse(button.contains(".fastTooltip(presentation.accessibilityLabel)"))
        XCTAssertTrue(button.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
        XCTAssertFalse(button.contains(".background"))
        XCTAssertFalse(button.contains("RoundedRectangle"))
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

    private func sourceSuffix(in source: String, after marker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker)?.upperBound)
        return String(source[start...])
    }

    private func usageOverlayButtonCount(in source: String) -> Int {
        source.components(separatedBy: "usageOverlayButton").count - 1
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

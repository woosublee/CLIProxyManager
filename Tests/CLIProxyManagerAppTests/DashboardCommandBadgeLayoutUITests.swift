import Foundation
import XCTest

final class DashboardCommandBadgeLayoutUITests: XCTestCase {
    func testSlugPillKeepsCommandTextOnOneLine() throws {
        let slugPill = try sourceSection(
            in: designChromeSource(),
            after: "struct SlugPill: View {",
            before: "\n}\n\n// MARK: - Provider avatar"
        )
        let commandText = try sourceSection(
            in: slugPill,
            after: "Text(slug)",
            before: "Image(systemName:"
        )

        XCTAssertTrue(commandText.contains(".lineLimit(1)"))
        XCTAssertTrue(commandText.contains(".truncationMode(.tail)"))
    }

    private func dashboardSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DashboardView.swift")
    }

    private func designChromeSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
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

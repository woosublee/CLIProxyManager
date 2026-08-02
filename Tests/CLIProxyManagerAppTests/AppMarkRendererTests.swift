import XCTest
@testable import CLIProxyManagerApp

#if canImport(AppKit)
@MainActor
final class AppMarkRendererTests: XCTestCase {
    func testDockIconsRenderAtCanvasSizeAndDifferByBuildFlavor() throws {
        let official = try XCTUnwrap(AppMarkRenderer.dockIcon(buildFlavor: .official))
        let development = try XCTUnwrap(AppMarkRenderer.dockIcon(buildFlavor: .development))

        XCTAssertEqual(official.size.width, 1024, accuracy: 0.01)
        XCTAssertEqual(official.size.height, 1024, accuracy: 0.01)
        XCTAssertEqual(development.size.width, 1024, accuracy: 0.01)
        XCTAssertEqual(development.size.height, 1024, accuracy: 0.01)
        XCTAssertNotEqual(official.tiffRepresentation, development.tiffRepresentation)
    }

    func testDefaultAppIconViewRemainsOfficial() {
        XCTAssertEqual(AppIconView().buildFlavor, .official)
    }

    func testDevelopmentDockKeepsOfficialGradientWithoutLetterBadge() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private let officialGradientColors"))
        XCTAssertTrue(source.contains("Color.orange.opacity"))
        XCTAssertTrue(source.contains("buildFlavor == .development ? Color.black.opacity"))
        XCTAssertFalse(source.contains("Text(\"D\")"))
        XCTAssertFalse(source.contains("45.0 / 255.0"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif

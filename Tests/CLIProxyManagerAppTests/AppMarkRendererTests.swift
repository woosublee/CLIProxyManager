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
}
#endif

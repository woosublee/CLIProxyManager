import XCTest
@testable import CLIProxyManagerApp

#if canImport(AppKit)
@MainActor
final class AppMarkRendererTests: XCTestCase {
    func testMenuBarTemplateRendersSquareTemplateImage() {
        let image = AppMarkRenderer.menuBarTemplate(size: 18)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size.width ?? 0, 18, accuracy: 0.01)
        XCTAssertEqual(image?.size.height ?? 0, 18, accuracy: 0.01)
    }

    func testMenuBarTemplateHandlesVerySmallSizes() {
        let image = AppMarkRenderer.menuBarTemplate(size: 1)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size.width ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(image?.size.height ?? 0, 1, accuracy: 0.01)
    }
}
#endif

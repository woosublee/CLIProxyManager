import XCTest
@testable import CLIProxyManagerApp

final class SettingsToastPresentationTests: XCTestCase {
    func testToastUsesBottomCenterPlacement() {
        XCTAssertEqual(SettingsToastPresentation.default.alignment, .bottom)
        XCTAssertEqual(SettingsToastPresentation.default.horizontalPlacement, .center)
    }

    func testToastWidthUsesCompactBounds() {
        XCTAssertEqual(SettingsToastPresentation.default.width(for: "Saved."), 92)
        XCTAssertEqual(SettingsToastPresentation.default.width(for: "Cannot install shell functions: `cc` is already defined as an alias or function in ~/.zshrc."), 228)
    }

    func testToastCloseButtonUsesTopTrailingOverlayPlacement() {
        XCTAssertEqual(SettingsToastPresentation.default.closeButtonPlacement, .topTrailingOverlay)
        XCTAssertEqual(SettingsToastPresentation.default.closeButtonHitSize, 18)
        XCTAssertEqual(SettingsToastPresentation.default.closeButtonTopPadding, 5)
        XCTAssertEqual(SettingsToastPresentation.default.closeButtonTrailingPadding, 5)
        XCTAssertEqual(SettingsToastPresentation.default.messageTrailingPadding, 24)
    }
}

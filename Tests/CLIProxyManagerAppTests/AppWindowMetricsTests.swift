import XCTest
@testable import CLIProxyManagerApp

final class AppWindowMetricsTests: XCTestCase {
    func testWindowMetricsMatchUI3ReferenceSizes() {
        XCTAssertEqual(AppWindowMetrics.mainWidth, 380)
        XCTAssertEqual(AppWindowMetrics.mainMaxHeight, 720)
        XCTAssertEqual(AppWindowMetrics.settingsWidth, 720)
        XCTAssertEqual(AppWindowMetrics.settingsHeight, 500)
        XCTAssertEqual(AppWindowMetrics.menuBarWidth, 248)
        XCTAssertEqual(AppWindowMetrics.usageOverlayExpandedWidth, 300)
        XCTAssertEqual(AppWindowMetrics.usageOverlayCompactWidth, 108)
        XCTAssertEqual(AppWindowMetrics.usageOverlayExpandedMinimumHeight, 260)
        XCTAssertEqual(AppWindowMetrics.usageOverlayMaximumHeight, 720)
        XCTAssertEqual(AppWindowMetrics.usageOverlayScreenMargin, 16)
        XCTAssertEqual(AppWindowMetrics.usageOverlayWidth, 300)
        XCTAssertEqual(AppWindowMetrics.usageOverlayHeight, 260)
    }
}

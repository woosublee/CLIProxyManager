import XCTest
@testable import CLIProxyManagerApp

final class AppWindowMetricsTests: XCTestCase {
    func testWindowMetricsMatchUI3ReferenceSizes() {
        XCTAssertEqual(AppWindowMetrics.mainWidth, 380)
        XCTAssertEqual(AppWindowMetrics.mainMaxHeight, 720)
        XCTAssertEqual(AppWindowMetrics.settingsWidth, 720)
        XCTAssertEqual(AppWindowMetrics.settingsHeight, 500)
        XCTAssertEqual(AppWindowMetrics.menuBarWidth, 248)
    }
}

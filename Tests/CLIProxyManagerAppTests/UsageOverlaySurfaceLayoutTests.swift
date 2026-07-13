import CoreGraphics
import XCTest
@testable import CLIProxyManagerApp

final class UsageOverlaySurfaceLayoutTests: XCTestCase {
    func testChromeKeepsFixedTopTrailingInsetAcrossPanelSizes() {
        let expanded = UsageOverlaySurfaceLayout.chromeFrame(
            in: CGRect(x: 0, y: 0, width: 300, height: 330)
        )
        let compact = UsageOverlaySurfaceLayout.chromeFrame(
            in: CGRect(x: 0, y: 0, width: 108, height: 168)
        )

        XCTAssertEqual(expanded.maxX, 290)
        XCTAssertEqual(expanded.maxY, 320)
        XCTAssertEqual(compact.maxX, 98)
        XCTAssertEqual(compact.maxY, 158)
    }

    func testSurfaceAlwaysMatchesAnimatedPanelBounds() {
        let surface = UsageOverlaySurfaceLayout.surfaceFrame(
            in: CGRect(x: 0, y: 0, width: 204, height: 166)
        )

        XCTAssertEqual(surface, CGRect(x: 0, y: 0, width: 204, height: 166))
    }

    func testSurfaceCornerRadiusInterpolatesSymmetricallyBetweenModes() {
        XCTAssertEqual(
            UsageOverlaySurfaceLayout.cornerRadius(progress: 0),
            UsageOverlaySurfaceLayout.expandedCornerRadius
        )
        XCTAssertEqual(
            UsageOverlaySurfaceLayout.cornerRadius(progress: 0.5),
            16
        )
        XCTAssertEqual(
            UsageOverlaySurfaceLayout.cornerRadius(progress: 1),
            UsageOverlaySurfaceLayout.compactCornerRadius
        )
    }
}

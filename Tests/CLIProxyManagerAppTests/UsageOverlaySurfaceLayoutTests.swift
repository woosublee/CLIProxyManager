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

        XCTAssertEqual(expanded.maxX, 284)
        XCTAssertEqual(expanded.maxY, 314)
        XCTAssertEqual(compact.maxX, 92)
        XCTAssertEqual(compact.maxY, 152)
    }

    func testChromeFitsRefreshModeAndCloseControlsInCompactMode() {
        let compact = UsageOverlaySurfaceLayout.chromeFrame(
            in: CGRect(x: 0, y: 0, width: 108, height: 168)
        )

        XCTAssertEqual(compact.width, 76)
        XCTAssertGreaterThanOrEqual(compact.minX, UsageOverlaySurfaceLayout.chromeInset)
    }

    func testChromeKeepsScreenPositionDuringTopTrailingAnchoredResize() {
        let expandedPanel = CGRect(x: 500, y: 400, width: 300, height: 330)
        let compactPanel = CGRect(x: 692, y: 562, width: 108, height: 168)
        let expanded = UsageOverlaySurfaceLayout.chromeFrame(
            in: CGRect(origin: .zero, size: expandedPanel.size)
        ).offsetBy(dx: expandedPanel.minX, dy: expandedPanel.minY)
        let compact = UsageOverlaySurfaceLayout.chromeFrame(
            in: CGRect(origin: .zero, size: compactPanel.size)
        ).offsetBy(dx: compactPanel.minX, dy: compactPanel.minY)

        XCTAssertEqual(expanded, compact)
    }

    func testExpandedHeaderLeavesConsistentGapBeforeChromeControls() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 330)
        let chrome = UsageOverlaySurfaceLayout.chromeFrame(in: bounds)
        let contentRight = bounds.maxX - UsageOverlaySurfaceLayout.expandedContentInset
        let headerRight = contentRight - UsageOverlaySurfaceLayout.expandedHeaderTrailingPadding

        XCTAssertEqual(chrome.minX - headerRight, UsageOverlaySurfaceLayout.expandedHeaderControlSpacing)
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

import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class UsageOverlayFrameLayoutTests: XCTestCase {
    func testCompactFrameKeepsRightTopAnchor() {
        let current = CGRect(x: 500, y: 400, width: 300, height: 260)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 360,
            mode: .compact,
            visibleFrame: screen
        )

        XCTAssertEqual(target.width, 108)
        XCTAssertEqual(target.height, 360)
        XCTAssertEqual(target.maxX, current.maxX)
        XCTAssertEqual(target.maxY, current.maxY)
    }

    func testExpandedFrameClampsToMinimumAndMaximumHeight() {
        let current = CGRect(x: 500, y: 100, width: 108, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let minimum = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 100,
            mode: .expanded,
            visibleFrame: screen
        )
        let maximum = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 1_200,
            mode: .expanded,
            visibleFrame: screen
        )

        XCTAssertEqual(minimum.height, 260)
        XCTAssertEqual(maximum.height, 720)
    }

    func testTargetFrameStaysInsideVisibleFrameMargin() {
        let current = CGRect(x: -40, y: 760, width: 300, height: 260)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 700,
            mode: .compact,
            visibleFrame: screen
        )

        XCTAssertGreaterThanOrEqual(target.minX, screen.minX + 16)
        XCTAssertGreaterThanOrEqual(target.minY, screen.minY + 16)
        XCTAssertLessThanOrEqual(target.maxX, screen.maxX - 16)
        XCTAssertLessThanOrEqual(target.maxY, screen.maxY - 16)
    }
}

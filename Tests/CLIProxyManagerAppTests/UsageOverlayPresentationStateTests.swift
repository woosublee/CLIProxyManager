import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class UsageOverlayPresentationStateTests: XCTestCase {
    func testModePresentationUsesAvailableMacOS15SymbolsAndLabels() {
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.toggleSymbolName, "arrow.down.right.and.arrow.up.left")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.toggleAccessibilityLabel, "Show compact usage window")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.opposite, .compact)

        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.toggleSymbolName, "arrow.up.left.and.arrow.down.right")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.toggleAccessibilityLabel, "Show expanded usage window")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.opposite, .expanded)
    }

    func testPresentationStatePublishesModeAndCompactViewportHeight() {
        let state = UsageOverlayPresentationState(displayMode: .expanded)

        state.displayMode = .compact
        state.compactAccountMaximumHeight = 420

        XCTAssertEqual(state.displayMode, .compact)
        XCTAssertEqual(state.compactAccountMaximumHeight, 420)
    }

    func testModeAnimationPolicyDisablesAnimationForReduceMotion() {
        XCTAssertNil(usageOverlayModeAnimation(reduceMotion: true))
        XCTAssertNotNil(usageOverlayModeAnimation(reduceMotion: false))
    }

    func testCompactMeasurementRequestsResizeOnlyForNewPositiveHeight() {
        var state = CompactUsageMeasurementState()

        XCTAssertFalse(state.record(height: 0))
        XCTAssertTrue(state.record(height: 180))
        XCTAssertFalse(state.record(height: 180))
        XCTAssertTrue(state.record(height: 220))
    }
}

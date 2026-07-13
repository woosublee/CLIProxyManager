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

    func testExpandedContentUsesHeaderOnlyForProvidersWithoutUsageCapability() {
        XCTAssertEqual(
            expandedUsageContentPresentation(
                showsSubscriptionUsage: false,
                subscriptionUsageState: .disabled
            ),
            .headerOnly
        )
    }

    func testExpandedContentShowsDisabledMessageForCapableOAuthProvider() {
        XCTAssertEqual(
            expandedUsageContentPresentation(
                showsSubscriptionUsage: true,
                subscriptionUsageState: .disabled
            ),
            .message("Subscription usage is disabled")
        )
    }

    func testCompactMeasurementRequestsResizeOnlyForNewPositiveHeight() {
        var state = CompactUsageMeasurementState()

        XCTAssertFalse(state.record(height: 0))
        XCTAssertTrue(state.record(height: 180))
        XCTAssertFalse(state.record(height: 180))
        XCTAssertTrue(state.record(height: 220))
    }

    func testCompactViewportUsesStableEstimateUntilMeasurementIsReady() {
        let state = CompactUsageMeasurementState()

        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
    }

    func testCompactViewportUsesMeasuredHeightAfterMeasurement() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.record(height: 220))

        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 220)
        XCTAssertEqual(state.viewportHeight(maximumHeight: 180), 180)
    }

    func testProviderIdentityChangeResetsPreviousMeasurement() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one", "two"]))
        XCTAssertTrue(state.record(height: 600))

        XCTAssertTrue(state.updateProviderIDs(["one"]))
        XCTAssertEqual(state.height, 0)
        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
    }

    func testEmptyToProviderTransitionStartsUnmeasured() {
        var state = CompactUsageMeasurementState()
        XCTAssertFalse(state.updateProviderIDs([]))
        XCTAssertTrue(state.record(height: 72))

        XCTAssertTrue(state.updateProviderIDs(["one"]))
        XCTAssertEqual(state.height, 0)
    }

    func testSameProviderIdentityDoesNotResetMeasurement() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one"]))
        XCTAssertTrue(state.record(height: 220))

        XCTAssertFalse(state.updateProviderIDs(["one"]))
        XCTAssertEqual(state.height, 220)
    }
}

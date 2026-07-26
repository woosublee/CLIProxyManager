import AppKit
import SwiftUI
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class UsageOverlayPresentationStateTests: XCTestCase {
    func testChromeRemainsVisibleWhileModeContentIsHidden() {
        let state = UsageOverlayPresentationState(displayMode: .expanded)

        state.displayMode = .compact
        state.isContentHiddenForModeTransition = true

        XCTAssertEqual(state.chromeOpacity, 1)
        XCTAssertEqual(state.chromeDisplayMode, .compact)
        XCTAssertEqual(state.contentOpacity, 0)
    }

    func testAnimatedModeTransitionHidesContentInBothDirections() {
        let state = UsageOverlayPresentationState(displayMode: .expanded)

        XCTAssertEqual(state.contentBlurRadius, 0)
        XCTAssertEqual(state.contentOpacity, 1)

        state.isContentHiddenForModeTransition = true
        XCTAssertEqual(state.contentBlurRadius, 8)
        XCTAssertEqual(state.contentOpacity, 0)

        state.presentedDisplayMode = .compact
        state.isContentHiddenForModeTransition = false
        XCTAssertEqual(state.contentBlurRadius, 0)
        XCTAssertEqual(state.contentOpacity, 1)

        state.isContentHiddenForModeTransition = true
        XCTAssertEqual(state.contentBlurRadius, 8)
        XCTAssertEqual(state.contentOpacity, 0)
    }

    func testAccountTransitionConcealsContentWithoutConcealingChrome() {
        let presentation = accountPresentation([.claude])
        let state = UsageOverlayPresentationState(
            displayMode: .expanded,
            accountPresentation: presentation
        )

        state.accountTransitionPhase = .concealing

        XCTAssertEqual(state.contentBlurRadius, 8)
        XCTAssertEqual(state.contentOpacity, 0)
        XCTAssertEqual(state.chromeOpacity, 1)
        XCTAssertTrue(state.isContentHiddenForAccountTransition)
    }

    func testModeAndAccountConcealmentComposeUntilBothRelease() {
        let state = UsageOverlayPresentationState(
            displayMode: .expanded,
            accountPresentation: accountPresentation([.claude])
        )
        state.isContentHiddenForModeTransition = true
        state.accountTransitionPhase = .resizing

        state.isContentHiddenForModeTransition = false
        XCTAssertEqual(state.contentOpacity, 0)
        XCTAssertTrue(state.isContentConcealed)

        state.accountTransitionPhase = .revealing
        XCTAssertEqual(state.contentOpacity, 1)
        XCTAssertFalse(state.isContentConcealed)
    }

    func testPresentationStatePublishesBufferedAccountSnapshot() {
        let original = accountPresentation([.claude])
        let updated = accountPresentation([.claude, .codex])
        let state = UsageOverlayPresentationState(
            displayMode: .expanded,
            accountPresentation: original
        )

        state.presentedAccountPresentation = updated

        XCTAssertEqual(state.presentedAccountPresentation, updated)
    }

    func testAccountTransitionConcealmentCoversOnlyHiddenPhases() {
        let state = UsageOverlayPresentationState(
            displayMode: .expanded,
            accountPresentation: accountPresentation([])
        )

        for phase in [
            UsageOverlayAccountTransitionPhase.concealing,
            .swapping,
            .resizing,
        ] {
            state.accountTransitionPhase = phase
            XCTAssertTrue(state.isContentHiddenForAccountTransition)
        }

        for phase in [
            UsageOverlayAccountTransitionPhase.revealing,
            .visible,
        ] {
            state.accountTransitionPhase = phase
            XCTAssertFalse(state.isContentHiddenForAccountTransition)
        }
    }

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

    func testExpandedContentUsesAPIUsageForConfiguredAPIKeyProvider() {
        let presentation = expandedUsageContentPresentation(
            showsUsage: true,
            usageState: .apiCost(.available(makeCostSnapshot()))
        )

        XCTAssertEqual(presentation, .usage)
    }

    func testExpandedAPIRenderContractUsesTextOnlyAdaptiveRows() {
        let row = apiCostRows(
            snapshot: makeCostSnapshot(dayTokens: 84_000, dayRequests: 14)
        ).first!

        XCTAssertEqual(row.detail, "84K TOK · 14 REQ")
        XCTAssertEqual(row.cost, "$0.42")
        XCTAssertEqual(row.decoration, .textOnly)
        XCTAssertEqual(row.textLayout, .adaptiveSingleLine(minimumScaleFactor: 0.6))
    }

    func testExpandedContentUsesHeaderOnlyForProvidersWithoutUsageCapability() {
        XCTAssertEqual(
            expandedUsageContentPresentation(
                showsUsage: false,
                usageState: .subscription(.disabled)
            ),
            .headerOnly
        )
    }

    func testExpandedContentShowsDisabledMessageForCapableOAuthProvider() {
        XCTAssertEqual(
            expandedUsageContentPresentation(
                showsUsage: true,
                usageState: .subscription(.disabled)
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

    func testMeasurementRecordsProviderIdentitiesBeforeIdentityChangeCallback() {
        var state = CompactUsageMeasurementState()

        XCTAssertTrue(state.record(height: 220, providerIDs: ["one", "two"]))
        XCTAssertFalse(state.updateProviderIDs(["one", "two"]))
        XCTAssertEqual(state.height, 220)
    }

    func testCompactViewportUsesMinimumHeightUntilMeasurement() {
        let state = CompactUsageMeasurementState()

        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
        XCTAssertFalse(state.needsScrolling(maximumHeight: 500))
    }

    func testCompactViewportDoesNotReserveHeightForUnmeasuredProviders() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one", "two", "three", "four"]))

        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
        XCTAssertFalse(state.needsScrolling(maximumHeight: 500))
    }

    func testCompactViewportClampsMeasuredContentAndEnablesScrolling() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.record(height: 480, providerIDs: ["one", "two", "three", "four"]))

        XCTAssertEqual(state.viewportHeight(maximumHeight: 300), 300)
        XCTAssertTrue(state.needsScrolling(maximumHeight: 300))
    }

    func testCompactViewportUsesMeasuredHeightAfterMeasurement() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one", "two"]))
        XCTAssertTrue(state.record(height: 220))

        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 220)
        XCTAssertEqual(state.viewportHeight(maximumHeight: 180), 180)
        XCTAssertTrue(state.needsScrolling(maximumHeight: 180))
    }

    func testProviderAdditionResetsMeasurementToMinimumHeight() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one"]))
        XCTAssertTrue(state.record(height: 110))

        XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))
        XCTAssertEqual(state.height, 0)
        XCTAssertEqual(state.viewportHeight(maximumHeight: 500), 120)
    }

    func testProviderRemovalResetsMeasurementToMinimumHeight() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))
        XCTAssertTrue(state.record(height: 330))

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

    func testProviderReorderingPreservesMeasurement() {
        var state = CompactUsageMeasurementState()
        XCTAssertTrue(state.updateProviderIDs(["one", "two", "three"]))
        XCTAssertTrue(state.record(height: 360))

        XCTAssertFalse(state.updateProviderIDs(["three", "one", "two"]))
        XCTAssertEqual(state.height, 360)
    }

    private func makeCostSnapshot(
        dayTokens: Int64 = 84_000,
        dayRequests: Int64 = 14
    ) -> APICostSnapshot {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let day = APICostPeriodSnapshot(
            period: .day,
            estimatedUSD: Decimal(string: "0.42")!,
            totalTokens: dayTokens,
            requestCount: dayRequests,
            failedRequestCount: 0,
            pricedRequestCount: dayRequests,
            unpricedRequestCount: 0,
            intervalStart: start,
            intervalEnd: end,
            issues: []
        )
        let month = APICostPeriodSnapshot(
            period: .month,
            estimatedUSD: Decimal(string: "8.73")!,
            totalTokens: 1_800_000,
            requestCount: 218,
            failedRequestCount: 0,
            pricedRequestCount: 218,
            unpricedRequestCount: 0,
            intervalStart: start,
            intervalEnd: end,
            issues: []
        )
        return APICostSnapshot(
            profileID: "claude-api",
            provider: .claude,
            day: day,
            month: month,
            reportingTimeZoneID: "UTC",
            updatedAt: end
        )
    }

    func testCompactProviderChangePublishesOnlyFinalMeasuredHeight() async {
        let model = CompactUsageMeasurementHarnessModel(
            providers: [compactProvider(id: .claude, index: 0)],
            emptyMessage: "No connected accounts"
        )
        let hostingView = NSHostingView(rootView: CompactUsageMeasurementHarness(model: model))
        hostingView.frame = CGRect(x: 0, y: 0, width: 108, height: 640)

        let measuredInitialState = await waitUntil {
            hostingView.layoutSubtreeIfNeeded()
            return !model.measurements.isEmpty
        }
        XCTAssertTrue(measuredInitialState)
        let measurementCountBeforeAddition = model.measurements.count

        model.providers.append(compactProvider(id: .codex, index: 1))

        let measuredTwoAccounts = await waitUntil {
            hostingView.layoutSubtreeIfNeeded()
            return model.measurements.dropFirst(measurementCountBeforeAddition).contains {
                $0 > CompactUsageMeasurementState.estimatedHeight
            }
        }
        XCTAssertTrue(measuredTwoAccounts)
        let firstMeasurementAfterAddition = model.measurements
            .dropFirst(measurementCountBeforeAddition)
            .first
        XCTAssertGreaterThan(
            firstMeasurementAfterAddition ?? 0,
            CompactUsageMeasurementState.estimatedHeight
        )
    }

    func testCompactViewRemeasuresRenderedEmptyStateAfterLastProviderIsRemoved() async {
        let model = CompactUsageMeasurementHarnessModel(
            providers: [
                MenuBarConnectedProvider(
                    id: .claude,
                    name: "Claude OAuth",
                    displayName: "Work",
                    functionName: "cc-work",
                    connectionDetail: "work@example.com",
                    accountDetailHidden: true,
                    usageState: .subscription(.disabled),
                    showsUsage: true
                )
            ],
            emptyMessage: Array(repeating: "No accounts selected", count: 16).joined(separator: "\n")
        )
        let hostingView = NSHostingView(rootView: CompactUsageMeasurementHarness(model: model))
        hostingView.frame = CGRect(x: 0, y: 0, width: 108, height: 640)

        let measuredNonEmptyState = await waitUntil {
            hostingView.layoutSubtreeIfNeeded()
            return model.measurements.contains {
                abs($0 - CompactUsageMeasurementState.estimatedHeight) > 0.5
            }
        }
        XCTAssertTrue(measuredNonEmptyState)
        let measurementCountBeforeRemoval = model.measurements.count

        model.providers = []

        let measuredRenderedEmptyState = await waitUntil {
            hostingView.layoutSubtreeIfNeeded()
            return model.measurements.dropFirst(measurementCountBeforeRemoval).contains {
                $0 > CompactUsageMeasurementState.estimatedHeight
            }
        }
        XCTAssertTrue(measuredRenderedEmptyState)
        XCTAssertGreaterThan(
            model.measurements.last ?? 0,
            CompactUsageMeasurementState.estimatedHeight
        )
    }

    private func compactProvider(
        id: ProviderRowState.ID,
        index: Int
    ) -> MenuBarConnectedProvider {
        MenuBarConnectedProvider(
            id: id,
            name: "Provider \(index)",
            displayName: "Account \(index)",
            functionName: "provider-\(index)",
            connectionDetail: "account-\(index)@example.com",
            accountDetailHidden: true,
            usageState: .subscription(.disabled),
            showsUsage: true
        )
    }

    private func accountPresentation(
        _ ids: [ProviderRowState.ID]
    ) -> UsageOverlayAccountPresentation {
        UsageOverlayAccountPresentation(
            providers: ids.enumerated().map { index, id in
                MenuBarConnectedProvider(
                    id: id,
                    name: "Provider \(index)",
                    displayName: "Account \(index)",
                    functionName: "provider-\(index)",
                    connectionDetail: "account-\(index)@example.com",
                    accountDetailHidden: true,
                    usageState: .subscription(.disabled),
                    showsUsage: true
                )
            },
            emptyMessage: ids.isEmpty ? "No connected accounts" : nil
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class CompactUsageMeasurementHarnessModel: ObservableObject {
    @Published var providers: [MenuBarConnectedProvider]
    let emptyMessage: String
    private(set) var measurements: [CGFloat] = []

    init(providers: [MenuBarConnectedProvider], emptyMessage: String) {
        self.providers = providers
        self.emptyMessage = emptyMessage
    }

    func record(_ height: CGFloat) {
        measurements.append(height)
    }
}

private struct CompactUsageMeasurementHarness: View {
    @ObservedObject var model: CompactUsageMeasurementHarnessModel

    var body: some View {
        CompactUsageOverlayView(
            providers: model.providers,
            emptyMessage: model.emptyMessage,
            maximumAccountHeight: 640,
            onMeasurementChange: model.record
        )
        .frame(width: 108)
        .fixedSize(horizontal: false, vertical: true)
    }
}

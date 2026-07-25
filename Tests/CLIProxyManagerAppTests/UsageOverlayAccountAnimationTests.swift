import Foundation
@testable import CLIProxyManagerApp
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testInitialProviderIDsAreRevealedImmediately() {
        let insertionState = ExpandedUsageOverlayInsertionState(
            providerIDs: [.claude, .codex]
        )

        XCTAssertTrue(insertionState.isRevealed(.claude))
        XCTAssertTrue(insertionState.isRevealed(.codex))
        XCTAssertFalse(insertionState.isRevealed(.claudeAPI))
    }

    func testPreparePrunesRemovedIDsAndReturnsOnlyUnrevealedInsertions() {
        var insertionState = ExpandedUsageOverlayInsertionState(
            providerIDs: [.claude, .codex]
        )

        let pendingProviderIDs = insertionState.prepare(
            providerIDs: [.codex, .claudeAPI]
        )

        XCTAssertEqual(pendingProviderIDs, [.claudeAPI])
        XCTAssertFalse(insertionState.isRevealed(.claude))
        XCTAssertTrue(insertionState.isRevealed(.codex))
        XCTAssertFalse(insertionState.isRevealed(.claudeAPI))
    }

    func testRevealOnlyRevealsPendingIDsThatRemainPresent() {
        var insertionState = ExpandedUsageOverlayInsertionState(providerIDs: [.claude])
        let pendingProviderIDs = insertionState.prepare(
            providerIDs: [.claude, .codex, .claudeAPI]
        )

        insertionState.reveal(
            pendingProviderIDs,
            presentProviderIDs: [.claude, .claudeAPI]
        )

        XCTAssertTrue(insertionState.isRevealed(.claude))
        XCTAssertFalse(insertionState.isRevealed(.codex))
        XCTAssertTrue(insertionState.isRevealed(.claudeAPI))
    }

    func testRemoveThenReaddMakesProviderPendingAgain() {
        var insertionState = ExpandedUsageOverlayInsertionState(providerIDs: [.claude])

        XCTAssertEqual(insertionState.prepare(providerIDs: []), [])
        XCTAssertFalse(insertionState.isRevealed(.claude))
        XCTAssertEqual(insertionState.prepare(providerIDs: [.claude]), [.claude])
        XCTAssertFalse(insertionState.isRevealed(.claude))
    }

    func testExpandedUsesStagedRevealWithoutStackLevelAnimation() throws {
        let content = try expandedContent()
        let body = try bodySection(
            in: content,
            endingBeforeFirstOf: ["\n    private var accountSurface: some View {"]
        )
        let accountSurface = try sourceSection(
            in: content,
            after: "private var accountSurface: some View {",
            before: "\n    private var providerIDs: [ProviderRowState.ID]"
        )
        let reveal = try sourceSection(
            in: content,
            after: "private func scheduleReveal(for providerIDs: [ProviderRowState.ID]) {",
            before: "\n    }\n}"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(content.contains("@State private var insertionState: ExpandedUsageOverlayInsertionState"))
        XCTAssertTrue(content.contains("@State private var insertionGeneration = 0"))
        XCTAssertTrue(content.contains("_insertionState = State(initialValue: ExpandedUsageOverlayInsertionState(providerIDs: providers.map(\\.id)))"))
        XCTAssertTrue(body.contains("accountSurface"))
        XCTAssertTrue(body.contains(".onChange(of: providerIDs) { _, providerIDs in"))
        XCTAssertFalse(body.contains("if providers.isEmpty"))
        XCTAssertTrue(body.contains("insertionState.prepare(providerIDs: providerIDs)"))
        XCTAssertTrue(body.contains("scheduleReveal(for: pendingProviderIDs)"))

        XCTAssertTrue(accountSurface.contains("ZStack(alignment: .topLeading)"))
        XCTAssertTrue(accountSurface.contains("ForEach(providers)"))
        XCTAssertTrue(accountSurface.contains(".opacity(insertionState.isRevealed(provider.id) ? 1 : 0)"))
        XCTAssertTrue(accountSurface.contains(".transition(.identity)"))
        XCTAssertTrue(accountSurface.contains("if providers.isEmpty"))
        XCTAssertFalse(accountSurface.contains(".transition(accountTransition)"))
        XCTAssertFalse(accountSurface.contains(".animation("))
        XCTAssertFalse(content.contains("private var accountTransition: AnyTransition"))

        XCTAssertTrue(reveal.contains("DispatchQueue.main.async"))
        XCTAssertTrue(reveal.contains("guard generation == insertionGeneration else { return }"))
        XCTAssertTrue(reveal.contains("if accessibilityReduceMotion {"))
        XCTAssertTrue(reveal.contains("insertionState.reveal(providerIDs, presentProviderIDs: self.providerIDs)"))
        XCTAssertTrue(reveal.contains("withAnimation(.easeOut(duration: 0.12))"))
        XCTAssertEqual(content.components(separatedBy: "withAnimation(").count - 1, 1)
    }

    func testCompactKeepsVisibleAccountStackMountedWithIdentityMeasurementRows() throws {
        let content = try source(named: "CompactUsageOverlayView.swift")
        let body = try sourceSection(
            in: content,
            after: "var body: some View {",
            before: "\n    private var providerIDs"
        )
        let visibleStack = try sourceSection(
            in: content,
            after: "private var visibleAccountStack: some View {",
            before: "\n    }\n\n    @ViewBuilder"
        )
        let measurementStack = try sourceSection(
            in: content,
            after: "private var measurementAccountStack: some View {",
            before: "\n    }\n\n    private var visibleAccountStack"
        )
        let emptyMeasurementLayer = sourceSectionIfPresent(
            in: content,
            after: "private var emptyMeasurementLayer: some View {",
            before: "\n    @ViewBuilder\n    private var measurementLayer"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(body.contains("ZStack(alignment: .top)"))
        XCTAssertTrue(body.contains("measurementLayer"))
        XCTAssertTrue(body.contains("accountScrollView"))
        XCTAssertFalse(body.contains("if providers.isEmpty"))
        XCTAssertTrue(content.contains("private var emptyMeasurementLayer: some View"))
        XCTAssertTrue(emptyMeasurementLayer.contains(".transition(.identity)"))
        XCTAssertTrue(content.contains("private var measurementLayer: some View"))
        XCTAssertTrue(content.contains("private var accountScrollView: some View"))
        XCTAssertTrue(content.contains(".frame(height: providers.isEmpty ? 0 : viewportHeight)"))
        XCTAssertTrue(visibleStack.contains("accountRows(transition: accountTransition)"))
        XCTAssertTrue(measurementStack.contains("accountRows(transition: .identity)"))
        XCTAssertFalse(visibleStack.contains(".animation("))
        XCTAssertFalse(measurementStack.contains(".animation("))
        XCTAssertTrue(content.contains(".transition(transition)"))
        assertReduceMotionTransition(in: content)
        XCTAssertFalse(content.contains("value: providerIDs"))
    }

    private func assertReduceMotionTransition(
        in content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            content.contains(
                "private var accountTransition: AnyTransition {\n        if accessibilityReduceMotion {\n            return .identity\n        }\n        return .asymmetric(\n            insertion: .opacity.animation(.easeOut(duration: 0.12)),\n            removal: .identity\n        )\n    }"
            ),
            file: file,
            line: line
        )
    }

    private func expandedContent() throws -> String {
        try sourceSection(
            in: try source(named: "UsageOverlayView.swift"),
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )
    }

    private func source(named filename: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views")
                .appendingPathComponent(filename),
            encoding: .utf8
        )
    }

    private func bodySection(
        in source: String,
        endingBeforeFirstOf endMarkers: [String]
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: "var body: some View {")?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(
            endMarkers
                .compactMap { marker in suffix.range(of: marker)?.lowerBound }
                .min()
        )
        return String(suffix[..<end])
    }

    private func sourceSectionIfPresent(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) -> String {
        guard let start = source.range(of: startMarker)?.upperBound else { return "" }
        let suffix = source[start...]
        guard let end = suffix.range(of: endMarker)?.lowerBound else { return "" }
        return String(suffix[..<end])
    }

    private func sourceSection(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

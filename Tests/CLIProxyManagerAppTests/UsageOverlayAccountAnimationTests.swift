import Foundation
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testExpandedAccountUsesTransitionLocalInsertionFade() throws {
        let content = try sourceSection(
            in: try source(named: "UsageOverlayView.swift"),
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )
        let accountStack = try sourceSection(
            in: content,
            after: "VStack(alignment: .leading, spacing: 14) {",
            before: "\n                }"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(accountStack.contains(".transition(accountTransition)"))
        XCTAssertFalse(accountStack.contains(".animation("))
        XCTAssertTrue(content.contains("private var accountTransition: AnyTransition"))
        XCTAssertTrue(content.contains("insertion: .opacity.animation(.easeOut(duration: 0.12))"))
        XCTAssertTrue(content.contains("removal: .identity"))
        XCTAssertFalse(content.contains("value: providers.map(\\.id)"))
    }

    func testCompactVisibleRowsUseTransitionLocalFadeWhileMeasurementUsesIdentity() throws {
        let content = try sourceSection(
            in: try source(named: "CompactUsageOverlayView.swift"),
            after: "struct CompactUsageOverlayView: View {",
            before: "\nprivate struct CompactUsageAccountView"
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

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(visibleStack.contains("accountRows(transition: accountTransition)"))
        XCTAssertTrue(measurementStack.contains("accountRows(transition: .identity)"))
        XCTAssertFalse(visibleStack.contains(".animation("))
        XCTAssertFalse(measurementStack.contains(".animation("))
        XCTAssertTrue(content.contains(".transition(transition)"))
        XCTAssertTrue(content.contains("insertion: .opacity.animation(.easeOut(duration: 0.12))"))
        XCTAssertTrue(content.contains("removal: .identity"))
        XCTAssertFalse(content.contains("value: providerIDs"))
    }

    private func source(named filename: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views")
                .appendingPathComponent(filename),
            encoding: .utf8
        )
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

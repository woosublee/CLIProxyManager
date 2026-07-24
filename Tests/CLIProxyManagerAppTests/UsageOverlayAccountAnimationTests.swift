import Foundation
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testExpandedAccountStackUsesInsertionOnlyFadeAndReduceMotion() throws {
        let content = try sourceSection(
            in: try source(named: "UsageOverlayView.swift"),
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(content.contains(".transition(.asymmetric(insertion: .opacity, removal: .identity))"))
        XCTAssertTrue(content.contains("accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)"))
        XCTAssertTrue(content.contains("value: providers.map(\\.id)"))
    }

    func testCompactVisibleAccountStackUsesSameInsertionOnlyFade() throws {
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
        XCTAssertTrue(content.contains(".transition(.asymmetric(insertion: .opacity, removal: .identity))"))
        XCTAssertTrue(visibleStack.contains("accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)"))
        XCTAssertTrue(visibleStack.contains("value: providerIDs"))
        XCTAssertFalse(measurementStack.contains(".animation("))
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

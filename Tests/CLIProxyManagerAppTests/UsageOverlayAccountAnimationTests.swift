import Foundation
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testExpandedDoesNotOwnAccountInsertionAnimation() throws {
        let source = try appSource(relativePath: "Views/UsageOverlayView.swift")
        let content = try sourceSection(
            in: source,
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )

        XCTAssertFalse(source.contains("ExpandedUsageOverlayInsertionState"))
        XCTAssertFalse(source.contains("UsageOverlayExpandedInsertionRevealScheduler"))
        XCTAssertFalse(content.contains("accessibilityReduceMotion"))
        XCTAssertFalse(content.contains("withAnimation(.easeOut(duration: 0.12))"))
        XCTAssertFalse(content.contains(".transition(accountTransition)"))
        XCTAssertFalse(content.contains(".opacity(insertionState.isRevealed"))
        XCTAssertTrue(content.contains("if providers.isEmpty"))
        XCTAssertTrue(content.contains("ForEach(providers)"))
        XCTAssertFalse(source.contains("private var accountPresentation:"))
        XCTAssertTrue(source.contains("presentationState.presentedAccountPresentation"))
        XCTAssertTrue(
            source.contains(
                ".animation(.easeInOut(duration: 0.14), value: presentationState.isContentConcealed)"
            )
        )
    }

    func testCompactRestoresPreAnimationRenderingAndMeasurement() throws {
        let content = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")

        XCTAssertFalse(content.contains("accessibilityReduceMotion"))
        XCTAssertFalse(content.contains("accountTransition"))
        XCTAssertFalse(content.contains("accountRows(transition:"))
        XCTAssertFalse(content.contains(".transition("))
        XCTAssertFalse(content.contains("private var measurementLayer"))
        XCTAssertFalse(content.contains("private var accountScrollView"))
        XCTAssertTrue(content.contains("if providers.isEmpty"))
        XCTAssertTrue(content.contains("measurementAccountStack"))
        XCTAssertTrue(content.contains("ScrollView(.vertical, showsIndicators: needsScrolling)"))
        XCTAssertTrue(content.contains("private var accountRows: some View"))
    }

    func testWindowControllerDoesNotCoordinateExpandedInsertionReveal() throws {
        let source = try appSource(
            relativePath: "Services/UsageOverlayWindowController.swift"
        )
        let immediateResize = try sourceSection(
            in: source,
            after: "private func resizeToFittingContentImmediately(animated: Bool) {",
            before: "\n    private func resizeToFittingContent(animated: Bool)"
        )

        XCTAssertFalse(source.contains("scheduleExpandedInsertionReveal"))
        XCTAssertFalse(source.contains("isResizeScheduled"))
        XCTAssertTrue(
            immediateResize.contains(
                "_ = resizeCoordinator.requestResize(animated: animated)"
            )
        )
        XCTAssertTrue(immediateResize.contains("performScheduledResize()"))
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp")
                .appendingPathComponent(relativePath),
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

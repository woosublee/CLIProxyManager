import Foundation
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testExpandedKeepsAccountStackMountedAndUsesReduceMotionAwareRowTransition() throws {
        let content = try source(named: "UsageOverlayView.swift")
        let body = try bodySection(
            in: content,
            endingBeforeFirstOf: [
                "\n    private var accountSurface: some View {",
                "\n    private var accountTransition: AnyTransition {"
            ]
        )
        let accountSurface = sourceSectionIfPresent(
            in: content,
            after: "private var accountSurface: some View {",
            before: "\n    private var accountTransition: AnyTransition {"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(body.contains("accountSurface"))
        XCTAssertFalse(body.contains("if providers.isEmpty"))
        XCTAssertTrue(content.contains("private var accountSurface: some View"))
        XCTAssertTrue(accountSurface.contains("ZStack(alignment: .topLeading)"))
        XCTAssertTrue(accountSurface.contains("ForEach(providers)"))
        XCTAssertTrue(accountSurface.contains(".transition(accountTransition)"))
        XCTAssertTrue(accountSurface.contains("if providers.isEmpty"))
        XCTAssertTrue(accountSurface.contains(".transition(.identity)"))
        assertReduceMotionTransition(in: content)
        XCTAssertFalse(content.contains("value: providers.map(\\.id)"))
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

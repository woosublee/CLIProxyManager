import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipTests: XCTestCase {
    func testDefaultDelayAndTextNormalization() {
        XCTAssertEqual(FastTooltipConfiguration.defaultDelayMilliseconds, 400)
        XCTAssertNil(normalizedFastTooltipText(nil))
        XCTAssertNil(normalizedFastTooltipText("   \n"))
        XCTAssertEqual(normalizedFastTooltipText("  Reset available  "), "Reset available")
    }

    func testNilTooltipSkipsStatefulModifier() throws {
        let source = try appSource(relativePath: "Views/FastTooltip.swift")
        let extensionRange = try XCTUnwrap(source.range(of: "extension View"))
        let extensionSource = String(source[extensionRange.lowerBound...])

        XCTAssertTrue(extensionSource.contains("@ViewBuilder"))
        XCTAssertTrue(extensionSource.contains("if let text = normalizedFastTooltipText(text)"))
        XCTAssertTrue(extensionSource.contains("FastTooltipModifier(text: text"))
    }

    func testTooltipSourceUsesSharedAdaptivePopoverSurface() throws {
        let source = try appSource(relativePath: "Views/FastTooltip.swift")

        XCTAssertTrue(source.contains(".onHover"))
        XCTAssertTrue(source.contains(".popover("))
        XCTAssertTrue(source.contains(".regularMaterial"))
        XCTAssertFalse(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("accessibilityReduceTransparency"))
        XCTAssertTrue(source.contains("accessibilityContrast"))
        XCTAssertTrue(source.contains("Task.sleep"))
        XCTAssertFalse(source.contains(".transition("))
        XCTAssertFalse(source.contains(".scale("))
        XCTAssertFalse(source.contains("BrandPalette.statusError"))
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

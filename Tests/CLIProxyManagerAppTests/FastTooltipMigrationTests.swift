import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipMigrationTests: XCTestCase {
    func testAppSourcesUseFastTooltipOnlyForInformationalSurfaces() throws {
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp")
        let sourceFiles = try FileManager.default
            .subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try sourceFiles.map {
            try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
        }

        XCTAssertFalse(sources.contains { $0.contains(".help(") })
        XCTAssertGreaterThanOrEqual(sources.filter { $0.contains(".fastTooltip(") }.count, 5)
    }

    func testInformationalTooltipSurfacesUseSharedModifier() throws {
        let files = [
            "Views/MenuBarStatusView.swift",
            "Views/CodexResetCreditBadge.swift",
            "Views/SubscriptionUsageWarningIcon.swift",
            "Views/UsageOverlayView.swift",
            "Views/CompactUsageOverlayView.swift"
        ]

        for file in files {
            XCTAssertTrue(try appSource(relativePath: file).contains(".fastTooltip("), file)
        }
    }

    func testCompactUsageCardOwnsGroupedResetTooltip() throws {
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
        let rowsRange = try XCTUnwrap(compact.range(of: "ForEach(presentation.rows) { row in"))
        let openingBrace = try XCTUnwrap(compact[rowsRange].firstIndex(of: "{"))
        let closingBrace = try XCTUnwrap(
            matchingClosingBrace(in: compact, openingBrace: openingBrace)
        )
        let cardModifierStart = compact.index(after: closingBrace)
        let tooltipRange = try XCTUnwrap(
            compact.range(
                of: ".fastTooltip(tooltipsEnabled ? presentation.cardTooltip : nil)",
                range: cardModifierStart..<compact.endIndex
            )
        )
        let cardSegment = String(compact[cardModifierStart..<tooltipRange.upperBound])

        XCTAssertTrue(cardSegment.contains(".padding(.horizontal, 7)"))
        XCTAssertTrue(cardSegment.contains(".padding(.vertical, 7)"))
        XCTAssertTrue(cardSegment.contains(".background(.primary.opacity(0.055)"))
        XCTAssertTrue(cardSegment.contains(".contentShape(Rectangle())"))
    }

    func testCompactMeasurementDisablesTooltips() throws {
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
        let measurementRange = try XCTUnwrap(
            compact.range(of: "private var measurementAccountStack: some View")
        )
        let visibleRange = try XCTUnwrap(
            compact.range(
                of: "private var visibleAccountStack: some View",
                range: measurementRange.upperBound..<compact.endIndex
            )
        )
        let rowsBuilderRange = try XCTUnwrap(
            compact.range(
                of: "@ViewBuilder",
                range: visibleRange.upperBound..<compact.endIndex
            )
        )
        let measurementSection = String(
            compact[measurementRange.lowerBound..<visibleRange.lowerBound]
        )
        let visibleSection = String(
            compact[visibleRange.lowerBound..<rowsBuilderRange.lowerBound]
        )

        XCTAssertTrue(measurementSection.contains("accountRows(tooltipsEnabled: false)"))
        XCTAssertFalse(measurementSection.contains("accountRows(tooltipsEnabled: true)"))
        XCTAssertTrue(visibleSection.contains("accountRows(tooltipsEnabled: true)"))
        XCTAssertFalse(visibleSection.contains("accountRows(tooltipsEnabled: false)"))
        XCTAssertFalse(compact.contains("row.tooltip"))
        XCTAssertTrue(compact.contains(".fastTooltip(tooltipsEnabled ? presentation.cardTooltip : nil)"))
    }

    func testMenuBarSubscriptionResetUsesSharedPresentationHelper() throws {
        let menuBar = try appSource(relativePath: "Views/MenuBarStatusView.swift")

        XCTAssertTrue(menuBar.contains("subscriptionUsageResetTooltip(for: window)"))
        XCTAssertFalse(menuBar.contains("resetAt.formatted(date: .abbreviated, time: .shortened)"))
    }

    func testCompactOmitsAPICostRowTooltipWhileMenuBarKeepsIt() throws {
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
        let menuBar = try appSource(relativePath: "Views/MenuBarStatusView.swift")

        XCTAssertFalse(compact.contains("row.tooltip"))
        XCTAssertTrue(menuBar.contains(".fastTooltip(row.tooltip)"))
    }

    func testGeneralIconControlsUseAccessibilityLabelsWithoutFastTooltip() throws {
        let providerList = try appSource(relativePath: "Views/ProviderListView.swift")
        let dashboard = try appSource(relativePath: "Views/DashboardView.swift")
        let providerSettings = try appSource(relativePath: "Views/ProviderSettingsSheets.swift")
        let usageOverlay = try appSource(relativePath: "Views/UsageOverlayView.swift")

        XCTAssertTrue(providerList.contains(".accessibilityLabel(\"Add provider\")"))
        XCTAssertFalse(providerList.contains(".fastTooltip("))
        XCTAssertTrue(dashboard.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
        XCTAssertFalse(dashboard.contains(".fastTooltip(presentation.accessibilityLabel)"))
        XCTAssertTrue(providerSettings.contains(".accessibilityLabel(\"Refresh models for this Claude account\")"))
        XCTAssertTrue(providerSettings.contains(".accessibilityLabel(\"Refresh models for this Claude API key\")"))
        XCTAssertFalse(providerSettings.contains(".fastTooltip("))
        XCTAssertTrue(usageOverlay.contains(".accessibilityLabel(accessibilityLabel)"))
        XCTAssertFalse(usageOverlay.contains(".fastTooltip(accessibilityLabel)"))
    }

    private func matchingClosingBrace(
        in source: String,
        openingBrace: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = openingBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return index
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        return nil
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

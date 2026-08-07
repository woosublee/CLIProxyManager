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
        let lines = compact.components(separatedBy: .newlines)
        let cardTooltipIndex = try XCTUnwrap(
            lines.firstIndex { $0.contains(".fastTooltip(presentation.cardTooltip)") }
        )

        XCTAssertEqual(
            lines[cardTooltipIndex - 1].trimmingCharacters(in: .whitespaces),
            ".contentShape(Rectangle())"
        )
        XCTAssertTrue(
            lines[..<cardTooltipIndex].suffix(8).contains {
                $0.contains(".padding(.horizontal, 7)")
            }
        )
        XCTAssertTrue(
            lines[..<cardTooltipIndex].suffix(8).contains {
                $0.contains(".background(.primary.opacity(0.055)")
            }
        )
    }

    func testCompactAPICostRowsKeepIndividualTooltipModifier() throws {
        let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")

        XCTAssertTrue(compact.contains(".fastTooltip(row.tooltip)"))
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

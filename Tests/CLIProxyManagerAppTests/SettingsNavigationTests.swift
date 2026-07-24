import Foundation
import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class SettingsNavigationTests: XCTestCase {
    func testAboutVersionTextUsesBundleVersion() {
        let bundle = BundleMock(info: [
            "CFBundleShortVersionString": "0.1.2",
            "CFBundleVersion": "6"
        ])

        XCTAssertEqual(aboutVersionText(bundle: bundle), "Version 0.1.2 (6)")
    }

    func testSettingsTabsIncludeDedicatedUsageTab() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["General", "Usage", "Server", "Advanced", "About"]
        )
        XCTAssertEqual(
            SettingsTab.allCases.map(\.systemImage),
            ["slider.horizontal.3", "chart.bar.xaxis", "server.rack", "wrench.and.screwdriver", "info.circle"]
        )
    }

    func testUsageSettingsCopyExplainsAutomaticSharedBackend() {
        XCTAssertEqual(UsageSettingsCopy.menuBarLabel, "Show subscription usage")
        XCTAssertEqual(UsageSettingsCopy.hudLabel, "Show usage HUD")
        XCTAssertEqual(
            UsageSettingsCopy.footer,
            "Usage data is fetched whenever the menu bar display or Usage HUD is enabled. CLIProxyManager manages the local management key automatically."
        )
    }

    func testOAuthCompletionTransitionsAddProviderSheetToInitialProviderSettings() {
        XCTAssertEqual(
            DashboardSheet.afterOAuthLoginCompletion(.codex, isInitialSetup: true),
            .providerSettings(.codex, isInitialSetup: true)
        )
    }

    func testOAuthCompletionTransitionsReconnectedProviderToExistingSettings() {
        XCTAssertEqual(
            DashboardSheet.afterOAuthLoginCompletion(.codex, isInitialSetup: false),
            .providerSettings(.codex, isInitialSetup: false)
        )
    }

    func testProviderSettingsSheetIdentityIncludesInitialSetupState() {
        XCTAssertNotEqual(
            DashboardSheet.providerSettings(.codex, isInitialSetup: true).id,
            DashboardSheet.providerSettings(.codex, isInitialSetup: false).id
        )
    }

    func testCodexProviderSettingsUsesTallerSheetHeight() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.codexHeight, 720)
    }

    func testLegacyCodexModelsSheetUsesFastColumnWidth() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/CLIProxyManagerApp/Views/SettingsSheets.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".frame(width: ProviderSettingsSheetMetrics.codexWidth)"))
    }

    func testCodexRoleRoutingFieldsNormalizeInitialAuthoritativeOptionsAndCanonicalizePickers() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Sources/CLIProxyManagerApp/Views/CodexRoleRoutingFields.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".task(id: availableModels)"))
        XCTAssertTrue(source.contains("normalizeRoles(for: availableModels)"))
        XCTAssertTrue(source.contains("get: { CodexFastMode.canonicalModel(from: role.wrappedValue.model) }"))
        XCTAssertTrue(source.contains("CodexRoleRoutingOptions.fastModeBinding(role: role, options: availableModels)"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLegacyCodexModelsSheetPreservesFastModeThroughSaveNormalization() {
        let supportedOption = CodexModelOption(id: "gpt-5.5", supportsFastMode: true)
        let unsupportedOption = CodexModelOption(id: "custom-model", supportsFastMode: false)
        let sheet = ModelsSettingsSheet(
            config: .default,
            availableModels: [supportedOption, unsupportedOption],
            refreshModels: {},
            save: { _ in }
        )
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.5", reasoning: .medium, fastModeEnabled: true),
            sonnet: .init(model: "custom-model", reasoning: .medium, fastModeEnabled: true),
            haiku: .init(model: "gpt-5.5", reasoning: .medium, fastModeEnabled: false)
        )

        let normalized = CodexRoleRoutingOptions.normalizedCodex(
            codex,
            options: sheet.availableModels
        )

        XCTAssertTrue(normalized.opus.fastModeEnabled)
        XCTAssertFalse(normalized.sonnet.fastModeEnabled)
    }
}

private final class BundleMock: Bundle, @unchecked Sendable {
    private let storedInfo: [String: Any]

    init(info: [String: Any]) {
        self.storedInfo = info
        super.init()
    }

    override var infoDictionary: [String: Any]? {
        storedInfo
    }
}

final class GeneralServerControlSnapshotTests: XCTestCase {
    func testStoppedServerShowsStartAction() {
        let snapshot = GeneralServerControlSnapshot(status: DiagnosticStatus(
            severity: .warning,
            title: "Needs check",
            message: "Server status has not been checked yet."
        ))

        XCTAssertEqual(snapshot.title, "CLIProxyAPI Server")
        XCTAssertEqual(snapshot.actionTitle, "Start Server")
        XCTAssertFalse(snapshot.isRunning)
    }

    func testRunningServerShowsStopAction() {
        let snapshot = GeneralServerControlSnapshot(status: DiagnosticStatus(
            severity: .ready,
            title: "CLIProxyAPI Running",
            message: "Models are available on port 18317."
        ))

        XCTAssertEqual(snapshot.actionTitle, "Stop Server")
        XCTAssertTrue(snapshot.isRunning)
    }
}

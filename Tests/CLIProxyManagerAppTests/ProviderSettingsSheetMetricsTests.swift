import CLIProxyManagerCore
import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

final class ProviderSettingsSheetMetricsTests: XCTestCase {
    func testFooterActionButtonsUseRegularControlSize() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.footerActionButtonControlSize, .regular)
    }

    func testProviderSheetsReserveStableRoutingDimensionsBeforeModelsLoad() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.claudeHeight, 620)
        XCTAssertEqual(ProviderSettingsSheetMetrics.codexHeight, 700)
        XCTAssertEqual(ProviderSettingsSheetMetrics.claudeModelPickerWidth, 225)
    }

    func testClaudeDisplayUsesInitialModelsWithoutWaitingForReload() {
        let models = [ClaudeModelOption(id: "claude-opus-4-8", created: 500)]
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .opus,
            selection: .automatic,
            options: models
        )

        XCTAssertEqual(rows.first?.label, "Automatic — Opus 4.8")
    }

    func testClaudeModelsAreOnlyShownForProxyConnections() {
        XCTAssertTrue(ClaudeRoleRoutingOptions.showsModels(connectionMode: .proxy))
        XCTAssertFalse(ClaudeRoleRoutingOptions.showsModels(connectionMode: .direct))
    }

    func testCodexProviderKeepsScopedModelsWhenGlobalAvailableModelsChange() {
        let models = CodexProviderModelOptions.modelsAfterGlobalAvailableModelsChange(
            currentScopedModels: [CodexModelOption(id: "gpt-work-only")],
            globalAvailableModels: [CodexModelOption(id: "gpt-personal-only")]
        )

        XCTAssertEqual(models, [CodexModelOption(id: "gpt-work-only")])
    }

    func testCodexAPIInitialDefaultsApplyOnlyOnceWhileUnconfigured() {
        XCTAssertTrue(CodexAPIInitialDefaults.shouldApply(isConfigured: false, didApply: false))
        XCTAssertFalse(CodexAPIInitialDefaults.shouldApply(isConfigured: false, didApply: true))
        XCTAssertFalse(CodexAPIInitialDefaults.shouldApply(isConfigured: true, didApply: false))
    }

    func testCodexAPIInitialModelsPreferScopedOptionsWithCapabilities() {
        let scoped = [
            CodexModelOption(id: "gpt-5.6", supportedReasoning: [.low, .high], defaultReasoning: .high)
        ]

        let models = CodexAPIModelOptions.initialModels(
            codex: AppConfig.default.codexAPI.codex,
            availableModels: scoped
        )

        XCTAssertEqual(models, scoped)
    }

    func testCodexAPIModelsNormalizePrefixesReasoningAndDuplicates() {
        let models = CodexAPIModelOptions.baseModels(from: [
            "cpm-codex-api/gpt-5.6(xhigh)",
            "codex-work/gpt-5.6",
            "openai/gpt-5.6-mini(low)",
            "gpt-5.6-mini"
        ])

        XCTAssertEqual(models, ["gpt-5.6", "gpt-5.6-mini"])
    }

    func testCodexProviderRefreshButtonStaysDisabledDuringScopedReload() {
        XCTAssertTrue(
            CodexProviderModelLoadingPresentation.isRefreshDisabled(
                modelLoadingState: .idle,
                isReloading: true
            )
        )
    }

    func testCodexProviderShowsLoadingMessageDuringScopedReload() {
        XCTAssertEqual(
            CodexProviderModelLoadingPresentation.message(
                modelLoadingState: .idle,
                isReloading: true
            ),
            CodexModelLoadingState.loadingModels.message
        )
    }
}

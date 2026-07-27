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
        XCTAssertEqual(ProviderSettingsSheetMetrics.codexWidth, 680)
        XCTAssertEqual(ProviderSettingsSheetMetrics.codexHeight, 720)
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

    func testCodexAPINewProfileModelsAreCredentialIndependentAndExposeReasoningCapabilities() {
        let models = CodexAPIModelOptions.newProfileModels

        XCTAssertEqual(models.map(\.id), [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4"
        ])
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .auto,
                model: "gpt-5.6-sol",
                options: models
            ),
            [.auto, .low, .medium, .high, .xhigh, .max]
        )
    }

    func testCodexAPINewProfileAppliesDefaultModelSynchronouslyWithoutChangingReasoning() {
        let initial = CodexAPIModelOptions.initialCodex(
            AppConfig.Codex(
                opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh),
                sonnet: .init(model: "gpt-5.6-sol", reasoning: .medium),
                haiku: .init(model: "gpt-5.6-sol", reasoning: .low)
            ),
            isNewProfile: true,
            defaultModel: "gpt-5.6-terra"
        )

        XCTAssertEqual(initial.opus, .init(model: "gpt-5.6-terra", reasoning: .xhigh))
        XCTAssertEqual(initial.sonnet, .init(model: "gpt-5.6-terra", reasoning: .medium))
        XCTAssertEqual(initial.haiku, .init(model: "gpt-5.6-terra", reasoning: .low))

        let existing = CodexAPIModelOptions.initialCodex(
            AppConfig.Codex(
                opus: .init(model: "gpt-5.6-sol", reasoning: .high),
                sonnet: .init(model: "gpt-5.5", reasoning: .medium),
                haiku: .init(model: "gpt-5.4", reasoning: .low)
            ),
            isNewProfile: false,
            defaultModel: "gpt-5.6-terra"
        )
        XCTAssertEqual(existing.opus.model, "gpt-5.6-sol")
        XCTAssertEqual(existing.sonnet.model, "gpt-5.5")
        XCTAssertEqual(existing.haiku.model, "gpt-5.4")
    }

    func testCodexAPINewProfileDoesNotReloadModelsOnAppear() {
        XCTAssertFalse(CodexAPIModelDiscovery.shouldReloadOnAppear(isNewProfile: true))
        XCTAssertTrue(CodexAPIModelDiscovery.shouldReloadOnAppear(isNewProfile: false))
    }

    func testCodexAPIEmptyRefreshKeepsCurrentScopedModels() {
        let current = [CodexModelOption(id: "gpt-5.6-terra", supportedReasoning: [.low, .high])]

        XCTAssertEqual(
            CodexAPIModelDiscovery.modelsAfterRefresh(current: current, refreshed: []),
            current
        )
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

    func testCodexAPIModelsStripOnlyManagedPrefixAndPreserveNestedIdentifiers() {
        let models = CodexAPIModelOptions.baseModels(from: [
            "cpm-codex-api/openai/gpt-5.6(xhigh)",
            "openai/gpt-5.6(xhigh)",
            "cpm-codex-api/gpt-5.6-mini(low)",
            "gpt-5.6-mini"
        ])

        XCTAssertEqual(models, ["openai/gpt-5.6", "gpt-5.6-mini"])
    }

    func testCodexAPIModelsCanonicalizeManagedFastAliases() {
        XCTAssertEqual(
            CodexAPIModelOptions.baseModels(from: [
                "cpm-codex-api/gpt-5.6-sol-fast(xhigh)",
                "gpt-5.6-sol"
            ]),
            ["gpt-5.6-sol"]
        )
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

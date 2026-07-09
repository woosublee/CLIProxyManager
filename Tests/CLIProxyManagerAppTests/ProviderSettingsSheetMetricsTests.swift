import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

final class ProviderSettingsSheetMetricsTests: XCTestCase {
    func testFooterActionButtonsUseRegularControlSize() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.footerActionButtonControlSize, .regular)
    }

    func testCodexProviderKeepsScopedModelsWhenGlobalAvailableModelsChange() {
        let models = CodexProviderModelOptions.modelsAfterGlobalAvailableModelsChange(
            currentScopedModels: ["gpt-work-only"],
            globalAvailableModels: ["gpt-personal-only"]
        )

        XCTAssertEqual(models, ["gpt-work-only"])
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

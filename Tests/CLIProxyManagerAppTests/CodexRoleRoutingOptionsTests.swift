import XCTest
import SwiftUI
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class CodexRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        CodexModelOption(
            id: "gpt-5.5",
            supportedReasoning: [.low, .medium, .high, .xhigh],
            defaultReasoning: .medium,
            supportsFastMode: true,
            contextWindow: 372_000
        ),
        CodexModelOption(
            id: "gpt-5.6-sol",
            supportedReasoning: [.low, .medium, .high, .xhigh, .max],
            defaultReasoning: .low,
            supportsFastMode: false
        ),
        CodexModelOption(
            id: "custom-model",
            supportedReasoning: [.low, .medium],
            defaultReasoning: .medium,
            supportsFastMode: false,
            contextWindow: 128_000
        )
    ]

    func testReasoningValuesAlwaysStartWithAutoAndFollowModelCapabilityOrder() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .xhigh,
                model: "gpt-5.5",
                options: options
            ),
            [.auto, .low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .max,
                model: "gpt-5.6-sol",
                options: options
            ),
            [.auto, .low, .medium, .high, .xhigh, .max]
        )
    }

    func testUnknownCapabilityPreservesOnlyAutoAndCurrentStoredReasoning() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .xhigh,
                model: "unknown-model",
                options: options
            ),
            [.auto, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .auto,
                model: "unknown-model",
                options: options
            ),
            [.auto]
        )
    }

    func testListedModelWithUnknownCapabilityPreservesCurrentStoredReasoning() {
        let unknownOptions = [CodexModelOption(id: "custom-model")]

        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .xhigh,
                model: "custom-model",
                options: unknownOptions
            ),
            [.auto, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(
                currentReasoning: .xhigh,
                model: "custom-model",
                options: unknownOptions
            ),
            .xhigh
        )
    }

    func testModelChangeUsesSupportedDefaultThenAuto() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(
                currentReasoning: .max,
                model: "gpt-5.5",
                options: options
            ),
            .medium
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedReasoning(
                currentReasoning: .max,
                model: "missing-model",
                options: options
            ),
            .max
        )
    }

    func testFastModeIsEnabledOnlyForSupportedModel() {
        XCTAssertTrue(CodexRoleRoutingOptions.supportsFastMode(model: "gpt-5.5", options: options))
        XCTAssertFalse(CodexRoleRoutingOptions.supportsFastMode(model: "custom-model", options: options))
        XCTAssertFalse(CodexRoleRoutingOptions.supportsFastMode(model: "missing-model", options: options))
    }

    func testModelChangeNormalizesReasoningAndDisablesUnsupportedFastMode() {
        let role = AppConfig.CodexRole(
            model: "gpt-5.5",
            reasoning: .xhigh,
            fastModeEnabled: true
        )

        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedRole(role, model: "custom-model", options: options),
            AppConfig.CodexRole(
                model: "custom-model",
                reasoning: .medium,
                detectedContextWindow: 128_000,
                fastModeEnabled: false
            )
        )
    }

    func testNormalizedCodexPreservesFastForUnknownCapabilityButDisablesAuthoritativeUnsupported() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.5", reasoning: .xhigh, fastModeEnabled: true),
            sonnet: .init(model: "custom-model", reasoning: .medium, fastModeEnabled: true),
            haiku: .init(model: "missing-model", reasoning: .low, fastModeEnabled: true)
        )

        let normalized = CodexRoleRoutingOptions.normalizedCodex(codex, options: options)
        let normalizedWithoutOptions = CodexRoleRoutingOptions.normalizedCodex(codex, options: [])

        XCTAssertTrue(normalized.opus.fastModeEnabled)
        XCTAssertFalse(normalized.sonnet.fastModeEnabled)
        XCTAssertTrue(normalized.haiku.fastModeEnabled)
        XCTAssertTrue(normalizedWithoutOptions.opus.fastModeEnabled)
        XCTAssertTrue(normalizedWithoutOptions.sonnet.fastModeEnabled)
        XCTAssertTrue(normalizedWithoutOptions.haiku.fastModeEnabled)
    }

    func testFastModeBindingCannotEnableUnknownCapabilityButPreservesStoredTrue() {
        var role = AppConfig.CodexRole(
            model: "missing-model",
            reasoning: .auto,
            fastModeEnabled: true
        )
        let binding = CodexRoleRoutingOptions.fastModeBinding(
            role: Binding(get: { role }, set: { role = $0 }),
            options: options
        )

        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(role.fastModeEnabled)
        binding.wrappedValue = true
        XCTAssertFalse(role.fastModeEnabled)
    }

    func testModelChangeDisablesFastWhenNewCapabilityIsUnknown() {
        let role = AppConfig.CodexRole(
            model: "gpt-5.5",
            reasoning: .xhigh,
            fastModeEnabled: true
        )

        XCTAssertFalse(
            CodexRoleRoutingOptions.normalizedRole(
                role,
                model: "missing-model",
                options: options
            ).fastModeEnabled
        )
    }

    func testFastModeHelpTextMentionsSpeedAndUsage() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.fastModeHelpText,
            "Fast mode can be about 1.5× faster and may consume more usage or credits."
        )
    }

    func testModelIDsPreserveLegacyCurrentModelWithoutAddingRoutedModel() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "legacy-model", options: options),
            ["legacy-model", "gpt-5.5", "gpt-5.6-sol", "custom-model"]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "codex-work/gpt-5.5", options: options),
            ["gpt-5.5", "gpt-5.6-sol", "custom-model"]
        )
    }

    func testNormalizedRoleUpdatesDetectedContextWindowFromMatchingOption() {
        let role = AppConfig.CodexRole(model: "custom-model", reasoning: .auto, detectedContextWindow: nil)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "gpt-5.5", options: options)

        XCTAssertEqual(normalized.detectedContextWindow, 372_000)
    }

    func testNormalizedRoleClearsDetectedContextWindowWhenModelChangesToUnknown() {
        let role = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .auto, detectedContextWindow: 372_000)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "missing-model", options: options)

        XCTAssertNil(normalized.detectedContextWindow)
    }

    func testNormalizedRolePreservesLastSuccessfulContextWhenSameModelMetadataIsMissing() {
        let role = AppConfig.CodexRole(model: "gpt-5.6-sol", reasoning: .auto, detectedContextWindow: 372_000)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "gpt-5.6-sol", options: options)

        XCTAssertEqual(normalized.detectedContextWindow, 372_000)
    }

    func testNormalizedRoleClearsDetectedContextWindowWhenNewModelOptionHasNoValue() {
        let role = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .auto, detectedContextWindow: 372_000)

        let normalized = CodexRoleRoutingOptions.normalizedRole(role, model: "gpt-5.6-sol", options: options)

        XCTAssertNil(normalized.detectedContextWindow)
        XCTAssertEqual(normalized.effectiveContextWindow, 372_000)
    }

    func testContextWindowDisplayAbbreviatesEffectiveContextValues() {
        let terra = AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .medium)

        XCTAssertEqual(
            CodexRoleRoutingOptions.contextWindowDisplay(terra.effectiveContextWindow),
            "372K"
        )
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(1_050_000), "1.05M")
    }

    func testContextWindowDisplayShowsDashForUnknownOrStandardValues() {
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(nil), "—")
        XCTAssertEqual(CodexRoleRoutingOptions.contextWindowDisplay(200_000), "—")
    }
}

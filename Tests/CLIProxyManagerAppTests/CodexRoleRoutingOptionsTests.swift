import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class CodexRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        CodexModelOption(
            id: "gpt-5.5",
            supportedReasoning: [.low, .medium, .high, .xhigh],
            defaultReasoning: .medium,
            supportsFastMode: true
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
            supportsFastMode: false
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
            contextWindow: .context1m,
            fastModeEnabled: true
        )

        XCTAssertEqual(
            CodexRoleRoutingOptions.normalizedRole(role, model: "custom-model", options: options),
            AppConfig.CodexRole(
                model: "custom-model",
                reasoning: .medium,
                contextWindow: .context1m,
                fastModeEnabled: false
            )
        )
    }

    func testNormalizedCodexTurnsOffFastForUnsupportedAndUnknownModels() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: true),
            sonnet: .init(model: "custom-model", reasoning: .medium, contextWindow: .auto, fastModeEnabled: true),
            haiku: .init(model: "missing-model", reasoning: .low, contextWindow: .auto, fastModeEnabled: true)
        )

        let normalized = CodexRoleRoutingOptions.normalizedCodex(codex, options: options)

        XCTAssertTrue(normalized.opus.fastModeEnabled)
        XCTAssertFalse(normalized.sonnet.fastModeEnabled)
        XCTAssertFalse(normalized.haiku.fastModeEnabled)
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
}

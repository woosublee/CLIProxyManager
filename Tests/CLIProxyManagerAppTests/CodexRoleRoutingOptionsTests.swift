import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class CodexRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        CodexModelOption(
            id: "gpt-5.5",
            supportedReasoning: [.low, .medium, .high, .xhigh],
            defaultReasoning: .medium
        ),
        CodexModelOption(
            id: "gpt-5.6-sol",
            supportedReasoning: [.low, .medium, .high, .xhigh, .max],
            defaultReasoning: .low
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
                model: "custom-model",
                options: options
            ),
            [.auto, .xhigh]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.reasoningValues(
                currentReasoning: .auto,
                model: "custom-model",
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
                model: "custom-model",
                options: options
            ),
            .max
        )
    }

    func testModelIDsPreserveLegacyCurrentModelWithoutAddingRoutedModel() {
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "legacy-model", options: options),
            ["legacy-model", "gpt-5.5", "gpt-5.6-sol"]
        )
        XCTAssertEqual(
            CodexRoleRoutingOptions.modelIDs(currentModel: "codex-work/gpt-5.5", options: options),
            ["gpt-5.5", "gpt-5.6-sol"]
        )
    }
}

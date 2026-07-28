import XCTest
@testable import CLIProxyManagerCore

final class CodexContextWindowPolicyTests: XCTestCase {
    func testFallbackContextWindowsMatchBundledScopedRegistry() {
        let expected: [String: Int] = [
            "gpt-5.6-sol": 372_000,
            "gpt-5.6-terra": 372_000,
            "gpt-5.6-luna": 372_000,
            "gpt-5.5": 272_000,
            "codex-auto-review": 272_000,
            "gpt-image-1.5": 272_000,
            "gpt-image-2": 272_000,
            "gpt-5.4": 1_050_000,
            "gpt-5.4-mini": 400_000,
            "gpt-5.3-codex-spark": 128_000
        ]

        for (model, contextWindow) in expected {
            XCTAssertEqual(
                CodexContextWindowPolicy.fallbackContextWindow(for: model),
                contextWindow,
                model
            )
        }
    }

    func testFallbackCanonicalizesRoutingReasoningFastAliasAndOneMillionSuffix() {
        XCTAssertEqual(
            CodexContextWindowPolicy.fallbackContextWindow(
                for: " codex-personal/gpt-5.6-terra-fast(medium)[1m] "
            ),
            372_000
        )
    }

    func testDetectedContextWindowTakesPriorityOverFallback() {
        XCTAssertEqual(
            CodexContextWindowPolicy.effectiveContextWindow(
                model: "gpt-5.4",
                detectedContextWindow: 272_000
            ),
            272_000
        )
    }

    func testUnknownModelWithoutMetadataStaysUnknown() {
        XCTAssertNil(
            CodexContextWindowPolicy.effectiveContextWindow(
                model: "custom-model",
                detectedContextWindow: nil
            )
        )
    }
}

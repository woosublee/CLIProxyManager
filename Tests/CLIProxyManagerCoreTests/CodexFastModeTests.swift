import XCTest
@testable import CLIProxyManagerCore

final class CodexFastModeTests: XCTestCase {
    func testManagedAliasRoundTripsCanonicalModel() {
        XCTAssertEqual(CodexFastMode.alias(for: "gpt-5.6-sol"), "gpt-5.6-sol-cpm-fast")
        XCTAssertTrue(CodexFastMode.isManagedAlias("gpt-5.6-sol-cpm-fast"))
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-cpm-fast"), "gpt-5.6-sol")
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-cpm-fast(xhigh)"), "gpt-5.6-sol")
    }

    func testModelIdentifierAppliesFastAliasBeforeReasoningSuffix() {
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .xhigh, fastModeEnabled: true),
            "gpt-5.6-sol-cpm-fast(xhigh)"
        )
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .auto, fastModeEnabled: true),
            "gpt-5.6-sol-cpm-fast"
        )
        XCTAssertEqual(
            CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .medium, fastModeEnabled: false),
            "gpt-5.6-sol(medium)"
        )
    }
}

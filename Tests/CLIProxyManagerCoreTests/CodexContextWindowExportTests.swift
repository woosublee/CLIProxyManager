import XCTest
@testable import CLIProxyManagerCore

final class CodexContextWindowExportTests: XCTestCase {
    func testAutoCompactWindowReturnsMinimumActualMaximumAmongExtendedContextRoles() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000),
            sonnet: .init(model: "gpt-5.4-mini", reasoning: .medium, detectedContextWindow: 400_000),
            haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
        )

        XCTAssertEqual(CodexContextWindowExport.autoCompactWindow(for: codex), 372_000)
    }

    func testAutoCompactWindowUsesFallbackWhenDetectedMetadataIsMissing() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.4", reasoning: .xhigh),
            sonnet: .init(model: "gpt-5.6-terra", reasoning: .medium),
            haiku: .init(model: "gpt-5.5", reasoning: .low)
        )

        XCTAssertEqual(CodexContextWindowExport.autoCompactWindow(for: codex), 272_000)
    }

    func testAutoCompactWindowReturnsNilWhenNoRoleExceedsStandardContext() {
        let codex = AppConfig.Codex(
            opus: .init(model: "custom-model", reasoning: .xhigh, detectedContextWindow: 200_000),
            sonnet: .init(model: "gpt-5.3-codex-spark", reasoning: .medium),
            haiku: .init(model: "unknown-model", reasoning: .low)
        )

        XCTAssertNil(CodexContextWindowExport.autoCompactWindow(for: codex))
    }
}

import XCTest
@testable import CLIProxyManagerCore

final class CodexContextWindowExportTests: XCTestCase {
    func testAutoCompactWindowReturnsMinimumAmongExtendedContextRoles() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.6-sol", reasoning: .xhigh, detectedContextWindow: 372_000),
            sonnet: .init(model: "gpt-5.4-mini", reasoning: .medium, detectedContextWindow: 400_000),
            haiku: .init(model: "gpt-5.5", reasoning: .low, detectedContextWindow: 200_000)
        )

        XCTAssertEqual(CodexContextWindowExport.autoCompactWindow(for: codex), 372_000)
    }

    func testAutoCompactWindowReturnsNilWhenNoRoleExceedsStandardContext() {
        let codex = AppConfig.Codex(
            opus: .init(model: "gpt-5.5", reasoning: .xhigh, detectedContextWindow: 200_000),
            sonnet: .init(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: nil),
            haiku: .init(model: "gpt-5.5", reasoning: .low)
        )

        XCTAssertNil(CodexContextWindowExport.autoCompactWindow(for: codex))
    }
}

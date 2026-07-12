import XCTest
import CLIProxyManagerCore
@testable import CLIProxyManagerApp

final class ClaudeRoleRoutingOptionsTests: XCTestCase {
    private let options = [
        ClaudeModelOption(id: "claude-opus-4-8", created: 500),
        ClaudeModelOption(id: "claude-opus-4-7", created: 400),
        ClaudeModelOption(id: "claude-sonnet-5", created: 500),
        ClaudeModelOption(id: "claude-haiku-4-5", created: 500),
        ClaudeModelOption(id: "claude-custom-preview", family: .other, created: 600)
    ]

    func testAutomaticRowUsesTheRuntimeResolverResult() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .opus,
            selection: .automatic,
            options: options
        )

        XCTAssertEqual(rows.first, .init(selection: .automatic, label: "Automatic — Opus 4.8"))
        XCTAssertEqual(rows.dropFirst().map(\.selection), [
            .model("claude-opus-4-8"),
            .model("claude-opus-4-7")
        ])
    }

    func testDisplayNameRemovesRoutingAndClaudePrefixes() {
        XCTAssertEqual(ClaudeRoleRoutingOptions.displayName(for: "woosub-work/claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ClaudeRoleRoutingOptions.displayName(for: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ClaudeRoleRoutingOptions.displayName(for: "claude-haiku-4-5"), "Haiku 4.5")
    }

    func testRowsExcludeWrongFamiliesAndOtherModels() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .sonnet,
            selection: .automatic,
            options: options
        )

        XCTAssertEqual(rows.map(\.selection), [.automatic, .model("claude-sonnet-5")])
    }

    func testRowsPreserveUnavailableStoredSelection() {
        let rows = ClaudeRoleRoutingOptions.rows(
            role: .opus,
            selection: .model("claude-opus-4-6"),
            options: options
        )

        XCTAssertEqual(rows.last, .init(
            selection: .model("claude-opus-4-6"),
            label: "Unavailable — Opus 4.6"
        ))
    }

    func testModelsSectionVisibilityIsProxyOnly() {
        XCTAssertTrue(ClaudeRoleRoutingOptions.showsModels(connectionMode: .proxy))
        XCTAssertFalse(ClaudeRoleRoutingOptions.showsModels(connectionMode: .direct))
    }
}

import XCTest
@testable import CLIProxyManagerCore

final class DashboardViewModelTests: XCTestCase {
    func testProfileCardUpdatingStatusPreservesIdentityAndLabels() {
        let original = ProfileCard(
            command: "cc",
            title: "Claude Subscription",
            subtitle: "Uses the official Claude Code login",
            status: DiagnosticStatus(severity: .warning, title: "Needs check", message: "Status has not been checked yet.")
        )
        let ready = DiagnosticStatus(severity: .ready, title: "Ready", message: "Available.")

        let updated = original.updatingStatus(ready)

        XCTAssertEqual(updated.id, "cc")
        XCTAssertEqual(updated.command, original.command)
        XCTAssertEqual(updated.title, original.title)
        XCTAssertEqual(updated.subtitle, original.subtitle)
        XCTAssertEqual(updated.status, ready)
    }

    func testDefaultProfileCardsUseConfiguredCommandsAndLabels() {
        let config = AppConfig(
            port: 9444,
            commands: AppConfig.Commands(cc: "claude-local", ccapi: "api-local", ccodex: "codex-local"),
            ccapi: AppConfig.ClaudeAPI(model: "test-claude"),
            ccodex: AppConfig.Codex(
                opus: AppConfig.CodexRole(model: "test-opus", reasoning: .auto, contextWindow: .auto),
                sonnet: AppConfig.CodexRole(model: "test-sonnet", reasoning: .auto, contextWindow: .auto),
                haiku: AppConfig.CodexRole(model: "test-haiku", reasoning: .auto, contextWindow: .auto)
            ),
            includeDangerouslySkipPermissions: false,
            startAtLogin: false,
            showDockIcon: true,
            showMenuBarIcon: true
        )

        let cards = ProfileCard.makeDefaultCards(config: config)

        XCTAssertEqual(cards.map(\.id), ["claude-local", "codex-local"])
        XCTAssertEqual(cards.map(\.command), ["claude-local", "codex-local"])
        XCTAssertEqual(cards.map(\.title), ["Claude Subscription", "OpenAI/Codex"])
        XCTAssertEqual(cards.map(\.subtitle), [
            "Uses the official Claude Code login",
            "Routed through CLIProxyAPI"
        ])
        XCTAssertEqual(cards.map(\.status), Array(repeating: DiagnosticStatus(
            severity: .warning,
            title: "Needs check",
            message: "Status has not been checked yet."
        ), count: 2))
    }

    func testDefaultProfileCardsExcludeClaudeAPIEvenWhenConfigured() {
        var config = AppConfig.default
        config.commands.ccapi = "manualapi"
        config.ccapi = AppConfig.ClaudeAPI(model: "manual-model")

        let cards = ProfileCard.makeDefaultCards(config: config)

        XCTAssertFalse(cards.contains { $0.command == "manualapi" })
        XCTAssertFalse(cards.contains { $0.title == "Claude API" })
    }
}

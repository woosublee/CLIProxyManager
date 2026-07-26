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
        var config = AppConfig.default
        config.port = 9444
        config.oauthCommandProfiles = [
            .init(
                id: "claude-local",
                provider: .claude,
                authProfileID: "claude-local.json",
                commandName: "claude-local"
            ),
            .init(
                id: "codex-local",
                provider: .codex,
                authProfileID: "codex-local.json",
                commandName: "codex-local",
                codex: .default
            )
        ]

        let cards = ProfileCard.makeDefaultCards(config: config)

        XCTAssertEqual(cards.map(\.id), [ProfileCard.claudeID, ProfileCard.codexID])
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

    func testDefaultProfileCardsUseStableIDsWhenCommandNamesAreBlank() {
        let cards = ProfileCard.makeDefaultCards(config: .default)

        XCTAssertEqual(cards.map(\.id), [ProfileCard.claudeID, ProfileCard.codexID])
        XCTAssertEqual(Set(cards.map(\.id)).count, 2)
        XCTAssertEqual(cards.map(\.command), ["", ""])
    }

    func testDefaultProfileCardsExcludeClaudeAPIEvenWhenConfigured() {
        var config = AppConfig.default
        config.claudeAPI.commandName = "manualapi"

        let cards = ProfileCard.makeDefaultCards(config: config)

        XCTAssertFalse(cards.contains { $0.command == "manualapi" })
        XCTAssertFalse(cards.contains { $0.title == "Claude API" })
    }
}

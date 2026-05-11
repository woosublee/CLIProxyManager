import XCTest
@testable import CLIProxyManagerCore

final class DashboardViewModelTests: XCTestCase {
    func testProfileCardUpdatingStatusPreservesIdentityAndLabels() {
        let original = ProfileCard(
            command: "cc",
            title: "Claude 구독",
            subtitle: "Claude Code 공식 로그인 사용",
            status: DiagnosticStatus(severity: .warning, title: "확인 필요", message: "상태 확인 전입니다.")
        )
        let ready = DiagnosticStatus(severity: .ready, title: "준비됨", message: "사용할 수 있습니다.")

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
        XCTAssertEqual(cards.map(\.title), ["Claude 구독", "OpenAI/Codex"])
        XCTAssertEqual(cards.map(\.subtitle), [
            "Claude Code 공식 로그인 사용",
            "CLIProxyAPI 경유"
        ])
        XCTAssertEqual(cards.map(\.status), Array(repeating: DiagnosticStatus(
            severity: .warning,
            title: "확인 필요",
            message: "상태 확인 전입니다."
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

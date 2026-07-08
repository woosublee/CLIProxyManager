import XCTest
@testable import CLIProxyManagerCore

final class RoundRobinSelectionServiceTests: XCTestCase {
    func testCodexSelectionUsesIncludedOrderAndRoundRobinModelSettings() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-fast", provider: .codex, authProfileID: "codex-fast.json", commandName: "ccfast", codex: testCodex(model: "gpt-fast"), modelPrefix: "codex-fast"),
            AppConfig.OAuthCommandProfile(id: "codex-deep", provider: .codex, authProfileID: "codex-deep.json", commandName: "ccdeep", codex: testCodex(model: "gpt-deep"), modelPrefix: "codex-deep")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"],
                codex: testCodex(model: "gpt-rr")
            )
        ]
        let state = StubRoundRobinStateSelector(selections: ["codex-deep.json"])
        let service = RoundRobinSelectionService(stateSelector: state)

        let output = try service.shellEnvironmentAssignments(
            profileID: "codex-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "codex-fast.json", type: .codex, email: "fast@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-fast"),
                AuthProfile(fileName: "codex-deep.json", type: .codex, email: "deep@example.com", accountID: nil, expired: nil, disabled: false, prefix: "codex-deep")
            ]
        )

        XCTAssertEqual(state.calls, [RoundRobinStateCall(groupID: "codex-default", candidates: ["codex-fast.json", "codex-deep.json"])])
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-deep/gpt-rr(xhigh)'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='codex-deep/gpt-rr(medium)'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-deep/gpt-rr(low)'"))
        XCTAssertTrue(output.contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-deep.json'"))
    }

    func testClaudeSelectionUsesDefaultClaudeModels() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork", modelPrefix: "claude-work"),
            AppConfig.OAuthCommandProfile(id: "claude-personal", provider: .claude, authProfileID: "claude-personal.json", commandName: "ccpersonal", modelPrefix: "claude-personal")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"])
        ]
        let service = RoundRobinSelectionService(stateSelector: StubRoundRobinStateSelector(selections: ["claude-work.json"]))

        let output = try service.shellEnvironmentAssignments(
            profileID: "claude-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "claude-work.json", type: .claude, email: "work@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-work"),
                AuthProfile(fileName: "claude-personal.json", type: .claude, email: "personal@example.com", accountID: nil, expired: nil, disabled: false, prefix: "claude-personal")
            ]
        )

        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-7'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-4-6'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5-20251001'"))
    }

    func testDisabledPrefixlessAndProviderMismatchedProfilesAreExcluded() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-good", provider: .codex, authProfileID: "codex-good.json", commandName: "ccgood", modelPrefix: "codex-good"),
            AppConfig.OAuthCommandProfile(id: "codex-disabled", provider: .codex, authProfileID: "codex-disabled.json", commandName: "ccdisabled", modelPrefix: "codex-disabled"),
            AppConfig.OAuthCommandProfile(id: "codex-prefixless", provider: .codex, authProfileID: "codex-prefixless.json", commandName: "ccprefixless", modelPrefix: ""),
            AppConfig.OAuthCommandProfile(id: "claude-wrong", provider: .claude, authProfileID: "claude-wrong.json", commandName: "ccwrong", modelPrefix: "claude-wrong")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-good.json", "codex-disabled.json", "codex-prefixless.json", "claude-wrong.json"]
            )
        ]
        let service = RoundRobinSelectionService(stateSelector: StubRoundRobinStateSelector(selections: []))

        XCTAssertThrowsError(try service.shellEnvironmentAssignments(
            profileID: "codex-default",
            config: config,
            authProfiles: [
                AuthProfile(fileName: "codex-good.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-good"),
                AuthProfile(fileName: "codex-disabled.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: true, prefix: "codex-disabled"),
                AuthProfile(fileName: "codex-prefixless.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: nil),
                AuthProfile(fileName: "claude-wrong.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-wrong")
            ]
        )) { error in
            XCTAssertEqual(error as? RoundRobinSelectionError, .insufficientCandidates("codex-default", 1))
        }
    }

    private func testCodex(model: String) -> AppConfig.Codex {
        AppConfig.Codex(
            opus: AppConfig.CodexRole(model: model, reasoning: .xhigh, contextWindow: .auto),
            sonnet: AppConfig.CodexRole(model: model, reasoning: .medium, contextWindow: .auto),
            haiku: AppConfig.CodexRole(model: model, reasoning: .low, contextWindow: .auto)
        )
    }
}

private struct RoundRobinStateCall: Equatable {
    let groupID: String
    let candidates: [String]
}

private final class StubRoundRobinStateSelector: RoundRobinStateSelecting, @unchecked Sendable {
    private(set) var calls: [RoundRobinStateCall] = []
    private var selections: [String]

    init(selections: [String]) {
        self.selections = selections
    }

    func nextSelectedAuthProfileID(groupID: String, candidates: [String]) throws -> String {
        calls.append(RoundRobinStateCall(groupID: groupID, candidates: candidates))
        return selections.removeFirst()
    }
}

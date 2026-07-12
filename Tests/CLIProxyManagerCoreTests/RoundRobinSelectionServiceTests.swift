import XCTest
@testable import CLIProxyManagerCore

final class RoundRobinSelectionServiceTests: XCTestCase {
    func testCodexSelectionUsesIncludedOrderAndRoundRobinModelSettings() async throws {
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

        let output = try await service.shellEnvironmentAssignments(
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

    func testClaudeSelectionResolvesModelsForActuallySelectedAccount() async throws {
        var config = AppConfig.default
        config.port = 18_888
        config.oauthCommandProfiles = [
            .init(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                claude: .automatic,
                modelPrefix: "claude-work"
            ),
            .init(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal",
                claude: ClaudeRouting(
                    opus: .model("claude-opus-4-7"),
                    sonnet: .automatic,
                    haiku: .automatic
                ),
                modelPrefix: "claude-personal"
            )
        ]
        config.roundRobinProfiles = [
            .init(
                id: "claude-default",
                provider: .claude,
                isEnabled: true,
                commandName: "cc",
                includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"]
            )
        ]
        let models = StubRoundRobinClaudeModelListing(optionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ],
            "claude-personal": [
                .init(id: "claude-opus-4-7"),
                .init(id: "claude-sonnet-4-6"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let service = RoundRobinSelectionService(
            stateSelector: StubRoundRobinStateSelector(selections: ["claude-personal.json"]),
            claudeModelClient: models
        )

        let output = try await service.shellEnvironmentAssignments(
            profileID: "claude-default",
            config: config,
            authProfiles: [
                .init(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-work"),
                .init(fileName: "claude-personal.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-personal")
            ]
        )

        XCTAssertEqual(models.prefixes, ["claude-personal"])
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-personal/claude-opus-4-7'"))
        XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-personal/claude-sonnet-4-6'"))
        XCTAssertTrue(output.contains("CLIPROXY_ROUND_ROBIN_PROFILE='claude-personal.json'"))
    }

    func testClaudeUnavailableManualSelectionDoesNotReselectAccount() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: "claude-work.json", commandName: "ccwork", claude: .automatic, modelPrefix: "claude-work"),
            .init(
                id: "claude-personal",
                provider: .claude,
                authProfileID: "claude-personal.json",
                commandName: "ccpersonal",
                claude: .init(opus: .model("claude-opus-4-7"), sonnet: .automatic, haiku: .automatic),
                modelPrefix: "claude-personal"
            )
        ]
        config.roundRobinProfiles = [
            .init(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-work.json", "claude-personal.json"])
        ]
        let state = StubRoundRobinStateSelector(selections: ["claude-personal.json", "claude-work.json"])
        let models = StubRoundRobinClaudeModelListing(optionsByPrefix: [
            "claude-personal": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let service = RoundRobinSelectionService(stateSelector: state, claudeModelClient: models)

        do {
            _ = try await service.shellEnvironmentAssignments(
                profileID: "claude-default",
                config: config,
                authProfiles: [
                    .init(fileName: "claude-work.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-work"),
                    .init(fileName: "claude-personal.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-personal")
                ]
            )
            XCTFail("Expected unavailable manual model selection to fail")
        } catch {
            XCTAssertEqual(
                error as? ClaudeModelResolutionError,
                .selectedModelUnavailable(role: .opus, model: "claude-opus-4-7")
            )
        }

        XCTAssertEqual(state.calls.count, 1)
        XCTAssertEqual(models.prefixes, ["claude-personal"])
    }

    func testDirectClaudeProfilesAreExcludedWithoutModelRequest() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "claude-proxy", provider: .claude, authProfileID: "claude-proxy.json", commandName: "ccproxy", modelPrefix: "proxy"),
            .init(id: "claude-direct", provider: .claude, authProfileID: "claude-direct.json", commandName: "ccdirect", modelPrefix: "direct", connectionMode: .direct)
        ]
        config.roundRobinProfiles = [
            .init(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-proxy.json", "claude-direct.json"])
        ]
        let models = StubRoundRobinClaudeModelListing(optionsByPrefix: [
            "direct": [.init(id: "claude-opus-4-8"), .init(id: "claude-sonnet-5"), .init(id: "claude-haiku-4-5")]
        ])
        let state = StubRoundRobinStateSelector(selections: ["claude-direct.json"])
        let service = RoundRobinSelectionService(stateSelector: state, claudeModelClient: models)

        do {
            _ = try await service.shellEnvironmentAssignments(
                profileID: "claude-default",
                config: config,
                authProfiles: [
                    .init(fileName: "claude-proxy.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "proxy"),
                    .init(fileName: "claude-direct.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "direct")
                ]
            )
            XCTFail("Expected direct Claude account to leave insufficient candidates")
        } catch {
            XCTAssertEqual(error as? RoundRobinSelectionError, .insufficientCandidates("claude-default", 1))
        }

        XCTAssertTrue(state.calls.isEmpty)
        XCTAssertTrue(models.prefixes.isEmpty)
    }

    func testDisabledPrefixlessAndProviderMismatchedProfilesAreExcluded() async throws {
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

        do {
            _ = try await service.shellEnvironmentAssignments(
                profileID: "codex-default",
                config: config,
                authProfiles: [
                    AuthProfile(fileName: "codex-good.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-good"),
                    AuthProfile(fileName: "codex-disabled.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: true, prefix: "codex-disabled"),
                    AuthProfile(fileName: "codex-prefixless.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: nil),
                    AuthProfile(fileName: "claude-wrong.json", type: .claude, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "claude-wrong")
                ]
            )
            XCTFail("Expected insufficient candidates")
        } catch {
            XCTAssertEqual(error as? RoundRobinSelectionError, .insufficientCandidates("codex-default", 1))
        }
    }

    func testDuplicateCommandProfilesForIncludedAuthProfileThrowExplicitError() async throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-a", provider: .codex, authProfileID: "codex-a.json", commandName: "cca", modelPrefix: "codex-a"),
            AppConfig.OAuthCommandProfile(id: "codex-a-duplicate", provider: .codex, authProfileID: "codex-a.json", commandName: "ccadup", modelPrefix: "codex-a-dup"),
            AppConfig.OAuthCommandProfile(id: "codex-b", provider: .codex, authProfileID: "codex-b.json", commandName: "ccb", modelPrefix: "codex-b")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-a.json", "codex-b.json"]
            )
        ]
        let service = RoundRobinSelectionService(stateSelector: StubRoundRobinStateSelector(selections: []))

        do {
            _ = try await service.shellEnvironmentAssignments(
                profileID: "codex-default",
                config: config,
                authProfiles: [
                    AuthProfile(fileName: "codex-a.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-a"),
                    AuthProfile(fileName: "codex-b.json", type: .codex, email: nil, accountID: nil, expired: nil, disabled: false, prefix: "codex-b")
                ]
            )
            XCTFail("Expected duplicate command profiles")
        } catch {
            XCTAssertEqual(error as? RoundRobinSelectionError, .duplicateCommandProfiles("codex-a.json"))
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

private final class StubRoundRobinClaudeModelListing: ClaudeModelListing, @unchecked Sendable {
    private(set) var prefixes: [String] = []
    private let optionsByPrefix: [String: [ClaudeModelOption]]

    init(optionsByPrefix: [String: [ClaudeModelOption]]) {
        self.optionsByPrefix = optionsByPrefix
    }

    func claudeModelOptions(port _: Int, modelPrefix: String) async throws -> [ClaudeModelOption] {
        prefixes.append(modelPrefix)
        return optionsByPrefix[modelPrefix] ?? []
    }
}

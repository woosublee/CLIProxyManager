import XCTest
@testable import CLIProxyManagerCore

final class CodexFastModeTests: XCTestCase {
    func testManagedAliasRoundTripsCanonicalModel() {
        XCTAssertEqual(CodexFastMode.alias(for: "gpt-5.6-sol"), "gpt-5.6-sol-fast")
        XCTAssertTrue(CodexFastMode.isManagedAlias("gpt-5.6-sol-fast"))
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-fast"), "gpt-5.6-sol")
        XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-fast(xhigh)"), "gpt-5.6-sol")
    }

    func testModelIdentifierCoversEveryReasoningLevelWithFastModeOnAndOff() {
        let cases: [(reasoning: AppConfig.CodexReasoning, suffix: String)] = [
            (.auto, ""),
            (.low, "(low)"),
            (.medium, "(medium)"),
            (.high, "(high)"),
            (.xhigh, "(xhigh)"),
            (.max, "(max)")
        ]

        for testCase in cases {
            XCTAssertEqual(
                CodexFastMode.modelIdentifier(
                    model: "gpt-5.6-sol",
                    reasoning: testCase.reasoning,
                    fastModeEnabled: true
                ),
                "gpt-5.6-sol-fast\(testCase.suffix)",
                "Fast mode should preserve \(testCase.reasoning.rawValue) reasoning"
            )
            XCTAssertEqual(
                CodexFastMode.modelIdentifier(
                    model: "gpt-5.6-sol",
                    reasoning: testCase.reasoning,
                    fastModeEnabled: false
                ),
                "gpt-5.6-sol\(testCase.suffix)",
                "Regular mode should preserve \(testCase.reasoning.rawValue) reasoning"
            )
        }

        XCTAssertEqual(
            CodexFastMode.modelIdentifier(
                model: "upstream-fast",
                reasoning: .medium,
                fastModeEnabled: false
            ),
            "upstream-fast(medium)"
        )
    }

    func testFastConfigurationSeparatesOAuthAndAPIKeyModelsAndSortsThem() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "codex-work",
                provider: .codex,
                authProfileID: "codex-work.json",
                commandName: "ccwork",
                codex: codex(
                    opus: "gpt-5.6-sol",
                    sonnet: "gpt-5.5",
                    haiku: "gpt-5.5",
                    fastOpus: true,
                    fastSonnet: true
                ),
                modelPrefix: "codex-work"
            )
        ]
        config.roundRobinProfiles = [
            .init(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodex",
                includedAuthProfileIDs: ["codex-work.json", "codex-personal.json"],
                codex: codex(
                    opus: "gpt-5.4",
                    sonnet: "gpt-5.5",
                    haiku: "gpt-5.5",
                    fastOpus: true
                )
            )
        ]
        config.codexAPI.codex = codex(
            opus: "gpt-5.6-terra",
            sonnet: "gpt-5.6-sol",
            haiku: "gpt-5.5",
            fastOpus: true
        )

        let snapshot = try CodexFastConfiguration(config: config)

        XCTAssertEqual(snapshot.oauthCanonicalModels, ["gpt-5.4", "gpt-5.5", "gpt-5.6-sol"])
        XCTAssertEqual(snapshot.apiKeyCanonicalModels, ["gpt-5.6-terra"])
        XCTAssertEqual(snapshot.allAliases, [
            "gpt-5.4-fast",
            "gpt-5.5-fast",
            "gpt-5.6-sol-fast",
            "gpt-5.6-terra-fast"
        ])
    }

    func testAPIKeyFastModelsRemainScopedByProfileID() throws {
        let firstID = "codex-api-11111111-1111-1111-1111-111111111111"
        let secondID = "codex-api-22222222-2222-2222-2222-222222222222"
        var config = AppConfig.default
        config.apiKeyProfiles = [
            .init(
                id: firstID,
                provider: .codex,
                secretReference: SecretReference.apiKeyProfile(firstID)!,
                codex: codex(opus: "gpt-5.6-sol", sonnet: "gpt-5.5", haiku: "gpt-5.5", fastOpus: true)
            ),
            .init(
                id: secondID,
                provider: .codex,
                secretReference: SecretReference.apiKeyProfile(secondID)!,
                codex: codex(opus: "gpt-5.6-terra", sonnet: "gpt-5.5", haiku: "gpt-5.5", fastOpus: true)
            )
        ]

        let snapshot = try CodexFastConfiguration(
            config: config,
            includedAPIKeyProfileIDs: [firstID, secondID]
        )

        XCTAssertEqual(snapshot.apiKeyCanonicalModelsByProfileID[firstID], ["gpt-5.6-sol"])
        XCTAssertEqual(snapshot.apiKeyCanonicalModelsByProfileID[secondID], ["gpt-5.6-terra"])
        XCTAssertEqual(snapshot.apiKeyCanonicalModels, ["gpt-5.6-sol", "gpt-5.6-terra"])
    }

    func testAPIKeyModelsCanBeExcludedWhenNoAPIKeyIsConfigured() throws {
        var config = AppConfig.default
        config.codexAPI.codex.opus.fastModeEnabled = true

        XCTAssertEqual(
            try CodexFastConfiguration(config: config, includeAPIKeyModels: false).apiKeyCanonicalModels,
            []
        )
    }

    func testEnabledOAuthProfileWithoutCodexRoutingContributesNoCanonicalModels() throws {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "codex.json", commandName: "ccwork", modelPrefix: "codex-work")
        ]

        XCTAssertEqual(try CodexFastConfiguration(config: config).oauthCanonicalModels, [])
    }

    func testFastConfigurationRejectsManagedAliasCollision() {
        var config = AppConfig.default
        config.codexAPI.codex.opus = .init(
            model: "gpt-5.6-sol-fast",
            reasoning: .xhigh,
            fastModeEnabled: true
        )

        XCTAssertThrowsError(try CodexFastConfiguration(config: config)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-fast"))
        }
    }

    func testFastConfigurationRejectsManagedAliasWhenFastModeIsDisabled() {
        var config = AppConfig.default
        config.codexAPI.codex.opus = .init(
            model: "upstream-fast",
            reasoning: .medium,
            fastModeEnabled: false
        )

        XCTAssertThrowsError(try CodexFastConfiguration(config: config)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("upstream-fast"))
        }
    }

    func testFastConfigurationRejectsManagedAliasInDisabledProfile() {
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(
                id: "disabled-codex",
                provider: .codex,
                authProfileID: "disabled.json",
                commandName: "ccdisabled",
                codex: codex(
                    opus: "upstream-fast",
                    sonnet: "gpt-5.5",
                    haiku: "gpt-5.5"
                ),
                modelPrefix: "disabled-codex",
                isEnabled: false
            )
        ]

        XCTAssertThrowsError(try CodexFastConfiguration(config: config)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("upstream-fast"))
        }
    }

    private func codex(
        opus: String,
        sonnet: String,
        haiku: String,
        fastOpus: Bool = false,
        fastSonnet: Bool = false,
        fastHaiku: Bool = false
    ) -> AppConfig.Codex {
        .init(
            opus: .init(model: opus, reasoning: .xhigh, fastModeEnabled: fastOpus),
            sonnet: .init(model: sonnet, reasoning: .medium, fastModeEnabled: fastSonnet),
            haiku: .init(model: haiku, reasoning: .low, fastModeEnabled: fastHaiku)
        )
    }
}

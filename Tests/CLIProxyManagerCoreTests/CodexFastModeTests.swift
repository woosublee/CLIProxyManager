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
            "gpt-5.4-cpm-fast",
            "gpt-5.5-cpm-fast",
            "gpt-5.6-sol-cpm-fast",
            "gpt-5.6-terra-cpm-fast"
        ])
    }

    func testAPIKeyModelsCanBeExcludedWhenNoAPIKeyIsConfigured() throws {
        var config = AppConfig.default
        config.codexAPI.codex.opus.fastModeEnabled = true

        XCTAssertEqual(
            try CodexFastConfiguration(config: config, includeAPIKeyModels: false).apiKeyCanonicalModels,
            []
        )
    }

    func testEnabledOAuthProfileWithoutCodexRoutingFallsBackToLegacyCodexModels() throws {
        var config = AppConfig.default
        config.ccodex.opus.fastModeEnabled = true
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "codex.json", commandName: "ccwork", modelPrefix: "codex-work")
        ]

        XCTAssertEqual(try CodexFastConfiguration(config: config).oauthCanonicalModels, ["gpt-5.6-terra"])
    }

    func testFastConfigurationRejectsManagedAliasCollision() {
        var config = AppConfig.default
        config.ccodex.opus = .init(
            model: "gpt-5.6-sol-cpm-fast",
            reasoning: .xhigh,
            contextWindow: .auto,
            fastModeEnabled: true
        )

        XCTAssertThrowsError(try CodexFastConfiguration(config: config)) { error in
            XCTAssertEqual(error as? CodexFastConfigurationError, .managedAliasCollision("gpt-5.6-sol-cpm-fast"))
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
            opus: .init(model: opus, reasoning: .xhigh, contextWindow: .auto, fastModeEnabled: fastOpus),
            sonnet: .init(model: sonnet, reasoning: .medium, contextWindow: .auto, fastModeEnabled: fastSonnet),
            haiku: .init(model: haiku, reasoning: .low, contextWindow: .auto, fastModeEnabled: fastHaiku)
        )
    }
}

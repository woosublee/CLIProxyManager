import XCTest
@testable import CLIProxyManagerCore

final class ClaudeModelResolverTests: XCTestCase {
    func testAutomaticPrefersCreatedThenVersionThenDescendingID() throws {
        let options = [
            ClaudeModelOption(id: "claude-opus-4-7", created: 500),
            ClaudeModelOption(id: "claude-opus-4-8", created: 500),
            ClaudeModelOption(id: "claude-sonnet-4-6", created: nil),
            ClaudeModelOption(id: "claude-sonnet-5", created: nil),
            ClaudeModelOption(id: "claude-haiku-4-5-20251001", created: 300),
            ClaudeModelOption(id: "claude-haiku-4-5", created: 300)
        ]

        let resolved = try ClaudeModelResolver.resolve(
            routing: .automatic,
            options: options,
            prefix: "claude-work"
        )

        XCTAssertEqual(resolved.opus, "claude-work/claude-opus-4-8")
        XCTAssertEqual(resolved.sonnet, "claude-work/claude-sonnet-5")
        XCTAssertEqual(resolved.haiku, "claude-work/claude-haiku-4-5-20251001")
    }

    func testExplicitSelectionValidatesAvailabilityAndFamily() throws {
        let options = [
            ClaudeModelOption(id: "claude-opus-4-8", created: 500),
            ClaudeModelOption(id: "claude-sonnet-5", created: 400),
            ClaudeModelOption(id: "claude-haiku-4-5", created: 300)
        ]
        let routing = ClaudeRouting(
            opus: .model("claude-opus-4-8"),
            sonnet: .model("claude-sonnet-5"),
            haiku: .model("claude-haiku-4-5")
        )

        XCTAssertEqual(
            try ClaudeModelResolver.resolve(routing: routing, options: options, prefix: "claude-work"),
            ResolvedClaudeModels(
                opus: "claude-work/claude-opus-4-8",
                sonnet: "claude-work/claude-sonnet-5",
                haiku: "claude-work/claude-haiku-4-5"
            )
        )

        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .model("claude-sonnet-5"),
                role: .opus,
                options: options
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeModelResolutionError,
                .selectedModelHasWrongFamily(role: .opus, model: "claude-sonnet-5", actualFamily: .sonnet)
            )
        }
    }

    func testUnavailableExplicitSelectionDoesNotFallBackToAutomatic() {
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .model("claude-opus-4-7"),
                role: .opus,
                options: [ClaudeModelOption(id: "claude-opus-4-8")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeModelResolutionError,
                .selectedModelUnavailable(role: .opus, model: "claude-opus-4-7")
            )
        }
    }

    func testAutomaticCompatibilityFallbackIsScopedAndFamilySpecific() throws {
        let fallback = ClaudeModelOption(
            id: OAuthModelDefaults.claudeOpusModel,
            family: .other,
            created: nil
        )

        XCTAssertEqual(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .automatic,
                role: .opus,
                options: [fallback]
            ),
            OAuthModelDefaults.claudeOpusModel
        )
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolveBaseModel(
                selection: .automatic,
                role: .sonnet,
                options: [fallback]
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeModelResolutionError, .noModelForFamily(.sonnet))
        }
    }

    func testEmptyScopedRegistryProducesPrefixSpecificError() {
        XCTAssertThrowsError(
            try ClaudeModelResolver.resolve(routing: .automatic, options: [], prefix: "claude-work")
        ) { error in
            XCTAssertEqual(error as? ClaudeModelResolutionError, .noModelsAvailable(prefix: "claude-work"))
        }
    }

    func testShellAssignmentsSingleQuoteValues() throws {
        let resolved = ResolvedClaudeModels(
            opus: "claude-work/claude-opus-4-8",
            sonnet: "claude-work/claude-sonnet-5",
            haiku: "claude-work/claude-haiku-4-5"
        )

        XCTAssertEqual(resolved.shellEnvironmentAssignments, """
        ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-8'
        ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-5'
        ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5'
        """)
    }
}

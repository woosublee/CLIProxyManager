import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDefaultConfigMatchesMVPDecisions() {
        let config = AppConfig.default

        #if DEBUG
        XCTAssertEqual(config.port, 18_318)
        #else
        XCTAssertEqual(config.port, 18_317)
        #endif
        XCTAssertEqual(config.commands.cc, "")
        XCTAssertEqual(config.commands.ccapi, "")
        XCTAssertEqual(config.commands.ccodex, "")
        XCTAssertEqual(config.commands.ccodexapi, "")
        XCTAssertEqual(config.ccapi.connectionMode, .proxy)
        XCTAssertEqual(config.ccapi.claude, .automatic)
        XCTAssertEqual(config.ccapi.nickname, "")
        XCTAssertFalse(config.ccapi.dangerousPermissionsEnabled)
        XCTAssertEqual(config.codexAPI.codex, config.ccodex)
        XCTAssertEqual(config.codexAPI.nickname, "")
        XCTAssertFalse(config.codexAPI.dangerousPermissionsEnabled)
        XCTAssertEqual(config.ccodex.opus, AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh))
        XCTAssertEqual(config.ccodex.sonnet, AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .medium))
        XCTAssertEqual(config.ccodex.haiku, AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .low))
        XCTAssertFalse(config.includeDangerouslySkipPermissions)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertTrue(config.showDockIcon)
        XCTAssertTrue(config.showMenuBarIcon)
        XCTAssertFalse(config.showNotifications)
        XCTAssertFalse(config.usageOverlay.isVisible)
        XCTAssertFalse(config.usageOverlay.alwaysOnTop)
        XCTAssertEqual(config.usageOverlay.backgroundOpacity, 0.9)
        XCTAssertEqual(config.usageOverlay.displayMode, .expanded)
        XCTAssertFalse(config.roundRobinEnabled)
        XCTAssertEqual(config.roundRobinProfiles, [])
        XCTAssertEqual(config.accountOrder, [])
    }

    func testDefaultConfigHasNoStoredAccountOrder() {
        XCTAssertEqual(AppConfig.default.accountOrder, [])
    }

    func testDecodedConfigDefaultsMissingAccountOrderToEmpty() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "", "ccapi": "", "ccodex": "" },
          "ccapi": {},
          "ccodex": {
            "opus": { "model": "gpt-5.6-terra", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.6-terra", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.6-terra", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.accountOrder, [])
    }

    func testAccountOrderRoundTripsThroughCodable() throws {
        var config = AppConfig.default
        config.accountOrder = ["codex-api", "claude-work", "claude-api"]

        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(decoded.accountOrder, ["codex-api", "claude-work", "claude-api"])
    }

    func testDefaultCodexRoutingUsesTerraWithRoleSpecificReasoning() {
        XCTAssertEqual(
            AppConfig.default.ccodex.opus,
            AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .xhigh)
        )
        XCTAssertEqual(
            AppConfig.default.ccodex.sonnet,
            AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .medium)
        )
        XCTAssertEqual(
            AppConfig.default.ccodex.haiku,
            AppConfig.CodexRole(model: "gpt-5.6-terra", reasoning: .low)
        )
    }

    func testCodexReasoningMaxRendersAndRoundTrips() throws {
        let role = AppConfig.CodexRole(model: "gpt-5.6-sol", reasoning: .max)

        XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol(max)")

        let encoded = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(AppConfig.CodexRole.self, from: encoded)
        XCTAssertEqual(decoded, role)
    }

    func testCodexRoleDefaultsMissingFastModeToFalse() throws {
        let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"}"#.utf8)

        let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

        XCTAssertFalse(role.fastModeEnabled)
    }

    func testCodexRoleFastModeRoundTripsAndRendersManagedAlias() throws {
        let role = AppConfig.CodexRole(
            model: "gpt-5.6-sol",
            reasoning: .max,
            fastModeEnabled: true
        )

        XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol-fast(max)")
        XCTAssertEqual(
            try JSONDecoder().decode(AppConfig.CodexRole.self, from: JSONEncoder().encode(role)),
            role
        )
    }

    func testCodexRoleModelIdentifierAppendsOneMillionSuffixForExtendedContext() {
        let role = AppConfig.CodexRole(
            model: "gpt-5.6-sol",
            reasoning: .xhigh,
            detectedContextWindow: 372_000,
            fastModeEnabled: true
        )

        XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol-fast(xhigh)[1m]")
    }

    func testCodexRoleModelIdentifierOmitsSuffixAtOrBelowStandardContext() {
        let atStandard = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: 200_000)
        let unknown = AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, detectedContextWindow: nil)

        XCTAssertEqual(atStandard.modelIdentifier, "gpt-5.5(medium)")
        XCTAssertEqual(unknown.modelIdentifier, "gpt-5.5(medium)")
    }

    func testCodexRoleDetectedContextWindowRoundTrips() throws {
        let role = AppConfig.CodexRole(
            model: "gpt-5.6-sol",
            reasoning: .xhigh,
            detectedContextWindow: 372_000,
            fastModeEnabled: false
        )

        let encoded = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(AppConfig.CodexRole.self, from: encoded)

        XCTAssertEqual(decoded.detectedContextWindow, 372_000)
    }

    func testCodexRoleDefaultsDetectedContextWindowToNilWhenMissing() throws {
        let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh"}"#.utf8)

        let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

        XCTAssertNil(role.detectedContextWindow)
    }

    func testCodexRoleIgnoresLegacyContextWindowStringKey() throws {
        let data = Data(#"{"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"}"#.utf8)

        let role = try JSONDecoder().decode(AppConfig.CodexRole.self, from: data)

        XCTAssertNil(role.detectedContextWindow)
    }

    func testUsageOverlayInitializerClampsBackgroundOpacity() {
        XCTAssertEqual(
            AppConfig.UsageOverlay(backgroundOpacity: 0.1).backgroundOpacity,
            0.2
        )
        XCTAssertEqual(
            AppConfig.UsageOverlay(backgroundOpacity: 1.1).backgroundOpacity,
            1
        )
    }

    func testUsageOverlayDefaultsToExpandedDisplayMode() {
        XCTAssertEqual(AppConfig.UsageOverlay().displayMode, .expanded)
        XCTAssertEqual(AppConfig.default.usageOverlay.displayMode, .expanded)
    }

    func testUsageOverlayDefaultsHiddenAccountIDsToEmpty() {
        XCTAssertEqual(AppConfig.UsageOverlay().hiddenAccountIDs, [])
        XCTAssertEqual(AppConfig.default.usageOverlay.hiddenAccountIDs, [])
    }

    func testUsageOverlayMissingHiddenAccountIDsDecodesAsEmpty() throws {
        let data = Data(#"{"isVisible":true,"alwaysOnTop":false,"backgroundOpacity":0.7,"displayMode":"compact"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

        XCTAssertEqual(decoded.hiddenAccountIDs, [])
        XCTAssertEqual(decoded.displayMode, .compact)
    }

    func testUsageOverlayDeduplicatesHiddenAccountIDsWhenDecoding() throws {
        let data = Data(#"{"hiddenAccountIDs":["claude","codex","claude","claude-api","codex"]}"#.utf8)

        let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

        XCTAssertEqual(decoded.hiddenAccountIDs, ["claude", "codex", "claude-api"])
    }

    func testUsageOverlayHiddenAccountIDsRoundTrip() throws {
        let overlay = AppConfig.UsageOverlay(
            isVisible: true,
            alwaysOnTop: true,
            backgroundOpacity: 0.45,
            displayMode: .compact,
            hiddenAccountIDs: ["codex-work", "claude-api"]
        )

        let decoded = try JSONDecoder().decode(
            AppConfig.UsageOverlay.self,
            from: JSONEncoder().encode(overlay)
        )

        XCTAssertEqual(decoded, overlay)
        XCTAssertEqual(decoded.hiddenAccountIDs, ["codex-work", "claude-api"])
    }

    func testUsageOverlayDisplayModeRoundTrips() throws {
        let overlay = AppConfig.UsageOverlay(
            isVisible: true,
            alwaysOnTop: true,
            backgroundOpacity: 0.45,
            displayMode: .compact
        )

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

        XCTAssertEqual(decoded, overlay)
        XCTAssertEqual(decoded.displayMode, .compact)
    }

    func testUsageOverlayMissingDisplayModeDecodesAsExpanded() throws {
        let data = Data(#"{"isVisible":true,"alwaysOnTop":false,"backgroundOpacity":0.7}"#.utf8)

        let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

        XCTAssertEqual(decoded.displayMode, .expanded)
        XCTAssertTrue(decoded.isVisible)
        XCTAssertEqual(decoded.backgroundOpacity, 0.7)
    }

    func testDecodedConfigPreservesSavedCommandNamesAndClaudeAPIModel() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "savedcc", "ccapi": "savedapi", "ccodex": "savedcodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.commands.cc, "savedcc")
        XCTAssertEqual(config.commands.ccapi, "savedapi")
        XCTAssertEqual(config.commands.ccodex, "savedcodex")
        XCTAssertEqual(config.commands.ccodexapi, "")
        XCTAssertEqual(config.ccapi.connectionMode, .proxy)
        XCTAssertEqual(config.ccapi.claude, .automatic)
        XCTAssertFalse(config.ccapi.dangerousPermissionsEnabled)
        XCTAssertEqual(config.codexAPI.codex, config.ccodex)
        XCTAssertFalse(config.codexAPI.dangerousPermissionsEnabled)
    }

    func testLegacyClaudeAPIFieldsDecodeWithoutPersistingModelOrConnectionMode() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "", "ccapi": "savedapi", "ccodex": "" },
          "ccapi": {
            "model": "claude-sonnet-4-6",
            "connectionMode": "direct",
            "dangerousPermissionsEnabled": true
          },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let encodedString = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)

        XCTAssertTrue(config.ccapi.dangerousPermissionsEnabled)
        XCTAssertFalse(encodedString.contains("claude-sonnet-4-6"))
        XCTAssertFalse(encodedString.contains("connectionMode"))
    }

    func testAPIKeyNicknamesRoundTripAndLegacyConfigsDefaultToEmpty() throws {
        var config = AppConfig.default
        config.ccapi = .init(nickname: "Anthropic Work", dangerousPermissionsEnabled: true)
        config.codexAPI = .init(
            codex: config.ccodex,
            nickname: "OpenAI Personal",
            dangerousPermissionsEnabled: true
        )

        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(roundTripped.ccapi.nickname, "Anthropic Work")
        XCTAssertEqual(roundTripped.codexAPI.nickname, "OpenAI Personal")

        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "", "ccapi": "", "ccodex": "" },
          "ccapi": {},
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8))
        XCTAssertEqual(legacy.ccapi.nickname, "")
        XCTAssertEqual(legacy.codexAPI.nickname, "")
    }

    func testMalformedWrappedCodexAPISettingsFailDecodingInsteadOfResettingToDefaults() {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "", "ccapi": "", "ccodex": "" },
          "ccapi": {},
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "codexAPI": {
            "nickname": "Work",
            "dangerousPermissionsEnabled": true,
            "codex": {
              "opus": { "model": "gpt-5.6", "reasoning": "future", "contextWindow": "auto" },
              "sonnet": { "model": "gpt-5.6", "reasoning": "medium", "contextWindow": "auto" },
              "haiku": { "model": "gpt-5.6", "reasoning": "low", "contextWindow": "auto" }
            }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: data))
    }

    func testOAuthCommandProfileDefaultsMissingConnectionModeToProxy() throws {
        let data = Data(#"""
        {
          "id": "claude-work",
          "provider": "claude",
          "authProfileID": "claude-work.json",
          "commandName": "ccwork"
        }
        """#.utf8)

        let profile = try JSONDecoder().decode(AppConfig.OAuthCommandProfile.self, from: data)

        XCTAssertEqual(profile.connectionMode, .proxy)
    }

    func testDefaultAccountPrivacyHidesProviderDetails() {
        let config = AppConfig.default

        XCTAssertTrue(config.accountPrivacy.claudeHidden)
        XCTAssertTrue(config.accountPrivacy.codexHidden)
    }

    func testDecodedConfigDefaultsMissingAccountPrivacyToHidden() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertTrue(config.accountPrivacy.claudeHidden)
        XCTAssertTrue(config.accountPrivacy.codexHidden)
    }

    func testDecodedConfigDefaultsMissingCodexPrivacyFieldToHidden() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "accountPrivacy": { "claudeHidden": false }
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertFalse(config.accountPrivacy.claudeHidden)
        XCTAssertTrue(config.accountPrivacy.codexHidden)
    }

    func testDecodedConfigDefaultsMissingClaudePrivacyFieldToHidden() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "accountPrivacy": { "codexHidden": false }
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertTrue(config.accountPrivacy.claudeHidden)
        XCTAssertFalse(config.accountPrivacy.codexHidden)
    }

    func testDecodedConfigPreservesAccountPrivacy() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "accountPrivacy": { "claudeHidden": false, "codexHidden": true }
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertFalse(config.accountPrivacy.claudeHidden)
        XCTAssertTrue(config.accountPrivacy.codexHidden)
    }

    func testDecodedConfigCannotEnableUnavailableFeatures() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "customapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "showNotifications": true,
          "roundRobinEnabled": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertFalse(config.showNotifications)
        XCTAssertFalse(config.roundRobinEnabled)
        XCTAssertEqual(config.roundRobinProfiles, [])
    }

    func testRoundRobinProfilesDecodeAndEncodeRoundTrip() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-8" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "roundRobinProfiles": [
            {
              "id": "codex-default",
              "provider": "codex",
              "isEnabled": true,
              "commandName": "ccodexrr",
              "nickname": "Codex Pool",
              "includedAuthProfileIDs": ["codex-fast.json", "codex-deep.json"],
              "accountDetailHidden": false,
              "dangerousPermissionsEnabled": true,
              "codex": {
                "opus": { "model": "gpt-5.6", "reasoning": "xhigh", "contextWindow": "1m" },
                "sonnet": { "model": "gpt-5.6", "reasoning": "medium", "contextWindow": "400k" },
                "haiku": { "model": "gpt-5.6-mini", "reasoning": "low", "contextWindow": "200k" }
              }
            }
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: encoded)

        XCTAssertEqual(roundTripped.roundRobinProfiles, decoded.roundRobinProfiles)
        XCTAssertEqual(roundTripped.roundRobinProfiles, [
            AppConfig.RoundRobinProfile(
                id: "codex-default",
                provider: .codex,
                isEnabled: true,
                commandName: "ccodexrr",
                nickname: "Codex Pool",
                includedAuthProfileIDs: ["codex-fast.json", "codex-deep.json"],
                accountDetailHidden: false,
                dangerousPermissionsEnabled: true,
                codex: AppConfig.Codex(
                    opus: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .xhigh),
                    sonnet: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .medium),
                    haiku: AppConfig.CodexRole(model: "gpt-5.6-mini", reasoning: .low)
                )
            )
        ])
    }

    func testMissingRoundRobinProfilesDecodesToEmptyArray() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-8" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.roundRobinProfiles, [])
    }

    func testRoundRobinProfileDefaultsWhenOptionalFieldsAreMissing() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-8" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "roundRobinProfiles": [
            {
              "id": "claude-default",
              "provider": "claude",
              "isEnabled": true,
              "commandName": "ccrr",
              "includedAuthProfileIDs": ["claude-work.json", "claude-personal.json"]
            }
          ]
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.roundRobinProfiles.first?.nickname, "")
        XCTAssertEqual(config.roundRobinProfiles.first?.accountDetailHidden, true)
        XCTAssertEqual(config.roundRobinProfiles.first?.dangerousPermissionsEnabled, false)
        XCTAssertNil(config.roundRobinProfiles.first?.codex)
    }

    func testOAuthCommandProfilesDecodeAndEncodeRoundTrip() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-8" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "oauthCommandProfiles": [
            {
              "id": "claude-work",
              "provider": "claude",
              "authProfileID": "claude-work.json",
              "commandName": "ccwork",
              "nickname": "Work",
              "accountDetailHidden": false,
              "dangerousPermissionsEnabled": true,
              "modelPrefix": "team",
              "isEnabled": true
            },
            {
              "id": "codex-personal",
              "provider": "codex",
              "authProfileID": "codex-personal.json",
              "commandName": "ccpersonal",
              "nickname": "Personal",
              "accountDetailHidden": true,
              "dangerousPermissionsEnabled": false,
              "codex": {
                "opus": { "model": "gpt-5.6", "reasoning": "high", "contextWindow": "auto" },
                "sonnet": { "model": "gpt-5.6", "reasoning": "medium", "contextWindow": "400k" },
                "haiku": { "model": "gpt-5.6-mini", "reasoning": "low", "contextWindow": "200k" }
              },
              "modelPrefix": "codex-personal",
              "isEnabled": false
            }
          ]
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: encoded)

        XCTAssertEqual(roundTripped.oauthCommandProfiles, decoded.oauthCommandProfiles)
        XCTAssertEqual(roundTripped.oauthCommandProfiles.count, 2)
        XCTAssertEqual(roundTripped.oauthCommandProfiles[0], AppConfig.OAuthCommandProfile(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            nickname: "Work",
            accountDetailHidden: false,
            dangerousPermissionsEnabled: true,
            modelPrefix: "team",
            isEnabled: true
        ))
        XCTAssertNil(roundTripped.oauthCommandProfiles[1].codex?.sonnet.detectedContextWindow)
        XCTAssertNil(roundTripped.oauthCommandProfiles[1].codex?.haiku.detectedContextWindow)
    }

    func testMissingOAuthCommandProfilesDecodesToEmptyArray() throws {
        let data = Data(#"""
        {
          "port": 18317,
          "commands": { "cc": "cc", "ccapi": "ccapi", "ccodex": "ccodex" },
          "ccapi": { "model": "claude-opus-4-7" },
          "ccodex": {
            "opus": { "model": "gpt-5.5", "reasoning": "xhigh", "contextWindow": "auto" },
            "sonnet": { "model": "gpt-5.5", "reasoning": "medium", "contextWindow": "auto" },
            "haiku": { "model": "gpt-5.5", "reasoning": "low", "contextWindow": "auto" }
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.oauthCommandProfiles, [])
        XCTAssertEqual(config.commands.cc, "cc")
        XCTAssertEqual(config.commands.ccodex, "ccodex")
    }

    func testDefaultRootDirectoryUsesDevelopmentSubdirectoryInDebugBuilds() {
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cliproxy-manager", isDirectory: true)

        #if DEBUG
        XCTAssertEqual(
            ManagedPaths.defaultRootDirectory(),
            productionRoot.appendingPathComponent("dev", isDirectory: true)
        )
        #else
        XCTAssertEqual(ManagedPaths.defaultRootDirectory(), productionRoot)
        #endif
    }

    func testManagedPathsCanBeRootedInTemporaryDirectory() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)

        XCTAssertEqual(paths.rootDirectory, root)
        XCTAssertEqual(paths.functionsFile, root.appendingPathComponent("functions.zsh"))
        XCTAssertEqual(paths.configFile, root.appendingPathComponent("config.json"))
        XCTAssertEqual(
            paths.subscriptionUsageManagementKeyFile,
            root.appendingPathComponent("subscription-usage-management-key.json")
        )
        XCTAssertEqual(
            paths.subscriptionUsageSnapshotCacheFile,
            root.appendingPathComponent("subscription-usage-snapshots.json")
        )
        XCTAssertEqual(paths.logsDirectory, root.appendingPathComponent("logs"))
        XCTAssertEqual(paths.clipProxyDirectory, root.appendingPathComponent("cliproxyapi"))
        XCTAssertEqual(
            paths.clipProxyConfigFile,
            root.appendingPathComponent("cliproxyapi").appendingPathComponent("config.yaml")
        )
        XCTAssertEqual(
            paths.clipProxyBinary,
            root.appendingPathComponent("cliproxyapi").appendingPathComponent("cliproxyapi")
        )
    }

    func testManagedPathsUseAuthLogsForProxyRuntimeLogs() {
        let root = URL(fileURLWithPath: "/tmp/managed", isDirectory: true)
        let paths = ManagedPaths(rootDirectory: root)
        XCTAssertEqual(paths.proxyLogsDirectory, root.appendingPathComponent("auth/logs", isDirectory: true))
    }

    func testManagedPathsExposeUserPrivateAPIKeyFiles() {
        let root = URL(fileURLWithPath: "/tmp/managed", isDirectory: true)
        let paths = ManagedPaths(rootDirectory: root)

        XCTAssertEqual(paths.apiKeysDirectory, root.appendingPathComponent("api-keys", isDirectory: true))
        XCTAssertEqual(paths.apiKeyFile(for: .claudeAPIKey), root.appendingPathComponent("api-keys/claude-api-key.json"))
        XCTAssertEqual(paths.apiKeyFile(for: .codexAPIKey), root.appendingPathComponent("api-keys/codex-api-key.json"))
    }

    func testClaudeModelSelectionUsesStringRepresentationAndNormalizesBlankValues() throws {
        let automatic = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""automatic""#.utf8))
        let blank = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""   ""#.utf8))
        let explicit = try JSONDecoder().decode(ClaudeModelSelection.self, from: Data(#""claude-opus-4-8""#.utf8))

        XCTAssertEqual(automatic, .automatic)
        XCTAssertEqual(blank, .automatic)
        XCTAssertEqual(explicit, .model("claude-opus-4-8"))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(automatic), as: UTF8.self), #""automatic""#)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(explicit), as: UTF8.self), #""claude-opus-4-8""#)
    }

    func testLegacyClaudeOAuthProfileUsesAutomaticEffectiveRoutingWithoutForcingStoredField() throws {
        let data = Data(#"""
        {
          "id": "claude-work",
          "provider": "claude",
          "authProfileID": "claude-work.json",
          "commandName": "ccwork",
          "connectionMode": "proxy"
        }
        """#.utf8)

        let profile = try JSONDecoder().decode(AppConfig.OAuthCommandProfile.self, from: data)

        XCTAssertNil(profile.claude)
        XCTAssertEqual(profile.effectiveClaudeRouting, .automatic)
    }

    func testClaudeRoutingRoundTripsAndSurvivesDirectMode() throws {
        let routing = ClaudeRouting(
            opus: .model("claude-opus-4-8"),
            sonnet: .automatic,
            haiku: .model("claude-haiku-4-5")
        )
        let profile = AppConfig.OAuthCommandProfile(
            id: "claude-work",
            provider: .claude,
            authProfileID: "claude-work.json",
            commandName: "ccwork",
            claude: routing,
            modelPrefix: "claude-work",
            connectionMode: .direct
        )

        let decoded = try JSONDecoder().decode(
            AppConfig.OAuthCommandProfile.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded.claude, routing)
        XCTAssertEqual(decoded.effectiveClaudeRouting, routing)
        XCTAssertEqual(decoded.connectionMode, .direct)
    }

    func testLegacySubscriptionUsageEnabledMigratesToMenuBarVisibility() throws {
        let enabled = try decodeConfig(subscriptionUsageJSON: #"{"isEnabled":true}"#, usageOverlayJSON: #"{"isVisible":false}"#)
        let disabled = try decodeConfig(subscriptionUsageJSON: #"{"isEnabled":false}"#, usageOverlayJSON: #"{"isVisible":false}"#)

        XCTAssertTrue(enabled.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(disabled.subscriptionUsage.showInMenuBar)
    }

    func testNewMenuBarVisibilityTakesPrecedenceOverLegacyEnabledField() throws {
        let config = try decodeConfig(
            subscriptionUsageJSON: #"{"showInMenuBar":false,"isEnabled":true}"#,
            usageOverlayJSON: #"{"isVisible":false}"#
        )

        XCTAssertFalse(config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(config.isSubscriptionUsageEnabled)
    }

    func testSubscriptionUsageEnabledIsComputedFromEitherDisplayPreference() {
        var config = AppConfig.default
        XCTAssertFalse(config.isSubscriptionUsageEnabled)

        config.subscriptionUsage.showInMenuBar = true
        XCTAssertTrue(config.isSubscriptionUsageEnabled)

        config.subscriptionUsage.showInMenuBar = false
        config.usageOverlay.isVisible = true
        XCTAssertTrue(config.isSubscriptionUsageEnabled)

        config.subscriptionUsage.showInMenuBar = true
        config.usageOverlay.isVisible = true
        XCTAssertTrue(config.isSubscriptionUsageEnabled)
    }

    func testSubscriptionUsageEncodesOnlyNewMenuBarVisibilityField() throws {
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        let usage = try XCTUnwrap(object["subscriptionUsage"] as? [String: Any])

        XCTAssertEqual(usage["showInMenuBar"] as? Bool, true)
        XCTAssertNil(usage["isEnabled"])
    }

    private func decodeConfig(subscriptionUsageJSON: String, usageOverlayJSON: String) throws -> AppConfig {
        let json = """
        {
          "port": 18317,
          "commands": {"cc":"","ccapi":"","ccodex":""},
          "ccapi": {"model":"claude-opus-4-8"},
          "ccodex": {
            "opus": {"model":"gpt-5.5","reasoning":"xhigh","contextWindow":"auto"},
            "sonnet": {"model":"gpt-5.5","reasoning":"medium","contextWindow":"auto"},
            "haiku": {"model":"gpt-5.5","reasoning":"low","contextWindow":"auto"}
          },
          "includeDangerouslySkipPermissions": false,
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true,
          "subscriptionUsage": \(subscriptionUsageJSON),
          "usageOverlay": \(usageOverlayJSON)
        }
        """
        return try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
}

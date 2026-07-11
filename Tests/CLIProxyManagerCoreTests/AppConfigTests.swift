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
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-8")
        XCTAssertEqual(config.ccodex.opus, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto))
        XCTAssertEqual(config.ccodex.sonnet, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto))
        XCTAssertEqual(config.ccodex.haiku, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto))
        XCTAssertFalse(config.includeDangerouslySkipPermissions)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertTrue(config.showDockIcon)
        XCTAssertTrue(config.showMenuBarIcon)
        XCTAssertFalse(config.showNotifications)
        XCTAssertFalse(config.usageOverlay.isVisible)
        XCTAssertFalse(config.usageOverlay.alwaysOnTop)
        XCTAssertEqual(config.usageOverlay.backgroundOpacity, 0.9)
        XCTAssertFalse(config.roundRobinEnabled)
        XCTAssertEqual(config.roundRobinProfiles, [])
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
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
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
                    opus: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .xhigh, contextWindow: .context1m),
                    sonnet: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
                    haiku: AppConfig.CodexRole(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
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
        XCTAssertEqual(roundTripped.oauthCommandProfiles[1].codex?.sonnet.contextWindow, .context400k)
        XCTAssertEqual(roundTripped.oauthCommandProfiles[1].codex?.haiku.contextWindow, .context200k)
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
}

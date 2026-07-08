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
        XCTAssertFalse(config.roundRobinEnabled)
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
}

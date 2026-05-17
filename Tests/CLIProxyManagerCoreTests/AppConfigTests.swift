import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDefaultConfigMatchesMVPDecisions() {
        let config = AppConfig.default

        XCTAssertEqual(config.port, 18_317)
        XCTAssertEqual(config.commands.cc, "cc")
        XCTAssertEqual(config.commands.ccapi, "ccapi")
        XCTAssertEqual(config.commands.ccodex, "ccodex")
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
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

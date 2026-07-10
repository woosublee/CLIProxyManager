import XCTest
@testable import CLIProxyManagerCore

final class AppConfigStoreTests: XCTestCase {
    func testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured() {
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
        XCTAssertEqual(config.roundRobinProfiles, [])
        XCTAssertFalse(config.subscriptionUsage.isEnabled)
    }

    func testStoreReturnsDefaultWhenConfigFileDoesNotExist() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))

        let config = try store.load()

        XCTAssertEqual(config, .default)
    }

    func testLegacyConfigWithoutSubscriptionUsageDefaultsToDisabled() throws {
        let legacyJSON = #"""
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
          "showMenuBarIcon": true
        }
        """#

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacyJSON.utf8))

        XCTAssertFalse(config.subscriptionUsage.isEnabled)
    }

    func testStoreSavesAndLoadsConfig() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        var config = AppConfig(
            port: 18_888,
            commands: AppConfig.Commands(cc: "mine", ccapi: "mineapi", ccodex: "minecodex"),
            ccapi: AppConfig.ClaudeAPI(model: "claude-sonnet-4-6"),
            ccodex: AppConfig.Codex(
                opus: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .context1m),
                sonnet: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .context400k),
                haiku: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .context200k)
            ),
            includeDangerouslySkipPermissions: true,
            startAtLogin: true,
            showDockIcon: false,
            showMenuBarIcon: true
        )
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "claude-work",
                provider: .claude,
                authProfileID: "claude-work.json",
                commandName: "ccwork",
                nickname: "Work",
                accountDetailHidden: false,
                dangerousPermissionsEnabled: true,
                modelPrefix: "team",
                isEnabled: true
            ),
            AppConfig.OAuthCommandProfile(
                id: "codex-personal",
                provider: .codex,
                authProfileID: "codex-personal.json",
                commandName: "ccpersonal",
                nickname: "Personal",
                accountDetailHidden: true,
                dangerousPermissionsEnabled: false,
                codex: AppConfig.Codex(
                    opus: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .high, contextWindow: .auto),
                    sonnet: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .medium, contextWindow: .context400k),
                    haiku: AppConfig.CodexRole(model: "gpt-5.6-mini", reasoning: .low, contextWindow: .context200k)
                ),
                modelPrefix: "codex-personal",
                isEnabled: false
            )
        ]

        try store.save(config)

        XCTAssertEqual(try store.load(), config)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }
}

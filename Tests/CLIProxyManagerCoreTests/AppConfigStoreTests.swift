import XCTest
@testable import CLIProxyManagerCore

final class AppConfigStoreTests: XCTestCase {
    func testDefaultConfigUsesAppManagedPortAndLeavesOAuthCommandNamesUnconfigured() {
        let config = AppConfig.default

        #if DEBUG
        XCTAssertEqual(config.port, AppConfig.developmentDefaultPort)
        #else
        XCTAssertEqual(config.port, AppConfig.releaseDefaultPort)
        #endif
        XCTAssertEqual(config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(config.claudeAPI.commandName, "")
        XCTAssertEqual(config.claudeAPI.connectionMode, .proxy)
        XCTAssertFalse(config.claudeAPI.dangerousPermissionsEnabled)
        XCTAssertEqual(config.codexAPI.commandName, "")
        XCTAssertEqual(config.codexAPI.codex, .default)
        XCTAssertEqual(config.codexAPI.nickname, "")
        XCTAssertFalse(config.codexAPI.dangerousPermissionsEnabled)
        XCTAssertEqual(config.oauthCommandProfiles, [])
        XCTAssertEqual(config.roundRobinProfiles, [])
        XCTAssertFalse(config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(config.isSubscriptionUsageEnabled)
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
          "port": 28317,
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

        XCTAssertFalse(config.subscriptionUsage.showInMenuBar)
        XCTAssertFalse(config.isSubscriptionUsageEnabled)
    }

    func testStoreSavesAndLoadsConfig() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        var config = AppConfig(
            port: 18_888,
            claudeAPI: AppConfig.ClaudeAPI(
                commandName: "claude-api-work",
                dangerousPermissionsEnabled: true
            ),
            codexAPI: AppConfig.CodexAPI(
                commandName: "codex-api-work",
                codex: AppConfig.Codex(
                    opus: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh),
                    sonnet: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium),
                    haiku: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low)
                )
            ),
            startAtLogin: true,
            showDockIcon: false,
            showMenuBarIcon: true
        )
        config.subscriptionUsage.showInMenuBar = true
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
                    opus: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .high),
                    sonnet: AppConfig.CodexRole(model: "gpt-5.6", reasoning: .medium),
                    haiku: AppConfig.CodexRole(model: "gpt-5.6-mini", reasoning: .low)
                ),
                modelPrefix: "codex-personal",
                isEnabled: false
            )
        ]
        config.accountOrder = ["codex-personal", "claude-api", "claude-work"]

        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(loaded.port, config.port)
        XCTAssertEqual(loaded.claudeAPI, config.claudeAPI)
        XCTAssertEqual(loaded.codexAPI, config.codexAPI)
        XCTAssertEqual(loaded.oauthCommandProfiles, config.oauthCommandProfiles)
        XCTAssertEqual(loaded.accountOrder, config.accountOrder)
        XCTAssertTrue(loaded.subscriptionUsage.showInMenuBar)
        XCTAssertTrue(loaded.isSubscriptionUsageEnabled)
    }

    func testLegacyDocumentLoadsCanonicalProviderSettingsAndOAuthDefaults() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        let legacyJSON = #"""
        {
          "port": 28317,
          "commands": {
            "cc": "claude-work",
            "ccapi": "claude-api-work",
            "ccodex": "codex-work",
            "ccodexapi": "codex-api-work"
          },
          "ccapi": {
            "nickname": "Claude API",
            "dangerousPermissionsEnabled": true,
            "claude": {"opus":"automatic","sonnet":"automatic","haiku":"automatic"}
          },
          "ccodex": {
            "opus":{"model":"gpt-5.6-terra","reasoning":"xhigh"},
            "sonnet":{"model":"gpt-5.6-terra","reasoning":"medium"},
            "haiku":{"model":"gpt-5.6-terra","reasoning":"low"}
          },
          "codexAPI": {
            "nickname": "Codex API",
            "codex": {
              "opus":{"model":"gpt-5.6-terra","reasoning":"xhigh"},
              "sonnet":{"model":"gpt-5.6-terra","reasoning":"medium"},
              "haiku":{"model":"gpt-5.6-terra","reasoning":"low"}
            }
          },
          "includeDangerouslySkipPermissions": true,
          "nicknames": {"cc":"Claude Work","ccodex":"Codex Work"},
          "accountPrivacy": {"claudeHidden":false,"codexHidden":true},
          "startAtLogin": false,
          "showDockIcon": true,
          "showMenuBarIcon": true
        }
        """#
        try Data(legacyJSON.utf8).write(to: store.paths.configFile)

        let loaded = try store.loadDocument()

        XCTAssertEqual(loaded.config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(loaded.config.claudeAPI.commandName, "claude-api-work")
        XCTAssertEqual(loaded.config.claudeAPI.nickname, "Claude API")
        XCTAssertTrue(loaded.config.claudeAPI.dangerousPermissionsEnabled)
        XCTAssertEqual(loaded.config.codexAPI.commandName, "codex-api-work")
        XCTAssertEqual(loaded.config.codexAPI.nickname, "Codex API")
        XCTAssertEqual(loaded.legacyOAuthDefaults?.claude?.commandName, "claude-work")
        XCTAssertEqual(loaded.legacyOAuthDefaults?.claude?.nickname, "Claude Work")
        XCTAssertEqual(loaded.legacyOAuthDefaults?.claude?.accountDetailHidden, false)
        XCTAssertEqual(loaded.legacyOAuthDefaults?.codex?.commandName, "codex-work")
        XCTAssertEqual(loaded.legacyOAuthDefaults?.codex?.nickname, "Codex Work")
        XCTAssertEqual(loaded.legacyOAuthDefaults?.codex?.accountDetailHidden, true)
        XCTAssertTrue(loaded.requiresCanonicalRewrite)
    }

    func testVersion2SingletonAPISettingsDecodeAsFixedProfiles() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        let json = #"{"schemaVersion":2,"port":28317,"claudeAPI":{"commandName":"claude_work","nickname":"Work","dangerousPermissionsEnabled":true},"codexAPI":{"commandName":"codex_personal","nickname":"Personal","codex":{"opus":{"model":"gpt-5.6-terra","reasoning":"xhigh"},"sonnet":{"model":"gpt-5.6-terra","reasoning":"medium"},"haiku":{"model":"gpt-5.6-terra","reasoning":"low"}},"dangerousPermissionsEnabled":false},"startAtLogin":false,"showDockIcon":true,"showMenuBarIcon":true}"#
        try json.write(to: store.paths.configFile, atomically: true, encoding: .utf8)

        let result = try store.loadDocument()

        XCTAssertTrue(result.requiresCanonicalRewrite)
        XCTAssertEqual(result.config.apiKeyProfiles.map(\.id), ["claude-api", "codex-api"])
        XCTAssertEqual(result.config.apiKeyProfiles[0].secretReference, .claudeAPIKey)
        XCTAssertEqual(result.config.apiKeyProfiles[0].commandName, "claude_work")
        XCTAssertEqual(result.config.apiKeyProfiles[0].nickname, "Work")
        XCTAssertTrue(result.config.apiKeyProfiles[0].dangerousPermissionsEnabled)
        XCTAssertEqual(result.config.apiKeyProfiles[1].secretReference, .codexAPIKey)
        XCTAssertEqual(result.config.apiKeyProfiles[1].commandName, "codex_personal")
    }

    func testCanonicalSaveWritesVersion3APIKeyProfiles() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        var config = AppConfig.default
        config.claudeAPI.commandName = "claude-api-work"
        config.codexAPI.commandName = "codex-api-work"

        try store.save(config)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.configFile)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 3)
        let profiles = try XCTUnwrap(object["apiKeyProfiles"] as? [[String: Any]])
        XCTAssertEqual(Set(profiles.compactMap { $0["id"] as? String }), ["claude-api", "codex-api"])
        for legacyKey in [
            "claudeAPI",
            "codexAPI",
            "commands",
            "ccapi",
            "ccodex",
            "nicknames",
            "accountPrivacy",
            "includeDangerouslySkipPermissions"
        ] {
            XCTAssertNil(object[legacyKey], "Unexpected legacy key: \(legacyKey)")
        }
    }

    func testCurrentConfigNormalizesBindAddressAndRequestsOneCanonicalRewrite() throws {
        let fixtures: [(name: String, value: String?, shouldRewrite: Bool)] = [
            ("missing", nil, true),
            ("loopback", ProxyNetworkPolicy.loopbackHost, false),
            ("wildcard", "0.0.0.0", true),
            ("blank", "   ", true),
            ("hostname", "proxy.local", true),
            ("ipv6-wildcard", "::", true)
        ]

        for fixture in fixtures {
            let sandbox = try makeSandbox()
            let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
            var object: [String: Any] = [
                "schemaVersion": AppConfig.currentSchemaVersion,
                "port": 28_317,
                "logLevel": LogLevel.info.rawValue
            ]
            object["bindAddress"] = fixture.value
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: store.paths.configFile)

            let loaded = try store.loadDocument()

            XCTAssertEqual(loaded.config.bindAddress, ProxyNetworkPolicy.loopbackHost, fixture.name)
            XCTAssertEqual(loaded.requiresCanonicalRewrite, fixture.shouldRewrite, fixture.name)

            try store.save(loaded.config)
            let reloaded = try store.loadDocument()
            XCTAssertEqual(reloaded.config.bindAddress, ProxyNetworkPolicy.loopbackHost, fixture.name)
            XCTAssertFalse(reloaded.requiresCanonicalRewrite, fixture.name)
        }
    }

    func testVersion2WildcardBindAddressMigratesToLoopback() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        try #"{"schemaVersion":2,"port":28317,"bindAddress":"0.0.0.0"}"#.write(
            to: store.paths.configFile,
            atomically: true,
            encoding: .utf8
        )

        let loaded = try store.loadDocument()

        XCTAssertEqual(loaded.config.bindAddress, ProxyNetworkPolicy.loopbackHost)
        XCTAssertTrue(loaded.requiresCanonicalRewrite)
        try store.save(loaded.config)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.configFile)) as? [String: Any]
        )
        XCTAssertEqual(object["bindAddress"] as? String, ProxyNetworkPolicy.loopbackHost)
    }

    func testAppConfigInitializerDoesNotAllowWildcardBindAddress() {
        let config = AppConfig(
            port: 28_317,
            startAtLogin: false,
            showDockIcon: true,
            showMenuBarIcon: true,
            bindAddress: "0.0.0.0"
        )

        XCTAssertEqual(config.bindAddress, ProxyNetworkPolicy.loopbackHost)
    }

    func testCurrentConfigNormalizesLogLevelAndRequestsOneCanonicalRewrite() throws {
        let fixtures: [(name: String, value: String?, expected: LogLevel, shouldRewrite: Bool)] = [
            ("missing", nil, .info, true),
            ("error", "error", .info, true),
            ("warn", "warn", .info, true),
            ("info", "info", .info, false),
            ("debug", "debug", .debug, false),
            ("unknown", "trace", .info, true)
        ]

        for fixture in fixtures {
            let sandbox = try makeSandbox()
            let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
            var object: [String: Any] = [
                "schemaVersion": AppConfig.currentSchemaVersion,
                "port": 28_317,
                "bindAddress": ProxyNetworkPolicy.loopbackHost
            ]
            object["logLevel"] = fixture.value
            try JSONSerialization.data(withJSONObject: object).write(to: store.paths.configFile)

            let loaded = try store.loadDocument()

            XCTAssertEqual(loaded.config.logLevel, fixture.expected, fixture.name)
            XCTAssertEqual(loaded.config.runtimeLogConfiguration.proxyDebugEnabled, fixture.expected == .debug, fixture.name)
            XCTAssertEqual(loaded.requiresCanonicalRewrite, fixture.shouldRewrite, fixture.name)

            try store.save(loaded.config)
            let reloaded = try store.loadDocument()
            XCTAssertEqual(reloaded.config.logLevel, fixture.expected, fixture.name)
            XCTAssertFalse(reloaded.requiresCanonicalRewrite, fixture.name)
        }
    }

    func testLegacyLogLevelsMigrateDeterministically() throws {
        for (schemaVersion, rawLevel, expected) in [
            (1, "error", LogLevel.info),
            (1, "debug", LogLevel.debug),
            (2, "warn", LogLevel.info),
            (2, "future", LogLevel.info)
        ] {
            let sandbox = try makeSandbox()
            let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
            let object: [String: Any] = [
                "schemaVersion": schemaVersion,
                "port": 28_317,
                "logLevel": rawLevel
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: store.paths.configFile)

            let loaded = try store.loadDocument()

            XCTAssertEqual(loaded.config.logLevel, expected, "schema=\(schemaVersion), raw=\(rawLevel)")
            XCTAssertTrue(loaded.requiresCanonicalRewrite)
        }
    }

    func testStoreRejectsFutureSchemaVersion() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        try #"{"schemaVersion":99,"port":28317}"#.write(
            to: store.paths.configFile,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try store.loadDocument()) { error in
            XCTAssertEqual(error as? AppConfigStoreError, .unsupportedSchemaVersion(99))
        }
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

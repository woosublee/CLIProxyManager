import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyManagerCommandTests: XCTestCase {
    func testSecretGetStillPrintsSecret() async throws {
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "secret-value"]),
            output: output
        )

        try await command.run(arguments: ["secret", "get", "claude-api-key"])

        XCTAssertEqual(output.stdout, ["secret-value\n"])
    }

    func testCodexAPISecretGetPrintsSecret() async throws {
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(values: [.codexAPIKey: "codex-secret"]),
            output: output
        )

        try await command.run(arguments: ["secret", "get", "codex-api-key"])

        XCTAssertEqual(output.stdout, ["codex-secret\n"])
    }

    func testSecretMutationsExplainThatRunningProxyNeedsRestart() async throws {
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            input: { "new-secret\n" },
            output: output
        )

        try await command.run(arguments: ["secret", "set", "claude-api-key"])
        try await command.run(arguments: ["secret", "delete", "claude-api-key"])

        XCTAssertEqual(output.stderr, [
            "Restart CLIProxyAPI with `cpm restart` to apply the API key change.\n",
            "Restart CLIProxyAPI with `cpm restart` to apply the API key change.\n"
        ])
    }

    func testDefaultCLICommandReadsAPIKeyFromManagedFileStore() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        try AppConfigStore(paths: paths).save(.default)
        try FileSecretStore(paths: paths).set("file-secret", for: .claudeAPIKey)
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            configStore: AppConfigStore(paths: paths),
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: output
        )

        try await command.run(arguments: ["secret", "get", "claude-api-key"])

        XCTAssertEqual(output.stdout, ["file-secret\n"])
    }

    func testRoutingNextPrintsShellAssignments() async throws {
        let sandbox = try makeSandbox()
        let configStore = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(id: "codex-a", provider: .codex, authProfileID: "codex-a.json", commandName: "cca", modelPrefix: "codex-a"),
            AppConfig.OAuthCommandProfile(id: "codex-b", provider: .codex, authProfileID: "codex-b.json", commandName: "ccb", modelPrefix: "codex-b")
        ]
        config.roundRobinProfiles = [
            AppConfig.RoundRobinProfile(id: "codex-default", provider: .codex, isEnabled: true, commandName: "ccodex", includedAuthProfileIDs: ["codex-a.json", "codex-b.json"])
        ]
        try configStore.save(config)
        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","prefix":"codex-a","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex-a.json"))
        try Data(#"{"type":"codex","prefix":"codex-b","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex-b.json"))
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            stateSelector: RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("round-robin-state.json")),
            output: output
        )

        try await command.run(arguments: ["routing", "next", "codex-default"])

        XCTAssertEqual(output.stdout.count, 1)
        XCTAssertTrue(output.stdout[0].hasSuffix("\n"))
        XCTAssertTrue(output.stdout[0].contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-a/gpt-5.6-terra(xhigh)'"))
        XCTAssertTrue(output.stdout[0].contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-a.json'"))
    }

    func testRoutingNextResolvesClaudeModelsForSelectedAccount() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.port = 18_888
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
            .init(id: "claude-default", provider: .claude, isEnabled: true, commandName: "cc", includedAuthProfileIDs: ["claude-personal.json", "claude-work.json"])
        ]
        try configStore.save(config)
        try FileManager.default.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","prefix":"claude-work","disabled":false}"#.utf8)
            .write(to: paths.authDirectory.appendingPathComponent("claude-work.json"))
        try Data(#"{"type":"claude","prefix":"claude-personal","disabled":false}"#.utf8)
            .write(to: paths.authDirectory.appendingPathComponent("claude-personal.json"))
        let models = StubClaudeModelListing(optionsByPrefix: [
            "claude-personal": [
                .init(id: "claude-opus-4-7"),
                .init(id: "claude-sonnet-4-6"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            stateSelector: RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("round-robin-state.json")),
            output: output,
            claudeModelClient: models
        )

        try await command.run(arguments: ["routing", "next", "claude-default"])

        XCTAssertEqual(models.requests.map { "\($0.port):\($0.prefix)" }, ["18888:claude-personal"])
        XCTAssertTrue(output.stdout.joined().contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-personal/claude-opus-4-7'"))
    }

    func testQuotaKeySetStatusAndDeleteUseInjectedLocalFileWithoutPrintingKey() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        try configStore.save(.default)
        let output = OutputDouble(isInteractive: false)
        let keyStore = SubscriptionUsageManagementKeyFileStore(paths: paths)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: sandbox.appendingPathComponent("auth", isDirectory: true)),
            input: { "management-key-value\n" },
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionUsageKeyStore: keyStore
        )

        try await command.run(arguments: ["quota", "key", "set", "--stdin"])
        try await command.run(arguments: ["quota", "key", "status"])
        try await command.run(arguments: ["quota", "key", "delete"])
        try await command.run(arguments: ["quota", "key", "status"])

        XCTAssertEqual(
            output.stdout,
            ["Management key stored.\n", "configured=true\n", "Management key removed.\n", "configured=false\n"]
        )
        XCTAssertFalse(output.stdout.joined().contains("management-key-value"))
        XCTAssertTrue(try configStore.load().subscriptionUsage.showInMenuBar)
        XCTAssertTrue(try configStore.load().isSubscriptionUsageEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.subscriptionUsageManagementKeyFile.path))
        XCTAssertEqual(services.calls, [.proxyStatus, .proxyStatus])
    }

    func testQuotaKeySetPreservesExistingKeyWhenHUDOnlyConfigSaveFails() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        try configStore.save(config)
        let keyStore = CommandManagementKeyStore(key: "existing-key")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.rootDirectory.path)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            input: { "replacement-key\n" },
            output: OutputDouble(isInteractive: false),
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionUsageKeyStore: keyStore
        )

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["quota", "key", "set", "--stdin"]))

        XCTAssertEqual(keyStore.key, "existing-key")
        XCTAssertEqual(services.calls, [])
    }

    func testQuotaKeyGetIsRejected() async {
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            output: OutputDouble(isInteractive: false),
            subscriptionUsageKeyStore: CommandManagementKeyStore()
        )

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["quota", "key", "get"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    func testQuotaFetchesWhenOnlyUsageHUDIsEnabled() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        try configStore.save(config)

        let authDirectory = paths.authDirectory
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","disabled":false}"#.utf8)
            .write(to: authDirectory.appendingPathComponent("codex.json"))
        let quotaClient = FixedSubscriptionQuotaClient(states: [
            "codex.json": .available(.init(
                profileID: "codex.json",
                provider: .codex,
                windows: [.init(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)],
                fetchedAt: Date(timeIntervalSince1970: 0)
            ))
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            subscriptionQuotaClient: quotaClient
        )

        try await command.run(arguments: ["quota", "--json"])

        XCTAssertTrue(output.stdout.joined().contains("available"))
    }

    func testQuotaTextUsesNicknameCommandAndNormalizedCodexWindows() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "claude-work", provider: .claude, authProfileID: "claude.json", commandName: "cc", nickname: "Work Claude"),
            .init(id: "codex-personal", provider: .codex, authProfileID: "codex.json", commandName: "cdx")
        ]
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("claude.json"))
        try Data(#"{"type":"codex","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex.json"))

        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "claude.json": .available(.init(profileID: "claude.json", provider: .claude, windows: [
                    .init(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil),
                    .init(id: "seven_day", label: "7d", usedPercent: 1, resetAt: nil)
                ], fetchedAt: Date(timeIntervalSince1970: 0))),
                "codex.json": .available(.init(profileID: "codex.json", provider: .codex, windows: [
                    .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
                    .init(id: "secondary", label: "Secondary", usedPercent: 9, resetAt: nil)
                ], fetchedAt: Date(timeIntervalSince1970: 0)))
            ])
        )

        try await command.run(arguments: ["quota"])

        XCTAssertEqual(output.stdout.joined(), """
        Work Claude  $ cc
          5h   ░░░░░░░░░░   0%
          7d   ░░░░░░░░░░   1%

        Codex OAuth  $ cdx
          5h   ██░░░░░░░░  15%
          7d   █░░░░░░░░░   9%

        """)
        XCTAssertFalse(output.stdout.joined().contains("claude.json"))
        XCTAssertFalse(output.stdout.joined().contains("Primary"))
        XCTAssertFalse(output.stdout.joined().contains("Secondary"))
    }

    func testQuotaTextUsesReportedTeamWindowPeriod() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-team", provider: .codex, authProfileID: "codex.json", commandName: "cdx")
        ]
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex.json"))

        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "codex.json": .available(.init(profileID: "codex.json", provider: .codex, windows: [
                    .init(
                        id: "primary",
                        label: "Primary",
                        usedPercent: 0,
                        resetAt: nil,
                        limitWindowSeconds: 2_628_000
                    )
                ], fetchedAt: Date(timeIntervalSince1970: 0)))
            ])
        )

        try await command.run(arguments: ["quota"])

        XCTAssertTrue(output.stdout.joined().contains("  1mo  ░░░░░░░░░░   0%"), output.stdout.joined())
        XCTAssertFalse(output.stdout.joined().contains("  5h"), output.stdout.joined())
    }

    func testQuotaTextPreservesLongWindowLabel() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "claude-monthly", provider: .claude, authProfileID: "claude.json", commandName: "cc")
        ]
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("claude.json"))

        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "claude.json": .available(.init(profileID: "claude.json", provider: .claude, windows: [
                    .init(id: "monthly", label: "Monthly", usedPercent: 10, resetAt: nil)
                ], fetchedAt: Date(timeIntervalSince1970: 0)))
            ])
        )

        try await command.run(arguments: ["quota"])

        XCTAssertTrue(output.stdout.joined().contains("  Monthly █"), output.stdout.joined())
        XCTAssertFalse(output.stdout.joined().contains("  Mont █"))
    }

    func testQuotaJSONKeepsProfileIDAndRawWindowLabels() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex.json"))

        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "codex.json": .available(.init(profileID: "codex.json", provider: .codex, windows: [
                    .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil),
                    .init(id: "secondary", label: "Secondary", usedPercent: 9, resetAt: nil)
                ], fetchedAt: Date(timeIntervalSince1970: 0)))
            ])
        )

        try await command.run(arguments: ["quota", "--json"])

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.stdout.joined().utf8)) as? [String: Any])
        let accounts = try XCTUnwrap(json["accounts"] as? [[String: Any]])
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account["profileID"] as? String, "codex.json")
        let windows = try XCTUnwrap(account["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.map { $0["label"] as? String }, ["Primary", "Secondary"])
    }

    func testQuotaTextPrintsStaleSnapshotBeforeWarning() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-personal", provider: .codex, authProfileID: "codex.json", commandName: "cdx")
        ]
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex.json"))

        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "codex.json": .stale(snapshot, .credentialExpired)
            ])
        )

        try await command.run(arguments: ["quota"])

        let text = output.stdout.joined()
        XCTAssertTrue(text.contains("5h   ██░░░░░░░░  15%"))
        XCTAssertTrue(text.contains("Warning: Credential needs attention. Showing last successful usage."))
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "15%")?.lowerBound),
            try XCTUnwrap(text.range(of: "Warning:")?.lowerBound)
        )
    }

    func testQuotaJSONPreservesStaleSnapshotAndIssue() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.subscriptionUsage.showInMenuBar = true
        config.oauthCommandProfiles = [
            .init(id: "codex-personal", provider: .codex, authProfileID: "codex.json", commandName: "cdx")
        ]
        try configStore.save(config)

        let authDirectory = sandbox.appendingPathComponent("auth", isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"codex","disabled":false}"#.utf8).write(to: authDirectory.appendingPathComponent("codex.json"))

        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                .init(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )
        let output = OutputDouble(isInteractive: false)
        let services = RuntimeServicesDouble()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            subscriptionQuotaClient: FixedSubscriptionQuotaClient(states: [
                "codex.json": .stale(snapshot, .credentialExpired)
            ])
        )

        try await command.run(arguments: ["quota", "--json"])

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.stdout.joined().utf8)) as? [String: Any])
        let account = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(account["status"] as? String, "stale")
        XCTAssertEqual(account["issue"] as? String, "credentialExpired")
        XCTAssertEqual((account["windows"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Primary"])
    }

    func testUnknownArgumentsStillThrowUsage() async {
        let command = CLIProxyManagerCommand(output: OutputDouble(isInteractive: false))

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["unknown"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    func testStartDispatchesOnlyToProxyRuntime() async throws {
        let services = RuntimeServicesDouble()
        let command = makeRuntimeCommand(services: services)

        try await command.run(arguments: ["start"])

        XCTAssertEqual(services.calls, [.proxyStart])
    }

    func testAppStartDispatchesOnlyToAppLifecycle() async throws {
        let services = RuntimeServicesDouble()
        let command = makeRuntimeCommand(services: services)

        try await command.run(arguments: ["app", "start"])

        XCTAssertEqual(services.calls, [.appStart])
    }

    func testStatusJSONWritesValidJSONToStdout() async throws {
        let output = OutputDouble(isInteractive: false)
        let command = makeRuntimeCommand(output: output, services: RuntimeServicesDouble())

        try await command.run(arguments: ["status", "--json"])

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.stdout.joined().utf8)))
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testRootUserIsRejectedBeforeStart() async throws {
        let services = RuntimeServicesDouble()
        let command = makeRuntimeCommand(services: services, uid: 0)

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["start"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite(
                "cpm must run as the macOS user that owns ~/.cliproxy-manager; do not use sudo."
            ))
        }
        XCTAssertTrue(services.calls.isEmpty)
    }

    func testRootUserIsPermittedForStatus() async throws {
        let output = OutputDouble(isInteractive: false)
        let command = makeRuntimeCommand(output: output, services: RuntimeServicesDouble(), uid: 0)

        try await command.run(arguments: ["status"])

        XCTAssertFalse(output.stdout.isEmpty)
    }

    func testStopDispatchesToProxyRuntime() async throws {
        let services = RuntimeServicesDouble()
        let command = makeRuntimeCommand(services: services)

        try await command.run(arguments: ["stop"])

        XCTAssertEqual(services.calls, [.proxyStop])
    }

    func testRestartDispatchesToProxyRuntime() async throws {
        let services = RuntimeServicesDouble()
        let command = makeRuntimeCommand(services: services)

        try await command.run(arguments: ["restart"])

        XCTAssertEqual(services.calls, [.proxyRestart])
    }

    func testLogsWithDuplicateFlagThrowsUsage() async {
        let command = makeRuntimeCommand(services: RuntimeServicesDouble())

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["logs", "-f", "-f"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
        }
    }

    func testRoutingClaudeModelsPrintsOnlyShellAssignmentsForEnabledProxyProfile() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
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
            )
        ]
        try configStore.save(config)
        let models = StubClaudeModelListing(optionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8", created: 500),
                .init(id: "claude-sonnet-5", created: 400),
                .init(id: "claude-haiku-4-5", created: 300)
            ]
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: output,
            claudeModelClient: models
        )

        try await command.run(arguments: ["routing", "claude-models", "claude-work"])

        XCTAssertEqual(models.requests.map { "\($0.port):\($0.prefix)" }, ["18888:claude-work"])
        XCTAssertEqual(output.stderr, [])
        XCTAssertEqual(output.stdout, ["""
        ANTHROPIC_DEFAULT_OPUS_MODEL='claude-work/claude-opus-4-8'
        ANTHROPIC_DEFAULT_SONNET_MODEL='claude-work/claude-sonnet-5'
        ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-work/claude-haiku-4-5'

        """])
    }

    func testRoutingClaudeModelsResolvesClaudeAPIKeyModelsWithDedicatedPrefix() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.port = 18_888
        config.claudeAPI = .init(
            commandName: "claude_api",
            claude: .init(
                opus: .model("claude-opus-4-7"),
                sonnet: .automatic,
                haiku: .automatic
            )
        )
        try configStore.save(config)
        let models = StubClaudeModelListing(optionsByPrefix: [
            "cpm-claude-api": [
                .init(id: "claude-opus-4-8", created: 500),
                .init(id: "claude-opus-4-7", created: 400),
                .init(id: "claude-sonnet-5", created: 500),
                .init(id: "claude-haiku-4-5", created: 500)
            ]
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: output,
            claudeModelClient: models
        )

        try await command.run(arguments: ["routing", "claude-models", "--api"])

        XCTAssertEqual(models.requests.map { "\($0.port):\($0.prefix)" }, ["18888:cpm-claude-api"])
        XCTAssertTrue(output.stdout.joined().contains("cpm-claude-api/claude-opus-4-7"))
        XCTAssertTrue(output.stdout.joined().contains("cpm-claude-api/claude-sonnet-5"))
    }

    func testRoutingClaudeModelsRejectsInvalidProfilesWithoutQueryingModels() async throws {
        let cases: [(String, AppConfig.OAuthCommandProfile?, String)] = [
            ("unknown", nil, "Claude command profile `unknown` was not found."),
            ("disabled", .init(id: "disabled", provider: .claude, authProfileID: "claude.json", modelPrefix: "claude", isEnabled: false), "Claude command profile `disabled` is disabled."),
            ("codex", .init(id: "codex", provider: .codex, authProfileID: "codex.json", modelPrefix: "codex"), "Command profile `codex` is not a Claude OAuth profile."),
            ("direct", .init(id: "direct", provider: .claude, authProfileID: "claude.json", modelPrefix: "claude", connectionMode: .direct), "Claude command profile `direct` uses Direct mode and does not use proxy model routing."),
            ("empty-prefix", .init(id: "empty-prefix", provider: .claude, authProfileID: "claude.json", modelPrefix: "  "), "This Claude account does not have a routing prefix. Save the account settings, then retry.")
        ]

        for (target, profile, message) in cases {
            let sandbox = try makeSandbox()
            let paths = ManagedPaths(rootDirectory: sandbox)
            let configStore = AppConfigStore(paths: paths)
            var config = AppConfig.default
            config.oauthCommandProfiles = profile.map { [$0] } ?? []
            try configStore.save(config)
            let models = StubClaudeModelListing(optionsByPrefix: [:])
            let command = CLIProxyManagerCommand(
                secretStore: InMemorySecretStore(),
                configStore: configStore,
                authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
                output: OutputDouble(isInteractive: false),
                claudeModelClient: models
            )

            await XCTAssertThrowsErrorAsync(
                try await command.run(arguments: ["routing", "claude-models", target])
            ) { error in
                XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite(message))
            }
            XCTAssertTrue(models.requests.isEmpty, "Unexpected lookup for \(target)")
        }
    }

    func testLegacyClaudeRoutingAllowsAccountSpecificCodexProfiles() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            .init(id: "codex-work", provider: .codex, authProfileID: "codex-work.json", modelPrefix: "codex-work")
        ]
        try configStore.save(config)
        try FileManager.default.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","prefix":"claude-work","disabled":false}"#.utf8)
            .write(to: paths.authDirectory.appendingPathComponent("claude-work.json"))
        let models = StubClaudeModelListing(optionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: output,
            claudeModelClient: models
        )

        await XCTAssertThrowsErrorAsync(
            try await command.run(arguments: ["routing", "claude-models", "--legacy"])
        ) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("Claude command profile `--legacy` was not found.")
            )
        }
        XCTAssertTrue(models.requests.isEmpty)
        XCTAssertTrue(output.stdout.isEmpty)
    }

    func testLegacyClaudeRoutingRequiresExactlyOneEnabledPrefixedClaudeProfile() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        let configStore = AppConfigStore(paths: paths)
        try configStore.save(.default)
        try FileManager.default.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
        try Data(#"{"type":"claude","prefix":"claude-work","disabled":false}"#.utf8)
            .write(to: paths.authDirectory.appendingPathComponent("claude-work.json"))
        let models = StubClaudeModelListing(optionsByPrefix: [
            "claude-work": [
                .init(id: "claude-opus-4-8"),
                .init(id: "claude-sonnet-5"),
                .init(id: "claude-haiku-4-5")
            ]
        ])
        let output = OutputDouble(isInteractive: false)
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: output,
            claudeModelClient: models
        )

        await XCTAssertThrowsErrorAsync(
            try await command.run(arguments: ["routing", "claude-models", "--legacy"])
        ) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("Claude command profile `--legacy` was not found.")
            )
        }
        XCTAssertTrue(models.requests.isEmpty)
        XCTAssertTrue(output.stdout.isEmpty)
    }

    func testLegacyClaudeRoutingRejectsMultipleProfilesWithoutQueryingModels() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox)
        try AppConfigStore(paths: paths).save(.default)
        try FileManager.default.createDirectory(at: paths.authDirectory, withIntermediateDirectories: true)
        for id in ["claude-a", "claude-b"] {
            try Data(#"{"type":"claude","prefix":"prefix","disabled":false}"#.utf8)
                .write(to: paths.authDirectory.appendingPathComponent("\(id).json"))
        }
        let models = StubClaudeModelListing(optionsByPrefix: [:])
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: AppConfigStore(paths: paths),
            authProfileStore: AuthProfileStore(authDirectory: paths.authDirectory),
            output: OutputDouble(isInteractive: false),
            claudeModelClient: models
        )

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["routing", "claude-models", "--legacy"])) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("Claude command profile `--legacy` was not found.")
            )
        }
        XCTAssertTrue(models.requests.isEmpty)
    }

    private func makeRuntimeCommand(
        output: OutputDouble = OutputDouble(isInteractive: false),
        services: RuntimeServicesDouble,
        uid: uid_t = 501
    ) -> CLIProxyManagerCommand {
        CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            output: output,
            proxyRuntime: services,
            appLifecycle: services,
            logService: services,
            statusReporter: services,
            currentUID: { uid }
        )
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

private struct FixedSubscriptionQuotaClient: SubscriptionQuotaFetching {
    let states: [String: AccountSubscriptionUsageState]

    func fetchUsage(port: Int, profiles: [AuthProfile]) async -> SubscriptionUsageReport {
        SubscriptionUsageReport(statesByProfileID: states, fetchedAt: Date(timeIntervalSince1970: 0))
    }
}

private final class CommandManagementKeyStore: SubscriptionUsageManagementKeyConfiguring, @unchecked Sendable {
    private(set) var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func isConfigured() -> Bool { key != nil }
    func createManagementKeyIfNeeded() throws -> Bool {
        guard key == nil else { return false }
        key = "generated-management-key"
        return true
    }
    func setManagementKey(_ value: String) throws { key = value }
    func deleteManagementKey() throws { key = nil }
}

private final class StubClaudeModelListing: ClaudeModelListing, @unchecked Sendable {
    private(set) var requests: [(port: Int, prefix: String)] = []
    var optionsByPrefix: [String: [ClaudeModelOption]]

    init(optionsByPrefix: [String: [ClaudeModelOption]]) {
        self.optionsByPrefix = optionsByPrefix
    }

    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption] {
        requests.append((port, modelPrefix))
        return optionsByPrefix[modelPrefix] ?? []
    }
}

private final class OutputDouble: CLICommandOutputWriting, @unchecked Sendable {
    let isInteractive: Bool
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []

    init(isInteractive: Bool) { self.isInteractive = isInteractive }

    func writeStdout(_ text: String) { stdout.append(text) }
    func writeStderr(_ text: String) { stderr.append(text) }
    func confirm(_: String) -> Bool { false }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private final class RuntimeServicesDouble: ProxyRuntimeServicing, AppLifecycleControlling, ProxyLogServicing, StatusReporting, @unchecked Sendable {
    enum Call: Equatable {
        case proxyStart, proxyStop, proxyRestart, proxyStatus
        case appStart, appStop, appRestart, appStatus
        case logsRead, logsFollow
        case statusReport
    }

    private(set) var calls: [Call] = []
    let lock = NSLock()

    private func record(_ call: Call) { lock.withLock { calls.append(call) } }

    private let proxyStatusResult = ProxyRuntimeStatus(port: 8317, running: false, health: ProxyHealthSummary(title: "OK", message: "OK"), activeVersion: nil, pendingVersion: nil)
    private let appStatusResult = AppLifecycleStatus(installed: true, running: false, path: nil, version: nil, build: nil)

    // ProxyRuntimeServicing
    func status() async throws -> ProxyRuntimeStatus { record(.proxyStatus); return proxyStatusResult }
    func start() async throws -> ProxyRuntimeStatus { record(.proxyStart); return proxyStatusResult }
    func stop() async throws -> ProxyRuntimeStatus { record(.proxyStop); return proxyStatusResult }
    func restart() async throws -> ProxyRuntimeStatus { record(.proxyRestart); return proxyStatusResult }

    // AppLifecycleControlling
    func status() async throws -> AppLifecycleStatus { record(.appStatus); return appStatusResult }
    func start() async throws -> AppLifecycleStatus { record(.appStart); return appStatusResult }
    func stop() async throws -> AppLifecycleStatus { record(.appStop); return appStatusResult }
    func restart() async throws -> AppLifecycleStatus { record(.appRestart); return appStatusResult }

    // ProxyLogServicing
    func readLastLines(_ lineCount: Int) throws -> ProxyLogSnapshot {
        record(.logsRead)
        return ProxyLogSnapshot(fileURL: URL(fileURLWithPath: "/tmp/main.log"), text: "")
    }
    func follow() throws { record(.logsFollow) }

    // StatusReporting
    func status() async throws -> CPMStatus {
        record(.statusReport)
        return CPMStatus(
            app: CPMStatus.App(installed: true, path: nil, version: nil, build: nil, running: false, stagedVersion: nil),
            helper: CPMStatus.Helper(path: "/usr/local/bin/cpm", installed: false, matchesBundled: false),
            proxy: CPMStatus.Proxy(port: 8317, running: false, activeVersion: nil, pendingVersion: nil, stagedVersion: nil, logsPath: "/tmp/logs")
        )
    }
}

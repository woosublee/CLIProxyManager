import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testExplicitLoopbackConfigAcceptsOnlyOneTopLevelLoopbackHost() {
        let valid = [
            "host: \"127.0.0.1\"\nport: 28317\n",
            "host: '127.0.0.1'\nport: 28317\n",
            "host: 127.0.0.1\nport: 28317\n"
        ]
        for yaml in valid {
            XCTAssertTrue(ProxyServiceManager.isExplicitLoopbackConfig(Data(yaml.utf8)), yaml)
        }

        let invalid = [
            "host: \"0.0.0.0\"\nport: 28317\n",
            "server:\n  host: \"127.0.0.1\"\nport: 28317\n",
            "host: \"127.0.0.1\"\nhost: \"127.0.0.1\"\nport: 28317\n",
            "host: \"127.0.0.1\nport: 28317\n"
        ]
        for yaml in invalid {
            XCTAssertFalse(ProxyServiceManager.isExplicitLoopbackConfig(Data(yaml.utf8)), yaml)
        }
    }

    func testFakeLauncherDisablesAllSystemRuntimeInspection() {
        let fakeLauncher = FakeProcessLauncher()
        let sequencedLauncher = SequencedProcessLauncher(outcomes: [])

        XCTAssertFalse(ProxyServiceManager.shouldInspectSystemRuntime(using: fakeLauncher))
        XCTAssertFalse(ProxyServiceManager.shouldInspectSystemRuntime(using: sequencedLauncher))
        XCTAssertTrue(ProxyServiceManager.defaultLaunchctlManager(using: fakeLauncher) is DisabledLaunchctlManager)
        XCTAssertTrue(ProxyServiceManager.defaultLaunchctlManager(using: sequencedLauncher) is DisabledLaunchctlManager)
    }

    func testStopWithFakeLauncherCannotRemoveLaunchdJobs() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launchctl = RunningLabelsLaunchctl(labels: ["com.cliproxymanager.port.28317"])
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            launchctl: launchctl,
            inspectLaunchctlJobs: true,
            inspectSystemProcesses: false
        )

        try await manager.stop()

        XCTAssertTrue(launchctl.removedLabels.isEmpty)
    }

    func testManagedPathsExposeAppManagedAuthDirectory() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))

        XCTAssertEqual(paths.authDirectory, sandbox.appendingPathComponent("managed/auth", isDirectory: true))
    }

    func testManagedPathsExposeCLIProxyAPIUpdatePaths() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))

        XCTAssertEqual(paths.activeClipProxyManifest, sandbox.appendingPathComponent("managed/cliproxyapi/active-manifest.json"))
        XCTAssertEqual(paths.pendingClipProxyDirectory, sandbox.appendingPathComponent("managed/cliproxyapi/pending", isDirectory: true))
        XCTAssertEqual(paths.pendingClipProxyBinary, sandbox.appendingPathComponent("managed/cliproxyapi/pending/cliproxyapi"))
        XCTAssertEqual(paths.pendingClipProxyManifest, sandbox.appendingPathComponent("managed/cliproxyapi/pending/manifest.json"))
        XCTAssertEqual(
            paths.pendingClipProxyApplyOnNextStartMarker,
            sandbox.appendingPathComponent("managed/cliproxyapi/pending/apply-on-next-start")
        )
        XCTAssertEqual(paths.clipProxyUpdateStateFile, sandbox.appendingPathComponent("managed/cliproxyapi/update-state.json"))
    }

    func testStartWritesCompatibleConfigAndLaunchesBinaryWithConfigPath() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.clipProxyDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        var authIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.authDirectory.path, isDirectory: &authIsDirectory))
        XCTAssertTrue(authIsDirectory.boolValue)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(config, """
        host: "127.0.0.1"
        port: 8317
        auth-dir: "\(paths.authDirectory.path)"
        logging-to-file: true
        debug: false
        api-keys:
          - sk-dummy


        """)
        XCTAssertEqual(config.components(separatedBy: "host: \"127.0.0.1\"").count - 1, 1)
        XCTAssertFalse(config.contains("host: \"0.0.0.0\""))
        XCTAssertTrue(config.contains("port: 8317"))
        XCTAssertTrue(config.contains("auth-dir: \"\(paths.authDirectory.path)\""))
        XCTAssertFalse(config.contains("~/.cli-proxy-api"))
        XCTAssertTrue(config.contains("logging-to-file: true"))
        XCTAssertTrue(config.contains("debug: false"))
        XCTAssertTrue(config.contains("api-keys:"))
        XCTAssertTrue(config.contains("  - sk-dummy"))
        XCTAssertFalse(config.contains("claude-api-key:"))
        XCTAssertFalse(config.contains("codex-api-key:"))
        XCTAssertFalse(config.contains("https://api.anthropic.com"))
        XCTAssertFalse(config.contains("https://api.openai.com/v1"))

        XCTAssertEqual(launcher.invocations, [
            FakeProcessLauncher.Invocation(
                executable: paths.clipProxyBinary.path,
                arguments: ["--config", paths.clipProxyConfigFile.path]
            )
        ])
    }

    func testStartMapsDebugLogLevelToSingleProxyDebugKey() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let config: AppConfig = {
            var config = AppConfig.default
            config.logLevel = .debug
            return config
        }()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            appConfigProvider: { config }
        )

        try await manager.start(port: 18_318)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(yaml.contains("debug: true"))
        XCTAssertEqual(yaml.components(separatedBy: "debug:").count - 1, 1)
        XCTAssertFalse(yaml.contains("debug: false"))
    }

    func testStartEnablesUsageQueueOnlyWhenUsageAndAPIKeyAreBothPresent() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "management-key" },
            usageEnabledProvider: { true },
            claudeAPIKeyProvider: { "claude-key" },
            codexAPIKeyProvider: { nil }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(yaml.components(separatedBy: "host: \"127.0.0.1\"").count - 1, 1)
        XCTAssertFalse(yaml.contains("host: \"0.0.0.0\""))
        XCTAssertTrue(yaml.contains("usage-statistics-enabled: true"))
        XCTAssertTrue(yaml.contains("redis-usage-queue-retention-seconds: 3600"))
        XCTAssertTrue(yaml.contains("remote-management:"))
    }

    func testStartUsesOneUsageEnabledSnapshotForManagementAndQueue() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let callCounter = ProviderCallCounter()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "management-key" },
            usageEnabledProvider: {
                callCounter.increment()
                return callCounter.value == 1
            },
            claudeAPIKeyProvider: { "claude-key" },
            codexAPIKeyProvider: { nil }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(callCounter.value, 1)
        XCTAssertTrue(yaml.contains("remote-management:"))
        XCTAssertTrue(yaml.contains("usage-statistics-enabled: true"))
    }

    func testStartOmitsUsageQueueWhenUsageIsDisabledEvenWithAPIKey() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "management-key" },
            usageEnabledProvider: { false },
            claudeAPIKeyProvider: { "claude-key" },
            codexAPIKeyProvider: { nil }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(yaml.contains("usage-statistics-enabled:"))
        XCTAssertFalse(yaml.contains("redis-usage-queue-retention-seconds:"))
    }

    func testStartOmitsUsageQueueWhenOnlyOAuthUsageIsEnabled() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "management-key" },
            usageEnabledProvider: { true },
            claudeAPIKeyProvider: { nil },
            codexAPIKeyProvider: { nil }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(yaml.contains("usage-statistics-enabled:"))
        XCTAssertFalse(yaml.contains("redis-usage-queue-retention-seconds:"))
        XCTAssertTrue(yaml.contains("remote-management:"))
    }

    func testStartWritesOAuthAndAPIKeyFastAliasesWithPriorityPayload() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        var config = AppConfig.default
        config.oauthCommandProfiles = [
            AppConfig.OAuthCommandProfile(
                id: "codex",
                provider: .codex,
                authProfileID: "codex.json",
                codex: AppConfig.Codex.default,
                modelPrefix: "codex-account"
            )
        ]
        config.oauthCommandProfiles[0].codex!.opus = .init(model: "gpt-5.6-sol", reasoning: .xhigh, fastModeEnabled: true)
        config.codexAPI.codex.sonnet = .init(model: "gpt-5.5", reasoning: .medium, fastModeEnabled: true)
        let configuredAppConfig = config
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            codexAPIKeyProvider: { "codex-key" },
            appConfigProvider: { configuredAppConfig }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(yaml.components(separatedBy: "host: \"127.0.0.1\"").count - 1, 1)
        XCTAssertFalse(yaml.contains("host: \"0.0.0.0\""))
        XCTAssertTrue(yaml.contains("oauth-model-alias:"))
        XCTAssertTrue(yaml.contains("name: \"gpt-5.6-sol\""))
        XCTAssertTrue(yaml.contains("alias: \"gpt-5.6-sol-fast\""))
        XCTAssertTrue(yaml.contains("fork: true"))
        XCTAssertTrue(yaml.contains("models:"))
        XCTAssertTrue(yaml.contains("name: \"gpt-5.5\""))
        XCTAssertTrue(yaml.contains("alias: \"gpt-5.5-fast\""))
        XCTAssertTrue(yaml.contains("payload:"))
        XCTAssertTrue(yaml.contains("service_tier: priority"))
        XCTAssertEqual(yaml.components(separatedBy: "alias: \"gpt-5.6-sol-fast\"").count - 1, 1)
    }

    func testStartReadsCodexAPIKeyOnceAndOmitsAPIKeyFastModelsWithoutCredential() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        var config = AppConfig.default
        config.codexAPI.codex.opus.fastModeEnabled = true
        let configuredAppConfig = config
        let callCounter = ProviderCallCounter()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            codexAPIKeyProvider: {
                callCounter.increment()
                return nil
            },
            appConfigProvider: { configuredAppConfig }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(callCounter.value, 1)
        XCTAssertFalse(yaml.contains("codex-api-key:"))
        XCTAssertFalse(yaml.contains("gpt-5.6-terra-fast"))
    }

    func testStartReadsConfiguredLegacyCodexAPIKeyOnlyOnce() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let callCounter = ProviderCallCounter()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            codexAPIKeyProvider: {
                callCounter.increment()
                return "codex-key"
            },
            appConfigProvider: { .default }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(callCounter.value, 1)
        XCTAssertTrue(yaml.contains("codex-key"))
        XCTAssertTrue(yaml.contains("prefix: \"cpm-codex-api\""))
    }

    func testStartKeepsNoFastCodexAPIYAMLByteCompatibleWithMainRenderer() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            codexAPIKeyProvider: { "codex-key" },
            appConfigProvider: { .default }
        )

        try await manager.start(port: 8317)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8), """
        host: "127.0.0.1"
        port: 8317
        auth-dir: "\(paths.authDirectory.path)"
        logging-to-file: true
        debug: false
        api-keys:
          - sk-dummy


        codex-api-key:
          - api-key: "codex-key"
            base-url: "https://api.openai.com/v1"
            prefix: "cpm-codex-api"
        """)
    }

    func testStartOmitsFastSectionsWhenNoRolesUseFastMode() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            codexAPIKeyProvider: { "codex-key" },
            appConfigProvider: { .default }
        )

        try await manager.start(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(yaml.contains("oauth-model-alias:"))
        XCTAssertFalse(yaml.contains("-fast"))
        XCTAssertFalse(yaml.contains("payload:"))
    }

    func testStartPropagatesAppConfigLoadFailureWithoutWritingYAML() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let loadError = CocoaError(.fileReadCorruptFile)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            appConfigProvider: { throw loadError }
        )

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected config load failure")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .writeFailed(loadError.localizedDescription))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyConfigFile.path))
    }

    func testStartAddsConfiguredAPIKeysWithOfficialBaseURLsAndFixedPrefixes() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            claudeAPIKeyProvider: { "claude-key\"\nvalue" },
            codexAPIKeyProvider: { "codex-key" }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("claude-api-key:"))
        XCTAssertTrue(config.contains("api-key: \"claude-key\\\"\\nvalue\""))
        XCTAssertTrue(config.contains("base-url: \"https://api.anthropic.com\""))
        XCTAssertTrue(config.contains("prefix: \"cpm-claude-api\""))
        XCTAssertTrue(config.contains("codex-api-key:"))
        XCTAssertTrue(config.contains("api-key: \"codex-key\""))
        XCTAssertTrue(config.contains("base-url: \"https://api.openai.com/v1\""))
        XCTAssertTrue(config.contains("prefix: \"cpm-codex-api\""))
        XCTAssertTrue(config.contains("auth-dir: \"\(paths.authDirectory.path)\""))
        XCTAssertTrue(config.contains("  - sk-dummy"))
    }

    func testStartAlwaysAddsClaudeAPIKeyRegardlessOfLegacyConnectionMode() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            claudeAPIKeyProvider: { "claude-key" },
            codexAPIKeyProvider: { nil }        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("claude-api-key:"))
        XCTAssertTrue(config.contains("api-key: \"claude-key\""))
        XCTAssertTrue(config.contains("prefix: \"cpm-claude-api\""))
    }

    func testStartAddsManagementSecretOnlyWhenConfigured() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "management-key" },
            usageEnabledProvider: { true }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("remote-management:"))
        XCTAssertTrue(config.contains("secret-key: \"management-key\""))

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.clipProxyConfigFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStartReadsManagementSecretFromItsManagedPathsRootByDefault() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        try SubscriptionUsageManagementKeyFileStore(paths: paths).setManagementKey("sandbox-management-key")
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            usageEnabledProvider: { true }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("secret-key: \"sandbox-management-key\""))
    }

    func testStartAddsManagementSecretWhenOnlyUsageHUDIsVisible() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        var config = AppConfig.default
        config.usageOverlay.isVisible = true
        try AppConfigStore(paths: paths).save(config)
        try SubscriptionUsageManagementKeyFileStore(paths: paths).setManagementKey("management-key")
        let manager = ProxyServiceManager(paths: paths, launcher: FakeProcessLauncher())

        try await manager.start(port: 8317)

        let generatedConfig = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(generatedConfig.contains("remote-management:"))
        XCTAssertTrue(generatedConfig.contains("secret-key: \"management-key\""))
    }

    func testStartOmitsManagementSecretWhenLocalStorageIsInvalid() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        try FileManager.default.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: paths.subscriptionUsageManagementKeyFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.subscriptionUsageManagementKeyFile.path
        )
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            usageEnabledProvider: { true }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(config.contains("remote-management:"))
        XCTAssertFalse(config.contains("secret-key:"))
    }

    func testStartOmitsManagementSecretWhenSubscriptionUsageIsDisabledEvenIfAKeyExists() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { "stored-management-key" },
            usageEnabledProvider: { false }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(config.contains("remote-management:"))
        XCTAssertFalse(config.contains("secret-key:"))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.clipProxyConfigFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStartOmitsManagementSecretWhenConfiguredKeyIsBlank() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            managementKeyProvider: { " \n " },
            usageEnabledProvider: { true }
        )

        try await manager.start(port: 8317)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertFalse(config.contains("remote-management:"))
    }

    func testStartEscapesControlCharactersInYAMLAuthDirectory() async throws {
        let sandbox = try makeSandbox()
        let root = sandbox.appendingPathComponent("managed\nroot\twith\rcontrol")
        let paths = ManagedPaths(rootDirectory: root)
        try createBinary(at: paths.clipProxyBinary)
        let manager = ProxyServiceManager(paths: paths, launcher: FakeProcessLauncher())

        try await manager.start(port: 8317)

        let escapedAuthPath = paths.authDirectory.path
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("auth-dir: \"\(escapedAuthPath)\""))
        XCTAssertFalse(config.contains("managed\nroot\twith\rcontrol/auth"))
    }

    func testStartCopiesBundledBinaryWhenManagedBinaryIsMissing() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho bundled\n")
        let bundledManifestURL = try writeBundledManifest(for: bundledBinary, version: "7.2.41", in: sandbox)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifestURL, launcher: launcher)

        try await manager.start(port: 8317)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
        XCTAssertEqual(launcher.invocations.first?.executable, paths.clipProxyBinary.path)
    }

    func testStartReplacesManagedBinaryWhenBundledBinaryChanges() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary, contents: "#!/bin/sh\necho old\n")
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho new\n")
        let bundledManifestURL = try writeBundledManifest(for: bundledBinary, version: "7.2.41", in: sandbox)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifestURL, launcher: launcher)

        try await manager.start(port: 8317)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho new\n")
    }

    func testStartKeepsUserUpdatedBinaryWhenBundledBinaryIsOlder() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary, contents: "#!/bin/sh\necho active\n")
        let activeManifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: "7.2.42",
            commit: "active",
            builtAt: "2026-07-01T00:00:00Z",
            sourceKind: .userUpdated,
            source: "https://example.com/active.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v7.2.42",
            upstreamAsset: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: try Data(contentsOf: paths.clipProxyBinary).sha256HexDigest(),
            vendoredBinarySizeBytes: try XCTUnwrap(paths.clipProxyBinary.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            vendoredFromArchivePath: "cli-proxy-api"
        )
        try FileManager.default.createDirectory(at: paths.activeClipProxyManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(activeManifest).write(to: paths.activeClipProxyManifest)
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        let bundledManifestURL = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho bundled\n")
        let bundledManifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: "7.2.41",
            commit: "bundled",
            builtAt: "2026-06-25T17:56:53Z",
            sourceKind: .bundled,
            source: "https://example.com/bundled.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v7.2.41",
            upstreamAsset: "CLIProxyAPI_7.2.41_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: try Data(contentsOf: bundledBinary).sha256HexDigest(),
            vendoredBinarySizeBytes: try XCTUnwrap(bundledBinary.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            vendoredFromArchivePath: "cli-proxy-api"
        )
        try FileManager.default.createDirectory(at: bundledManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bundledManifest).write(to: bundledManifestURL)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, bundledManifestURL: bundledManifestURL, launcher: launcher)

        try await manager.start(port: 8317)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho active\n")
        XCTAssertEqual(launcher.invocations.first?.executable, paths.clipProxyBinary.path)
    }

    func testStartDoesNotUseRealHomeWhenPathsUseTemporaryRoot() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 9000)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains(paths.clipProxyDirectory.path) == false)
        XCTAssertTrue(config.contains(FileManager.default.homeDirectoryForCurrentUser.path) == false)
        XCTAssertEqual(launcher.invocations.first?.executable, paths.clipProxyBinary.path)
    }

    func testStopTerminatesAppManagedProcess() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(process: process)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.stop()

        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEventuallyEqual(process.waitUntilExitCallCount, 1)
    }

    func testStopReturnsWithoutBlockingOnProcessExitWait() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = ManagedProxyProcessDouble(waitDelay: 0.5)
        let launcher = FakeProcessLauncher(process: process)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        let startedAt = Date()
        try await manager.stop()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertEqual(process.terminateCallCount, 1)
    }

    func testStopWithoutRunningProcessIsNoOp() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.stop()

        XCTAssertEqual(launcher.invocations, [])
    }

    func testStopDoesNotTerminateExternalCLIProxyAPIProcessByDefault() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(process: process)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 28_317)
        try await manager.stop()

        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEventuallyEqual(process.waitUntilExitCallCount, 1)
    }

    func testSecondStartStopsPreviousManagedProcessBeforeLaunchingReplacement() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let events = ProxyLifecycleEventLog()
        let firstProcess = ManagedProxyProcessDouble(name: "first", events: events)
        let secondProcess = ManagedProxyProcessDouble(name: "second", events: events)
        let launcher = FakeProcessLauncher(processes: [firstProcess, secondProcess], events: events)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.start(port: 8317)

        XCTAssertEqual(firstProcess.terminateCallCount, 1)
        XCTAssertEqual(firstProcess.waitUntilExitCallCount, 1)
        XCTAssertEqual(secondProcess.terminateCallCount, 0)
        XCTAssertEqual(events.values, ["launch", "first terminate", "first wait", "launch"])
    }

    func testReconcileConfigurationRestartsTrackedProcessWhenExplicitHostIsMissing() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let firstProcess = ManagedProxyProcessDouble()
        let secondProcess = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(processes: [firstProcess, secondProcess])
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try "port: 8317\n".write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)

        let restarted = try await manager.reconcileConfiguration(port: 8317)

        XCTAssertTrue(restarted)
        XCTAssertEqual(firstProcess.terminateCallCount, 1)
        XCTAssertEqual(firstProcess.waitUntilExitCallCount, 1)
        XCTAssertEqual(launcher.invocations.count, 2)
        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(config.components(separatedBy: "host: \"127.0.0.1\"").count - 1, 1)
        XCTAssertFalse(config.contains("host: \"0.0.0.0\""))
    }

    func testReconcileRestartsAdoptedProcessEvenWhenConfigFileIsAlreadyCanonical() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let seedManager = ProxyServiceManager(paths: paths, launcher: FakeProcessLauncher())
        try await seedManager.start(port: 8317)
        try await seedManager.stop()
        let canonical = try Data(contentsOf: paths.clipProxyConfigFile)
        let launchctl = RunningLabelsLaunchctl(labels: ["com.cliproxymanager.port.8317"])
        let launcher = FakeProcessLauncher(usesManagedLaunchdJobs: true)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            launchctl: launchctl,
            inspectSystemProcesses: false
        )

        let restarted = try await manager.reconcileConfiguration(port: 8317)

        XCTAssertTrue(restarted)
        XCTAssertEqual(launcher.invocations.count, 1)
        XCTAssertEqual(try Data(contentsOf: paths.clipProxyConfigFile), canonical)
    }

    func testRestartStopsExistingProcessBeforeStartingAgain() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let firstProcess = ManagedProxyProcessDouble()
        let secondProcess = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(processes: [firstProcess, secondProcess])
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.restart(port: 9000)

        XCTAssertEqual(firstProcess.terminateCallCount, 1)
        XCTAssertEqual(firstProcess.waitUntilExitCallCount, 1)
        XCTAssertEqual(secondProcess.terminateCallCount, 0)
        XCTAssertEqual(secondProcess.waitUntilExitCallCount, 0)
        XCTAssertEqual(launcher.invocations, [
            FakeProcessLauncher.Invocation(
                executable: paths.clipProxyBinary.path,
                arguments: ["--config", paths.clipProxyConfigFile.path]
            ),
            FakeProcessLauncher.Invocation(
                executable: paths.clipProxyBinary.path,
                arguments: ["--config", paths.clipProxyConfigFile.path]
            )
        ])

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("port: 9000"))
        XCTAssertFalse(config.contains("port: 8317"))
    }

    func testRestartRestoresPreviousConfigAndProcessWhenReplacementLaunchFails() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let originalProcess = ManagedProxyProcessDouble()
        let restoredProcess = ManagedProxyProcessDouble()
        let launcher = SequencedProcessLauncher(outcomes: [
            .process(originalProcess),
            .failure(NSError(domain: "test", code: 1)),
            .process(restoredProcess)
        ])
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            rollbackReadinessProvider: { $0 == 8317 }
        )

        try await manager.start(port: 8317)
        let originalConfig = try Data(contentsOf: paths.clipProxyConfigFile)

        do {
            try await manager.restart(port: 9000)
            XCTFail("Expected restart failure")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .restartFailed(stage: .processLaunch, rollbackSucceeded: true))
            XCTAssertTrue(error.localizedDescription.contains("previous proxy configuration was restored"))
            XCTAssertTrue(error.localizedDescription.contains("Retry Restart Server"))
        }

        XCTAssertEqual(try Data(contentsOf: paths.clipProxyConfigFile), originalConfig)
        XCTAssertEqual(originalProcess.terminateCallCount, 1)
        XCTAssertEqual(originalProcess.waitUntilExitCallCount, 1)
        XCTAssertEqual(launcher.invocations.count, 3)

        try await manager.stop()
        XCTAssertEqual(restoredProcess.terminateCallCount, 1)
    }

    func testRollbackReportsFailureWhenRestoredProcessNeverListens() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let originalProcess = ManagedProxyProcessDouble()
        let restoredProcess = ManagedProxyProcessDouble()
        let launcher = SequencedProcessLauncher(outcomes: [
            .process(originalProcess),
            .failure(NSError(domain: "test", code: 1)),
            .process(restoredProcess)
        ])
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            rollbackReadinessProvider: { _ in false }
        )

        try await manager.start(port: 8317)

        do {
            try await manager.restart(port: 9000)
            XCTFail("Expected restart failure")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .restartFailed(stage: .processLaunch, rollbackSucceeded: false))
            XCTAssertTrue(error.localizedDescription.contains("proxy is stopped"))
        }

        XCTAssertEqual(restoredProcess.terminateCallCount, 1)
        XCTAssertEqual(restoredProcess.waitUntilExitCallCount, 1)
    }

    func testFailedLoopbackMigrationDoesNotRestoreWildcardConfiguration() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let legacyProcess = ManagedProxyProcessDouble()
        let launcher = SequencedProcessLauncher(outcomes: [
            .process(legacyProcess),
            .failure(NSError(domain: "test", code: 1))
        ])
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try "host: \"0.0.0.0\"\nport: 8317\n".write(
            to: paths.clipProxyConfigFile,
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await manager.reconcileConfiguration(port: 8317)
            XCTFail("Expected loopback migration failure")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .restartFailed(stage: .processLaunch, rollbackSucceeded: false))
            XCTAssertTrue(error.localizedDescription.contains("proxy is stopped"))
        }

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("host: \"127.0.0.1\""))
        XCTAssertFalse(config.contains("host: \"0.0.0.0\""))
        XCTAssertEqual(legacyProcess.terminateCallCount, 1)
        XCTAssertEqual(launcher.invocations.count, 2)
    }

    func testConfigGenerationFailureLeavesExistingConfigAndProcessRunning() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(process: process)
        let provider = AppConfigProviderDouble(config: .default)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            appConfigProvider: { try provider.load() }
        )

        try await manager.start(port: 8317)
        let originalConfig = try Data(contentsOf: paths.clipProxyConfigFile)
        provider.error = CocoaError(.fileReadCorruptFile)

        do {
            _ = try await manager.reconcileConfiguration(port: 9000)
            XCTFail("Expected config generation failure")
        } catch let error as ProxyServiceError {
            guard case .writeFailed = error else {
                return XCTFail("Expected writeFailed, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("existing server was left unchanged"))
        }

        XCTAssertEqual(try Data(contentsOf: paths.clipProxyConfigFile), originalConfig)
        XCTAssertEqual(process.terminateCallCount, 0)
        XCTAssertEqual(process.waitUntilExitCallCount, 0)
        XCTAssertEqual(launcher.invocations.count, 1)
    }

    func testRestartWaitsForExistingProcessExitBeforeLaunchingReplacement() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let events = ProxyLifecycleEventLog()
        let firstProcess = ManagedProxyProcessDouble(name: "first", events: events, waitDelay: 0.1)
        let secondProcess = ManagedProxyProcessDouble(name: "second", events: events)
        let launcher = FakeProcessLauncher(processes: [firstProcess, secondProcess], events: events)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try await manager.restart(port: 9000)

        XCTAssertEqual(events.values, ["launch", "first terminate", "first wait", "launch"])
    }

    func testStartRejectsInvalidPortBeforeWritingConfigOrLaunching() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        do {
            try await manager.start(port: 0)
            XCTFail("Expected invalid port error")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .invalidPort(0))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyConfigFile.path))
        XCTAssertEqual(launcher.invocations, [])
    }

    func testStartReportsMissingBinaryBeforeWritingConfigOrLaunching() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected missing binary error")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .missingBinary(paths.clipProxyBinary.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyConfigFile.path))
        XCTAssertEqual(launcher.invocations, [])
    }

    func testStartReportsWriteFailure() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        try FileManager.default.createDirectory(at: paths.clipProxyConfigFile, withIntermediateDirectories: true)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected write failure")
        } catch let error as ProxyServiceError {
            guard case .writeFailed = error else {
                XCTFail("Expected writeFailed, got \(error)")
                return
            }
        }

        XCTAssertEqual(launcher.invocations, [])
    }

    func testStartReportsLaunchFailure() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let launcher = FakeProcessLauncher(error: NSError(domain: "test", code: 1))
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected launch failure")
        } catch let error as ProxyServiceError {
            guard case .launchFailed = error else {
                XCTFail("Expected launchFailed, got \(error)")
                return
            }
        }

        XCTAssertEqual(launcher.invocations.count, 1)
    }

    func testLaunchctlRunnerRemovesSubmittedJobWhenPIDLookupTimesOut() throws {
        var results = Array(
            repeating: LaunchctlCommandResult(exitStatus: 1, stdout: "", stderr: "not found"),
            count: 20
        )
        results.append(LaunchctlCommandResult(exitStatus: 0, stdout: "", stderr: ""))
        let commandRunner = FakeLaunchctlCommandRunner(results: results)
        let launchctl = LaunchctlRunner(commandRunner: commandRunner, sleep: { _ in })

        XCTAssertThrowsError(try launchctl.lookupPID(label: "com.cliproxymanager.port.8317"))

        XCTAssertEqual(commandRunner.invocations.last, ["remove", "com.cliproxymanager.port.8317"])
    }

    func testLaunchctlRunnerRemovesSubmittedJobWhenPIDLookupCommandThrows() throws {
        let commandRunner = ThrowingLaunchctlCommandRunner()
        let launchctl = LaunchctlRunner(commandRunner: commandRunner, sleep: { _ in })

        XCTAssertThrowsError(try launchctl.lookupPID(label: "com.cliproxymanager.port.8317"))

        XCTAssertEqual(commandRunner.invocations, [
            ["list", "com.cliproxymanager.port.8317"],
            ["remove", "com.cliproxymanager.port.8317"]
        ])
    }

    func testLaunchctlRunnerChecksSubmitStatusAndReportsStderr() throws {
        let commandRunner = FakeLaunchctlCommandRunner(results: [
            LaunchctlCommandResult(exitStatus: 5, stdout: "", stderr: "bad label")
        ])
        let launchctl = LaunchctlRunner(commandRunner: commandRunner)

        XCTAssertThrowsError(try launchctl.submit(label: "com.cliproxymanager.port.8317", executable: "/tmp/cliproxyapi", arguments: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("launchctl submit failed with exit code 5"))
            XCTAssertTrue(error.localizedDescription.contains("bad label"))
        }
    }

    func testProcessLauncherUsesStablePortLabelAndRemovesExistingLaunchctlJobBeforeSubmit() throws {
        let sandbox = try makeSandbox()
        let configURL = sandbox.appendingPathComponent("config.yaml")
        try "port: 8317\n".write(to: configURL, atomically: true, encoding: .utf8)
        let commandRunner = FakeLaunchctlCommandRunner(results: [
            LaunchctlCommandResult(exitStatus: 0, stdout: "", stderr: ""),
            LaunchctlCommandResult(exitStatus: 0, stdout: "", stderr: ""),
            LaunchctlCommandResult(exitStatus: 0, stdout: "\"PID\" = 123;\n", stderr: "")
        ])
        let launchctl = LaunchctlRunner(commandRunner: commandRunner, sleep: { _ in })
        let launcher = ProcessLauncher(launchctl: launchctl, processExists: { _ in false })

        _ = try launcher.launch("/tmp/cliproxyapi", ["--config", configURL.path])

        XCTAssertEqual(commandRunner.invocations, [
            ["remove", "com.cliproxymanager.port.8317"],
            ["submit", "-l", "com.cliproxymanager.port.8317", "--", "/tmp/cliproxyapi", "--config", configURL.path],
            ["list", "com.cliproxymanager.port.8317"]
        ])
    }

    func testDetachedProcessWaitUntilExitPollsProcessExistence() {
        let probe = ProcessExistenceProbe(values: [true, true, false])
        let process = DetachedProcess(
            pid: 123,
            label: "com.cliproxymanager.port.8317",
            launchctl: FakeLaunchctl(),
            processExists: { _ in probe.next() },
            sleep: { _ in probe.recordSleep() }
        )

        process.waitUntilExit()

        XCTAssertEqual(probe.sleepCount, 2)
    }

    func testLaunchctlRunnerListsLabelsMatchingPID() throws {
        let commandRunner = FakeLaunchctlCommandRunner(results: [
            LaunchctlCommandResult(
                exitStatus: 0,
                stdout: "56022\t0\tcom.cliproxymanager.runtime.abc\n23098\t0\thomebrew.mxcl.cliproxyapi\n",
                stderr: ""
            )
        ])
        let launchctl = LaunchctlRunner(commandRunner: commandRunner)

        XCTAssertEqual(try launchctl.labels(matchingPID: 56022), ["com.cliproxymanager.runtime.abc"])
        XCTAssertEqual(commandRunner.invocations, [["list"]])
    }

    func testLaunchctlRunnerReturnsOnlyRunningLabelsWithPrefix() throws {
        let commandRunner = FakeLaunchctlCommandRunner(results: [
            LaunchctlCommandResult(
                exitStatus: 0,
                stdout: "56022\t0\tcom.cliproxymanager.port.8317\n-\t0\tcom.cliproxymanager.port.9000\n23098\t0\thomebrew.mxcl.cliproxyapi\n",
                stderr: ""
            )
        ])
        let launchctl = LaunchctlRunner(commandRunner: commandRunner)

        XCTAssertEqual(
            try launchctl.runningLabels(prefix: "com.cliproxymanager.port."),
            ["com.cliproxymanager.port.8317"]
        )
    }

    func testLaunchctlRunnerPreservesSpacesInMatchingLabels() throws {
        let commandRunner = FakeLaunchctlCommandRunner(results: [
            LaunchctlCommandResult(
                exitStatus: 0,
                stdout: "56022\t0\tcom.cliproxymanager.runtime.test label\n",
                stderr: ""
            )
        ])
        let launchctl = LaunchctlRunner(commandRunner: commandRunner)

        XCTAssertEqual(try launchctl.labels(matchingPID: 56022), ["com.cliproxymanager.runtime.test label"])
    }

    func testManagedCliproxyapiCommandRequiresManagedConfigPath() {
        XCTAssertTrue(ProxyServiceManager.isManagedCliproxyapiCommand(
            "/tmp/managed/cliproxyapi --config /tmp/managed/config.yaml",
            binaryPath: "/tmp/managed/cliproxyapi",
            configPath: "/tmp/managed/config.yaml"
        ))
        XCTAssertFalse(ProxyServiceManager.isManagedCliproxyapiCommand(
            "/usr/local/bin/cliproxyapi --config /tmp/other/config.yaml",
            binaryPath: "/tmp/managed/cliproxyapi",
            configPath: "/tmp/managed/config.yaml"
        ))
        XCTAssertFalse(ProxyServiceManager.isManagedCliproxyapiCommand(
            "/tmp/managed/cliproxyapi-old --config /tmp/managed/config.yaml.bak",
            binaryPath: "/tmp/managed/cliproxyapi",
            configPath: "/tmp/managed/config.yaml"
        ))
    }

    func testPrepareFindsManagedListenerOnPortOutsidePersistedAndRequestedPorts() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        try "host: \"0.0.0.0\"\nport: 9000\n".write(
            to: paths.clipProxyConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let launchctl = RunningLabelsLaunchctl(labels: ["com.cliproxymanager.port.8317"])
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(usesManagedLaunchdJobs: true),
            launchctl: launchctl,
            inspectSystemProcesses: false
        )

        XCTAssertThrowsError(try manager.prepare(port: 28_317)) { error in
            XCTAssertEqual(error as? ProxyServiceError, .configurationChangeRequiresRestart)
        }
        XCTAssertEqual(
            try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8),
            "host: \"0.0.0.0\"\nport: 9000\n"
        )
    }

    func testReconcileStopsManagedLaunchdJobOnPortOutsidePersistedAndRequestedPorts() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        try "host: \"0.0.0.0\"\nport: 9000\n".write(
            to: paths.clipProxyConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let launchctl = RunningLabelsLaunchctl(labels: ["com.cliproxymanager.port.8317"])
        let launcher = FakeProcessLauncher(usesManagedLaunchdJobs: true)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            launchctl: launchctl,
            inspectSystemProcesses: false
        )

        let restarted = try await manager.reconcileConfiguration(port: 28_317)

        XCTAssertTrue(restarted)
        XCTAssertTrue(launchctl.removedLabels.contains("com.cliproxymanager.port.8317"))
        XCTAssertEqual(launcher.invocations.count, 1)
        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("host: \"127.0.0.1\""))
        XCTAssertTrue(config.contains("port: 28317"))
    }

    func testPrepareLeavesConfigUnchangedWhenManagedRuntimeInspectionFails() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let existing = "host: \"0.0.0.0\"\nport: 8317\n"
        try existing.write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        let launchctl = RunningLabelsLaunchctl(error: CocoaError(.fileReadUnknown))
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(usesManagedLaunchdJobs: true),
            launchctl: launchctl,
            inspectSystemProcesses: false
        )

        XCTAssertThrowsError(try manager.prepare(port: 8317))

        XCTAssertEqual(try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8), existing)
    }

    func testPrepareDoesNotRestartRunningProxyWhenConfigurationChanged() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let process = ManagedProxyProcessDouble()
        let launcher = FakeProcessLauncher(process: process)
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)
        try "port: 8317\n".write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try manager.prepare(port: 8317)) { error in
            XCTAssertEqual(error as? ProxyServiceError, .configurationChangeRequiresRestart)
            XCTAssertTrue(error.localizedDescription.contains("Restart Server, then retry login"))
        }
        XCTAssertEqual(process.terminateCallCount, 0)
        XCTAssertEqual(process.waitUntilExitCallCount, 0)
        XCTAssertEqual(launcher.invocations.count, 1)
        XCTAssertEqual(
            try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8),
            "port: 8317\n"
        )
    }

    func testPrepareRendersMultipleAPIKeyProfilesPerProvider() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let claudeID = "claude-api-11111111-1111-1111-1111-111111111111"
        let codexID = "codex-api-22222222-2222-2222-2222-222222222222"
        let claudeReference = try XCTUnwrap(SecretReference.apiKeyProfile(claudeID))
        let codexReference = try XCTUnwrap(SecretReference.apiKeyProfile(codexID))
        var config = AppConfig.default
        config.apiKeyProfiles = [
            .legacy(provider: .claude),
            .init(
                id: claudeID,
                provider: .claude,
                secretReference: claudeReference,
                commandName: "claude_personal"
            ),
            .init(
                id: codexID,
                provider: .codex,
                secretReference: codexReference,
                commandName: "codex_work",
                codex: .default
            )
        ]
        let keys: [SecretReference: String] = [
            .claudeAPIKey: "legacy-claude-key",
            claudeReference: "personal-claude-key",
            codexReference: "work-codex-key"
        ]
        let preparedConfig = config
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            apiKeyProvider: { keys[$0] },
            appConfigProvider: { preparedConfig }
        )

        try manager.prepare(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertEqual(yaml.components(separatedBy: "base-url: \"https://api.anthropic.com\"").count - 1, 2)
        XCTAssertTrue(yaml.contains("prefix: \"cpm-claude-api\""))
        XCTAssertTrue(yaml.contains("prefix: \"cpm-\(claudeID)\""))
        XCTAssertTrue(yaml.contains("prefix: \"cpm-\(codexID)\""))
        XCTAssertTrue(yaml.contains("personal-claude-key"))
        XCTAssertTrue(yaml.contains("work-codex-key"))
    }

    func testPrepareSkipsUnreadableAPIKeyProfileWithoutDisablingHealthyProfiles() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let healthyID = "claude-api-11111111-1111-1111-1111-111111111111"
        let unreadableID = "claude-api-22222222-2222-2222-2222-222222222222"
        let healthyReference = try XCTUnwrap(SecretReference.apiKeyProfile(healthyID))
        let unreadableReference = try XCTUnwrap(SecretReference.apiKeyProfile(unreadableID))
        var config = AppConfig.default
        config.apiKeyProfiles = [
            .init(id: healthyID, provider: .claude, secretReference: healthyReference),
            .init(id: unreadableID, provider: .claude, secretReference: unreadableReference)
        ]
        let preparedConfig = config
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            apiKeyProvider: { reference in
                if reference == unreadableReference {
                    throw SecretStoreError.readFailed(reference.rawValue)
                }
                return reference == healthyReference ? "healthy-key" : nil
            },
            appConfigProvider: { preparedConfig }
        )

        try manager.prepare(port: 8317)

        let yaml = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(yaml.contains("prefix: \"cpm-\(healthyID)\""))
        XCTAssertTrue(yaml.contains("healthy-key"))
        XCTAssertFalse(yaml.contains("prefix: \"cpm-\(unreadableID)\""))
    }

    func testBlockedStartDoesNotStageConfigurationOrLaunch() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            compatibilityAuthorizer: CompatibilityAuthorizerDouble(blockedActions: [.startProxy])
        )

        do {
            try await manager.start(port: 8317)
            XCTFail("Expected compatibility block")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .compatibilityBlocked(.unsupportedArchitecture))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.clipProxyConfigFile.path))
        XCTAssertEqual(launcher.invocations, [])
    }

    func testBlockedRestartLeavesRunningProxyUntouched() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let launcher = FakeProcessLauncher()
        let authorizer = CompatibilityAuthorizerDouble()
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: launcher,
            compatibilityAuthorizer: authorizer
        )
        try await manager.start(port: 8317)
        authorizer.blockedActions = [.restartProxy]

        do {
            try await manager.restart(port: 8317)
            XCTFail("Expected compatibility block")
        } catch let error as ProxyServiceError {
            XCTAssertEqual(error, .compatibilityBlocked(.unsupportedArchitecture))
        }

        XCTAssertEqual(launcher.invocations.count, 1)
        XCTAssertEqual(try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8).contains("port: 8317"), true)
    }

    func testBlockedOAuthPreparationLeavesConfigurationUnchanged() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary)
        let existing = "host: \"127.0.0.1\"\nport: 8317\n"
        try existing.write(to: paths.clipProxyConfigFile, atomically: true, encoding: .utf8)
        let manager = ProxyServiceManager(
            paths: paths,
            launcher: FakeProcessLauncher(),
            compatibilityAuthorizer: CompatibilityAuthorizerDouble(blockedActions: [.prepareOAuthLogin])
        )

        XCTAssertThrowsError(try manager.prepare(port: 8317)) { error in
            XCTAssertEqual(error as? ProxyServiceError, .compatibilityBlocked(.unsupportedArchitecture))
        }
        XCTAssertEqual(try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8), existing)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func createBinary(at url: URL, contents: String = "#!/bin/sh\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func writeBundledManifest(for binaryURL: URL, version: String, in sandbox: URL) throws -> URL {
        let manifestURL = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        let manifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: version,
            commit: "bundled-\(version)",
            builtAt: "2026-06-25T17:56:53Z",
            sourceKind: .bundled,
            source: "https://example.com/bundled.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v\(version)",
            upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: try Data(contentsOf: binaryURL).sha256HexDigest(),
            vendoredBinarySizeBytes: try XCTUnwrap(binaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            vendoredFromArchivePath: "cli-proxy-api"
        )
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return manifestURL
    }

    private func XCTAssertEventuallyEqual<T: Equatable>(
        _ expression: @autoclosure () -> T,
        _ expected: T,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var value = expression()
        while value != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            value = expression()
        }
        XCTAssertEqual(value, expected, file: file, line: line)
    }
}

private final class CompatibilityAuthorizerDouble: RuntimeCompatibilityAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlockedActions: Set<CompatibilityAction>

    var blockedActions: Set<CompatibilityAction> {
        get { lock.withLock { storedBlockedActions } }
        set { lock.withLock { storedBlockedActions = newValue } }
    }

    init(blockedActions: Set<CompatibilityAction> = []) {
        storedBlockedActions = blockedActions
    }

    func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        let blocked = blockedActions
        return RuntimeCompatibilityReport(
            findings: blocked.isEmpty
                ? []
                : [.unsupportedArchitecture(expected: .arm64, actual: .x86_64)],
            decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
                (action, CompatibilityDecision(
                    action: action,
                    disposition: blocked.contains(action) ? .blocked : .allowed
                ))
            })
        )
    }

    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        staticReport(artifacts: artifacts)
    }

    func require(_ action: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {
        if blockedActions.contains(action) {
            throw RuntimeCompatibilityError.actionBlocked(action)
        }
    }
}

private final class ProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class ProcessExistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    private var _sleepCount = 0

    var sleepCount: Int {
        lock.withLock { _sleepCount }
    }

    init(values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.withLock { values.removeFirst() }
    }

    func recordSleep() {
        lock.withLock { _sleepCount += 1 }
    }
}

private final class ThrowingLaunchctlCommandRunner: LaunchctlCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocations: [[String]] = []

    var invocations: [[String]] {
        lock.withLock { storedInvocations }
    }

    func run(_ arguments: [String]) throws -> LaunchctlCommandResult {
        try lock.withLock {
            storedInvocations.append(arguments)
            if arguments.first == "list" {
                throw CocoaError(.fileReadUnknown)
            }
            return LaunchctlCommandResult(exitStatus: 0, stdout: "", stderr: "")
        }
    }
}

private final class FakeLaunchctlCommandRunner: LaunchctlCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [LaunchctlCommandResult]
    private var _invocations: [[String]] = []

    var invocations: [[String]] {
        lock.withLock { _invocations }
    }

    init(results: [LaunchctlCommandResult]) {
        self.results = results
    }

    func run(_ arguments: [String]) throws -> LaunchctlCommandResult {
        lock.withLock {
            _invocations.append(arguments)
            return results.removeFirst()
        }
    }
}

private struct FakeLaunchctl: LaunchctlManaging {
    func remove(label: String) throws {}
    func submit(label: String, executable: String, arguments: [String]) throws {}
    func lookupPID(label: String) throws -> pid_t { 123 }
    func labels(matchingPID pid: pid_t) throws -> [String] { [] }
}

private final class RunningLabelsLaunchctl: LaunchctlManaging, @unchecked Sendable {
    private let labels: [String]
    private let error: Error?
    private let lock = NSLock()
    private var storedRemovedLabels: [String] = []

    var removedLabels: [String] {
        lock.withLock { storedRemovedLabels }
    }

    init(labels: [String] = [], error: Error? = nil) {
        self.labels = labels
        self.error = error
    }

    func remove(label: String) throws {
        lock.withLock { storedRemovedLabels.append(label) }
    }
    func submit(label: String, executable: String, arguments: [String]) throws {}
    func lookupPID(label: String) throws -> pid_t { 123 }
    func labels(matchingPID pid: pid_t) throws -> [String] { [] }
    func runningLabels(prefix: String) throws -> [String] {
        if let error { throw error }
        return labels.filter { $0.hasPrefix(prefix) }
    }
}

private final class AppConfigProviderDouble: @unchecked Sendable {
    private let lock = NSLock()
    private let config: AppConfig
    private var storedError: Error?

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    init(config: AppConfig) {
        self.config = config
    }

    func load() throws -> AppConfig {
        try lock.withLock {
            if let storedError { throw storedError }
            return config
        }
    }
}

private final class SequencedProcessLauncher: ProcessLaunching, @unchecked Sendable {
    let usesManagedLaunchdJobs = false
    enum Outcome {
        case process(any ManagedProxyProcess)
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var storedInvocations: [FakeProcessLauncher.Invocation] = []

    var invocations: [FakeProcessLauncher.Invocation] {
        lock.withLock { storedInvocations }
    }

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        try lock.withLock {
            storedInvocations.append(.init(executable: executable, arguments: arguments))
            guard !outcomes.isEmpty else {
                throw NSError(
                    domain: "SequencedProcessLauncher",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unexpected launch #\(storedInvocations.count); no outcome was provided."
                    ]
                )
            }
            switch outcomes.removeFirst() {
            case .process(let process):
                return process
            case .failure(let error):
                throw error
            }
        }
    }
}

private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    let usesManagedLaunchdJobs: Bool
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let error: Error?
    private let events: ProxyLifecycleEventLog?
    private let lock = NSLock()
    private var processes: [any ManagedProxyProcess]
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(
        error: Error? = nil,
        process: any ManagedProxyProcess = ManagedProxyProcessDouble(),
        events: ProxyLifecycleEventLog? = nil,
        usesManagedLaunchdJobs: Bool = false
    ) {
        self.usesManagedLaunchdJobs = usesManagedLaunchdJobs
        self.error = error
        self.events = events
        self.processes = [process]
    }

    init(
        error: Error? = nil,
        processes: [any ManagedProxyProcess],
        events: ProxyLifecycleEventLog? = nil,
        usesManagedLaunchdJobs: Bool = false
    ) {
        self.usesManagedLaunchdJobs = usesManagedLaunchdJobs
        self.error = error
        self.events = events
        self.processes = processes
    }

    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        events?.append("launch")
        if let error {
            throw error
        }
        return lock.withLock { processes.removeFirst() }
    }
}

private final class ManagedProxyProcessDouble: ManagedProxyProcess, @unchecked Sendable {
    private let name: String?
    private let events: ProxyLifecycleEventLog?
    private let lock = NSLock()
    private var _terminateCallCount = 0
    private var _waitUntilExitCallCount = 0
    private let waitDelay: TimeInterval

    var terminateCallCount: Int {
        lock.withLock { _terminateCallCount }
    }

    var waitUntilExitCallCount: Int {
        lock.withLock { _waitUntilExitCallCount }
    }

    init(name: String? = nil, events: ProxyLifecycleEventLog? = nil, waitDelay: TimeInterval = 0) {
        self.name = name
        self.events = events
        self.waitDelay = waitDelay
    }

    func terminate() {
        lock.withLock { _terminateCallCount += 1 }
        if let name {
            events?.append("\(name) terminate")
        }
    }

    func waitUntilExit() {
        if waitDelay > 0 {
            Thread.sleep(forTimeInterval: waitDelay)
        }
        lock.withLock { _waitUntilExitCallCount += 1 }
        if let name {
            events?.append("\(name) wait")
        }
    }
}

private final class ProxyLifecycleEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.withLock { _values }
    }

    func append(_ value: String) {
        lock.withLock { _values.append(value) }
    }
}


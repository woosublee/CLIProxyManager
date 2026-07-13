import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
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
            subscriptionUsageEnabledProvider: { true }
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
            subscriptionUsageEnabledProvider: { true }
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
            subscriptionUsageEnabledProvider: { true }
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
            subscriptionUsageEnabledProvider: { false }
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
            subscriptionUsageEnabledProvider: { true }
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

        try await manager.start(port: 18_317)
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

private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
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
        events: ProxyLifecycleEventLog? = nil
    ) {
        self.error = error
        self.events = events
        self.processes = [process]
    }

    init(error: Error? = nil, processes: [any ManagedProxyProcess], events: ProxyLifecycleEventLog? = nil) {
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


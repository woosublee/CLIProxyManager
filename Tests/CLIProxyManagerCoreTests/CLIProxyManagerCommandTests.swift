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
        XCTAssertTrue(output.stdout[0].contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-a/gpt-5.5(xhigh)'"))
        XCTAssertTrue(output.stdout[0].contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-a.json'"))
    }

    func testQuotaKeyStatusAndSetDoNotPrintKey() async throws {
        let sandbox = try makeSandbox()
        let configStore = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        try configStore.save(.default)
        let output = OutputDouble(isInteractive: false)
        let keyStore = CommandManagementKeyStore()
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

        XCTAssertEqual(output.stdout, ["Management key stored.\n", "configured=true\n"])
        XCTAssertFalse(output.stdout.joined().contains("management-key-value"))
        XCTAssertTrue(try configStore.load().subscriptionUsage.isEnabled)
        XCTAssertEqual(services.calls, [.proxyStatus])
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

private final class CommandManagementKeyStore: SubscriptionUsageManagementKeyConfiguring, @unchecked Sendable {
    private var key: String?

    func isConfigured() -> Bool { key != nil }
    func setManagementKey(_ value: String) throws { key = value }
    func deleteManagementKey() throws { key = nil }
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

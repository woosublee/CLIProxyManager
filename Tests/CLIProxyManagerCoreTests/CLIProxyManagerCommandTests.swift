import XCTest
@testable import CLIProxyManagerCore

final class CLIProxyManagerCommandTests: XCTestCase {
    func testSecretGetStillPrintsSecret() throws {
        let output = OutputCollector()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(values: [.claudeAPIKey: "secret-value"]),
            output: { @Sendable line in output.append(line) }
        )

        try command.run(arguments: ["secret", "get", "claude-api-key"])

        XCTAssertEqual(output.value, "secret-value\n")
    }

    func testRoutingNextPrintsShellAssignments() throws {
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
        let output = OutputCollector()
        let command = CLIProxyManagerCommand(
            secretStore: InMemorySecretStore(),
            configStore: configStore,
            authProfileStore: AuthProfileStore(authDirectory: authDirectory),
            stateSelector: RoundRobinStateStore(stateFile: sandbox.appendingPathComponent("round-robin-state.json")),
            output: { @Sendable line in output.append(line) }
        )

        try command.run(arguments: ["routing", "next", "codex-default"])

        XCTAssertTrue(output.value.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-a/gpt-5.5(xhigh)'"))
        XCTAssertTrue(output.value.contains("CLIPROXY_ROUND_ROBIN_PROFILE='codex-a.json'"))
    }

    func testUnknownArgumentsThrowUsage() {
        let command = CLIProxyManagerCommand(secretStore: InMemorySecretStore())

        XCTAssertThrowsError(try command.run(arguments: ["routing"])) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .usage)
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

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage += line + "\n"
        lock.unlock()
    }
}

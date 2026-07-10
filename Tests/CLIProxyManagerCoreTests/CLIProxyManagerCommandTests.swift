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

    func testUnknownArgumentsStillThrowUsage() async {
        let command = CLIProxyManagerCommand(output: OutputDouble(isInteractive: false))

        await XCTAssertThrowsErrorAsync(try await command.run(arguments: ["unknown"])) { error in
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

import XCTest
@testable import CLIProxyManagerCore

final class AppConfigStoreTests: XCTestCase {
    func testDefaultConfigUsesAppManagedPortAndFunctionNames() {
        let config = AppConfig.default

        XCTAssertEqual(config.port, 18_317)
        XCTAssertEqual(config.commands.cc, "cc")
        XCTAssertEqual(config.commands.ccapi, "ccapi")
        XCTAssertEqual(config.commands.ccodex, "ccodex")
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
        XCTAssertEqual(config.ccodex.opus, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .auto))
        XCTAssertEqual(config.ccodex.sonnet, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .auto))
        XCTAssertEqual(config.ccodex.haiku, AppConfig.CodexRole(model: "gpt-5.5", reasoning: .low, contextWindow: .auto))
    }

    func testStoreReturnsDefaultWhenConfigFileDoesNotExist() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))

        let config = try store.load()

        XCTAssertEqual(config, .default)
    }

    func testStoreSavesAndLoadsConfig() throws {
        let sandbox = try makeSandbox()
        let store = AppConfigStore(paths: ManagedPaths(rootDirectory: sandbox))
        let config = AppConfig(
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

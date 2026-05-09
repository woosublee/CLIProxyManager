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

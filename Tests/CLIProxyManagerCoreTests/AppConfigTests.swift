import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDefaultConfigMatchesMVPDecisions() {
        let config = AppConfig.default

        XCTAssertEqual(config.port, 8317)
        XCTAssertEqual(config.commands.cc, "cc")
        XCTAssertEqual(config.commands.ccapi, "ccapi")
        XCTAssertEqual(config.commands.ccodex, "ccodex")
        XCTAssertEqual(config.ccapi.model, "claude-opus-4-7")
        XCTAssertEqual(config.ccodex.opusModel, "gpt-5.5(xhigh)")
        XCTAssertEqual(config.ccodex.sonnetModel, "gpt-5.5(xhigh)")
        XCTAssertEqual(config.ccodex.haikuModel, "gpt-5.5(low)")
        XCTAssertFalse(config.includeDangerouslySkipPermissions)
    }

    func testManagedPathsCanBeRootedInTemporaryDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)

        XCTAssertEqual(paths.rootDirectory, root)
        XCTAssertEqual(paths.functionsFile, root.appendingPathComponent("functions.zsh"))
        XCTAssertEqual(paths.configFile, root.appendingPathComponent("config.json"))
        XCTAssertEqual(paths.logsDirectory, root.appendingPathComponent("logs"))
        XCTAssertEqual(paths.clipProxyDirectory, root.appendingPathComponent("cliproxyapi"))
    }
}

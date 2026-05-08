import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testStartWritesCompatibleConfigAndRunsBinaryWithConfigPath() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let runner = FakeProcessRunner()
        let manager = ProxyServiceManager(paths: paths, runner: runner)

        _ = await manager.start(port: 8317)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.clipProxyDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("port: 8317"))
        XCTAssertTrue(config.contains("auth-dir: \"~/.cli-proxy-api\""))
        XCTAssertTrue(config.contains("logging-to-file: true"))
        XCTAssertTrue(config.contains("debug: false"))
        XCTAssertTrue(config.contains("api-keys:"))
        XCTAssertTrue(config.contains("  - sk-dummy"))

        XCTAssertEqual(runner.invocations, [
            FakeProcessRunner.Invocation(
                executable: paths.clipProxyBinary.path,
                arguments: ["--config", paths.clipProxyConfigFile.path]
            )
        ])
    }

    func testStartDoesNotUseRealHomeWhenPathsUseTemporaryRoot() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let runner = FakeProcessRunner()
        let manager = ProxyServiceManager(paths: paths, runner: runner)

        _ = await manager.start(port: 9000)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains(paths.clipProxyDirectory.path) == false)
        XCTAssertTrue(config.contains(FileManager.default.homeDirectoryForCurrentUser.path) == false)
        XCTAssertEqual(runner.invocations.first?.executable, paths.clipProxyBinary.path)
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

private final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testStartWritesCompatibleConfigAndLaunchesBinaryWithConfigPath() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 8317)

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

        XCTAssertEqual(launcher.invocations, [
            FakeProcessLauncher.Invocation(
                executable: paths.clipProxyBinary.path,
                arguments: ["--config", paths.clipProxyConfigFile.path]
            )
        ])
    }

    func testStartDoesNotUseRealHomeWhenPathsUseTemporaryRoot() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, launcher: launcher)

        try await manager.start(port: 9000)

        let config = try String(contentsOf: paths.clipProxyConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains(paths.clipProxyDirectory.path) == false)
        XCTAssertTrue(config.contains(FileManager.default.homeDirectoryForCurrentUser.path) == false)
        XCTAssertEqual(launcher.invocations.first?.executable, paths.clipProxyBinary.path)
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

    func testStartReportsWriteFailure() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try FileManager.default.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        try Data().write(to: paths.clipProxyDirectory)
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

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }
}

private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let error: Error?
    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func launch(_ executable: String, _ arguments: [String]) throws {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        if let error {
            throw error
        }
    }
}

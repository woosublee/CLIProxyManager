import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
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

    func testStartCopiesBundledBinaryWhenManagedBinaryIsMissing() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho bundled\n")
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, launcher: launcher)

        try await manager.start(port: 8317)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.clipProxyBinary.path))
        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho bundled\n")
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
        XCTAssertEqual(process.waitUntilExitCallCount, 1)
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
}

private final class FakeProcessLauncher: ProcessLaunching, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let error: Error?
    private let process: any ManagedProxyProcess
    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    init(error: Error? = nil, process: any ManagedProxyProcess = ManagedProxyProcessDouble()) {
        self.error = error
        self.process = process
    }

    func launch(_ executable: String, _ arguments: [String]) throws -> any ManagedProxyProcess {
        lock.withLock { _invocations.append(Invocation(executable: executable, arguments: arguments)) }
        if let error {
            throw error
        }
        return process
    }
}

private final class ManagedProxyProcessDouble: ManagedProxyProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminateCallCount = 0
    private var _waitUntilExitCallCount = 0

    var terminateCallCount: Int {
        lock.withLock { _terminateCallCount }
    }

    var waitUntilExitCallCount: Int {
        lock.withLock { _waitUntilExitCallCount }
    }

    func terminate() {
        lock.withLock { _terminateCallCount += 1 }
    }

    func waitUntilExit() {
        lock.withLock { _waitUntilExitCallCount += 1 }
    }
}

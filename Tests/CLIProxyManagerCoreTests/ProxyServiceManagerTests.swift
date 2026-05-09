import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyServiceManagerTests: XCTestCase {
    func testManagedPathsExposeAppManagedAuthDirectory() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))

        XCTAssertEqual(paths.authDirectory, sandbox.appendingPathComponent("managed/auth", isDirectory: true))
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

    func testStartReplacesManagedBinaryWhenBundledBinaryChanges() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try createBinary(at: paths.clipProxyBinary, contents: "#!/bin/sh\necho old\n")
        let bundledBinary = sandbox.appendingPathComponent("bundle/cliproxyapi")
        try createBinary(at: bundledBinary, contents: "#!/bin/sh\necho new\n")
        let launcher = FakeProcessLauncher()
        let manager = ProxyServiceManager(paths: paths, bundledBinaryURL: bundledBinary, launcher: launcher)

        try await manager.start(port: 8317)

        XCTAssertEqual(try String(contentsOf: paths.clipProxyBinary, encoding: .utf8), "#!/bin/sh\necho new\n")
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


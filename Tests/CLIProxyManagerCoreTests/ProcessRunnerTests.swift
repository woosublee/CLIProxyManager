import XCTest
@testable import CLIProxyManagerCore

final class ProcessRunnerTests: XCTestCase {
    func testForceTerminationGracePeriodAllowsProcessCleanup() {
        XCTAssertEqual(ProcessRunner.forceTerminationGracePeriod, 0.5)
    }

    func testDrainsLargeStdoutAndStderr() async throws {
        let runner = ProcessRunner(timeout: 5)
        let program = "BEGIN { for (i = 0; i < 100000; i++) printf \"x\"; for (i = 0; i < 100000; i++) printf \"y\" > \"/dev/stderr\" }"

        let result = await runner.run("/usr/bin/awk", [program])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 100_000)
        XCTAssertEqual(result.stderr.count, 100_000)
    }

    func testTimesOutLongRunningProcess() async throws {
        let runner = ProcessRunner(timeout: 0.1)
        let start = Date()

        let result = await runner.run("/bin/sh", ["-c", "sleep 2"])

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testInvalidExecutableReturnsFailure() async throws {
        let runner = ProcessRunner(timeout: 0.1)

        let result = await runner.run("/definitely/not/a/real/executable", [])

        XCTAssertEqual(result.exitCode, 127)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    func testTimeoutTerminatesBackgroundChildProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("child-finished")
        let runner = ProcessRunner(timeout: 0.1)

        let result = await runner.run("/bin/sh", ["-c", "(sleep 1; touch '\(marker.path)') & sleep 5"])
        try await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReturnsWithoutWaitingForChildThatKeepsStdoutOpen() async throws {
        let runner = ProcessRunner(timeout: 5)
        let start = Date()

        let result = await runner.run("/bin/sh", ["-c", "(sleep 2) & printf done"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testCancellationTerminatesRunningProcessGroup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("child-finished")
        let runner = ProcessRunner(timeout: 5)

        let task = Task {
            await runner.run("/bin/sh", ["-c", "(sleep 1; touch '\(marker.path)') & sleep 5"])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value
        try await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

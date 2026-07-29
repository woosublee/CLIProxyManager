import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyLogServiceTests: XCTestCase {
    func testReadsMainLogLastWhenItExists() throws {
        let paths = try makePaths()
        try write("one\ntwo\nthree\n", to: paths.proxyLogsDirectory.appendingPathComponent("main.log"))
        try write("newest-but-not-main\n", to: paths.proxyLogsDirectory.appendingPathComponent("error-new.log"))

        let snapshot = try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(2)

        XCTAssertEqual(snapshot.fileURL.lastPathComponent, "main.log")
        XCTAssertEqual(snapshot.text, "two\nthree\n")
    }

    func testFallsBackToMostRecentlyModifiedRegularLog() throws {
        let paths = try makePaths()
        try write("old\n", to: paths.proxyLogsDirectory.appendingPathComponent("old.log"), modifiedAt: .distantPast)
        try write("new\n", to: paths.proxyLogsDirectory.appendingPathComponent("new.log"), modifiedAt: .now)

        let snapshot = try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(200)

        XCTAssertEqual(snapshot.fileURL.lastPathComponent, "new.log")
    }

    func testRejectsSymlinkCandidateOutsideManagedLogs() throws {
        let paths = try makePaths()
        let outside = paths.rootDirectory.appendingPathComponent("secret.log")
        try write("private", to: outside)
        try FileManager.default.createSymbolicLink(
            at: paths.proxyLogsDirectory.appendingPathComponent("main.log"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(10))
    }

    func testReadLastLinesRespectsCount() throws {
        let paths = try makePaths()
        try write("a\nb\nc\nd\ne\n", to: paths.proxyLogsDirectory.appendingPathComponent("main.log"))

        let snapshot = try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(3)

        XCTAssertEqual(snapshot.text, "c\nd\ne\n")
    }

    func testSelectedLogFileExposesSameSafeSelectionUsedByCLI() throws {
        let paths = try makePaths()
        let mainLog = paths.proxyLogsDirectory.appendingPathComponent("main.log")
        try write("line\n", to: mainLog)

        XCTAssertEqual(
            try ProxyLogService(paths: paths, follower: FollowerDouble())
                .selectedLogFile()
                .resolvingSymlinksInPath(),
            mainLog.resolvingSymlinksInPath()
        )
    }

    func testFollowUsesSelectedLogFile() throws {
        let paths = try makePaths()
        try write("line\n", to: paths.proxyLogsDirectory.appendingPathComponent("main.log"))
        let follower = FollowerDouble()

        try ProxyLogService(paths: paths, follower: follower).follow()

        XCTAssertEqual(follower.followedURLs.map { $0.lastPathComponent }, ["main.log"])
    }

    func testThrowsWhenNoLogFiles() throws {
        let paths = try makePaths()
        XCTAssertThrowsError(try ProxyLogService(paths: paths, follower: FollowerDouble()).readLastLines(10)) { error in
            guard let cmdError = error as? CLIProxyManagerCommandError,
                  case .operation = cmdError else {
                XCTFail("Expected operation error, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: paths.proxyLogsDirectory, withIntermediateDirectories: true)
        return paths
    }

    private func write(_ text: String, to url: URL, modifiedAt date: Date? = nil) throws {
        try Data(text.utf8).write(to: url)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Test doubles

private final class FollowerDouble: LogFollowing, @unchecked Sendable {
    private(set) var followedURLs: [URL] = []

    func follow(fileURL: URL) throws {
        followedURLs.append(fileURL)
    }
}

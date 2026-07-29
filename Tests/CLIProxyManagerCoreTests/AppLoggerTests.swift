import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppLoggerTests: XCTestCase {
    func testInfoThresholdFiltersDebugUntilConfigurationChanges() {
        let fileWriter = RecordingFileWriter()
        let fallback = RecordingSink()
        let logger = AppLogger(
            minimumLevel: .info,
            fileWriter: fileWriter,
            fallbackSink: fallback,
            now: { Date(timeIntervalSince1970: 1) }
        )

        logger.record(.debug(.proxyRestartQueued))
        logger.record(.applicationLaunch(.succeeded))
        logger.configure(minimumLevel: .debug)
        logger.record(.debug(.proxyRestartQueued))
        logger.configure(minimumLevel: .info)
        logger.record(.debug(.proxyRestartApplied))

        XCTAssertEqual(fileWriter.entries.map(\.event), [
            .applicationLaunch(.succeeded),
            .debug(.proxyRestartQueued)
        ])
        XCTAssertEqual(fallback.entries, fileWriter.entries)
        XCTAssertEqual(logger.minimumLevel, .info)
    }

    func testTypedEventRenderingContainsOnlyAllowlistedFields() {
        let entry = AppLogEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .info,
            event: .update(target: .proxy, action: .apply, result: .failed(.updateVerification))
        )

        XCTAssertTrue(entry.line.contains("level=info"))
        XCTAssertTrue(entry.line.contains("category=update"))
        XCTAssertTrue(entry.line.contains("target=proxy"))
        XCTAssertTrue(entry.line.contains("failure=update-verification"))
        for forbidden in [
            "secret@example.com",
            "oauth-token-fixture",
            "management-key-fixture",
            "private prompt fixture",
            "raw-response-fixture"
        ] {
            XCTAssertFalse(entry.line.contains(forbidden))
        }
    }

    func testFileStoreCreatesOwnerOnlyDirectoryAndFile() throws {
        let paths = try makePaths()
        let store = AppLogFileStore(paths: paths)

        try store.prepare()
        try store.write(AppLogEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .info,
            event: .applicationLaunch(.succeeded)
        ))

        XCTAssertEqual(permissions(at: paths.logsDirectory), 0o700)
        XCTAssertEqual(permissions(at: paths.appLogFile), 0o600)
        let contents = try String(contentsOf: paths.appLogFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("category=application event=launch result=succeeded"))
    }

    func testValidatedExistingLogFileRequiresSafeOwnerOnlyRegularFile() throws {
        let paths = try makePaths()
        let store = AppLogFileStore(paths: paths)
        try store.prepare()

        XCTAssertEqual(
            try AppLogFileStore.validatedExistingLogFile(at: paths.appLogFile)
                .resolvingSymlinksInPath(),
            paths.appLogFile.resolvingSymlinksInPath()
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: paths.appLogFile.path
        )
        XCTAssertThrowsError(try AppLogFileStore.validatedExistingLogFile(at: paths.appLogFile))
    }

    func testFileStoreRotatesToOneBackupBeforeSizeLimitIsExceeded() throws {
        let paths = try makePaths()
        let store = AppLogFileStore(paths: paths, maximumFileSize: 180)
        let entry = AppLogEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .info,
            event: .server(action: .restart, result: .succeeded, port: 18_318)
        )

        try store.write(entry)
        try store.write(entry)
        try store.write(entry)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appLogFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.rotatedAppLogFile.path))
        XCTAssertLessThanOrEqual(fileSize(at: paths.appLogFile), 180)
        XCTAssertLessThanOrEqual(fileSize(at: paths.rotatedAppLogFile), 180)
        XCTAssertEqual(permissions(at: paths.appLogFile), 0o600)
    }

    func testFileStoreRejectsSymlinkLogFileWithoutChangingTarget() throws {
        let paths = try makePaths()
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        let outside = paths.rootDirectory.appendingPathComponent("outside.log")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: paths.appLogFile, withDestinationURL: outside)
        let fallback = RecordingSink()

        let logger = AppLogger(
            fileWriter: AppLogFileStore(paths: paths),
            fallbackSink: fallback
        )
        logger.record(.configurationSave(.succeeded))

        XCTAssertEqual(
            logger.diagnostics,
            .degraded(fileURL: paths.appLogFile, reason: .unsafeFile)
        )
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "unchanged")
        XCTAssertEqual(fallback.entries.map(\.event), [.configurationSave(.succeeded)])
    }

    func testFileStoreRejectsSymlinkLogsDirectory() throws {
        let paths = try makePaths()
        let outside = paths.rootDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.logsDirectory, withDestinationURL: outside)

        XCTAssertThrowsError(try AppLogFileStore(paths: paths).prepare()) { error in
            XCTAssertEqual(error as? AppLogFileError, .unsafeDirectory)
        }
    }

    func testWriteFailureUsesFallbackAndReportsDegradedDiagnostics() {
        let fileURL = URL(fileURLWithPath: "/tmp/app-logger-test.log")
        let fileWriter = ThrowingFileWriter(fileURL: fileURL)
        let fallback = RecordingSink()
        let logger = AppLogger(fileWriter: fileWriter, fallbackSink: fallback)

        logger.record(.server(action: .start, result: .failed(.process), port: 18_318))

        XCTAssertEqual(
            logger.diagnostics,
            .degraded(fileURL: fileURL, reason: .writeFailed)
        )
        XCTAssertEqual(fallback.entries.map(\.event), [
            .server(action: .start, result: .failed(.process), port: 18_318)
        ])
    }

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ManagedPaths(rootDirectory: root)
    }

    private func permissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func fileSize(at url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue) ?? 0
    }
}

private final class RecordingSink: AppLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [AppLogEntry] = []

    var entries: [AppLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func write(_ entry: AppLogEntry) {
        lock.lock()
        storedEntries.append(entry)
        lock.unlock()
    }
}

private final class RecordingFileWriter: AppLogFileWriting, @unchecked Sendable {
    let fileURL = URL(fileURLWithPath: "/tmp/recording-app.log")
    private let sink = RecordingSink()

    var entries: [AppLogEntry] { sink.entries }

    func prepare() {}
    func write(_ entry: AppLogEntry) { sink.write(entry) }
}

private struct ThrowingFileWriter: AppLogFileWriting {
    let fileURL: URL

    func prepare() throws {
        throw AppLogFileError.writeFailed
    }

    func write(_: AppLogEntry) throws {
        throw AppLogFileError.writeFailed
    }
}

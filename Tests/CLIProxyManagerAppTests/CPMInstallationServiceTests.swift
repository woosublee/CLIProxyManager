import CryptoKit
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class CPMInstallationServiceTests: XCTestCase {
    func testStatusIsNotInstalledWhenTargetAndRecordAreAbsent() throws {
        let fixture = try Fixture()
        let service = fixture.makeService()

        XCTAssertEqual(service.status(), .notInstalled)
    }

    func testInstallRecordsDigestAndReportsCurrent() async throws {
        let fixture = try Fixture()
        let runner = CopyingPrivilegedRunner()
        let service = fixture.makeService(runner: runner)

        try await service.installOrUpdate()

        XCTAssertEqual(runner.actions, [.install])
        XCTAssertEqual(service.status(), .installedCurrent(version: "0.1.13"))
        XCTAssertEqual(try Data(contentsOf: fixture.target), try Data(contentsOf: fixture.source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.cpmInstallationRecordFile.path))
    }

    func testStatusRemainsCurrentWhenBundledHelperChangesWithoutRevisionChange() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner(), currentRevision: 1)
        try await service.installOrUpdate()
        try Data("rebuilt cpm".utf8).write(to: fixture.source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.source.path)

        XCTAssertEqual(service.status(), .installedCurrent(version: "0.1.13"))
    }

    func testStatusReportsOutdatedWhenBundledRevisionIncreases() async throws {
        let fixture = try Fixture()
        try await fixture.makeService(
            runner: CopyingPrivilegedRunner(),
            bundledVersion: "0.1.13",
            currentRevision: 1
        ).installOrUpdate()

        let newer = fixture.makeService(
            bundledVersion: "0.1.14",
            currentRevision: 2
        )

        XCTAssertEqual(
            newer.status(),
            .installedOutdated(installedVersion: "0.1.13", availableVersion: "0.1.14")
        )
    }

    func testStatusKeepsNewerInstalledRevisionCurrent() async throws {
        let fixture = try Fixture()
        try await fixture.makeService(
            runner: CopyingPrivilegedRunner(),
            bundledVersion: "0.1.14",
            currentRevision: 2
        ).installOrUpdate()

        let olderBundle = fixture.makeService(
            bundledVersion: "0.1.13",
            currentRevision: 1
        )

        XCTAssertEqual(olderBundle.status(), .installedCurrent(version: "0.1.14"))
    }

    func testLegacyRecordWithoutRevisionRequiresOneUpdate() throws {
        let fixture = try Fixture()
        try Data("installed cpm".utf8).write(to: fixture.target)
        let digest = try fixture.sha256(of: fixture.target)
        try FileManager.default.createDirectory(
            at: fixture.paths.rootDirectory,
            withIntermediateDirectories: true
        )
        let legacy = """
        {"digest":"\(digest)","version":"0.1.15"}
        """
        try Data(legacy.utf8).write(to: fixture.paths.cpmInstallationRecordFile)

        XCTAssertEqual(
            fixture.makeService(bundledVersion: "0.1.17", currentRevision: 1).status(),
            .installedOutdated(installedVersion: "0.1.15", availableVersion: "0.1.17")
        )
    }

    func testRecordWithoutVersionAllowsOneUpdateWhenDigestMatches() throws {
        let fixture = try Fixture()
        try Data("installed cpm".utf8).write(to: fixture.target)
        let digest = try fixture.sha256(of: fixture.target)
        try FileManager.default.createDirectory(
            at: fixture.paths.rootDirectory,
            withIntermediateDirectories: true
        )
        let record = """
        {"digest":"\(digest)"}
        """
        try Data(record.utf8).write(to: fixture.paths.cpmInstallationRecordFile)

        XCTAssertEqual(
            fixture.makeService(bundledVersion: "0.1.17", currentRevision: 1).status(),
            .installedOutdated(installedVersion: "Unknown", availableVersion: "0.1.17")
        )
    }

    func testInstallRecordsAppVersionAndCompatibilityRevision() async throws {
        let fixture = try Fixture()
        try await fixture.makeService(
            runner: CopyingPrivilegedRunner(),
            bundledVersion: "0.1.17",
            currentRevision: 3
        ).installOrUpdate()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.paths.cpmInstallationRecordFile)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["appVersion"] as? String, "0.1.17")
        XCTAssertEqual(object["cpmRevision"] as? Int, 3)
        XCTAssertNil(object["version"])
    }

    func testUpdateAndRemoveRejectTargetWhoseDigestDoesNotMatchRecordedInstall() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner())
        try await service.installOrUpdate()
        try Data("other tool".utf8).write(to: fixture.target)

        XCTAssertEqual(service.status(), .unmanaged)
        await XCTAssertThrowsErrorAsync(try await service.installOrUpdate()) { error in
            XCTAssertEqual(error as? CPMInstallationError, .unmanagedTarget)
        }
        await XCTAssertThrowsErrorAsync(try await service.remove()) { error in
            XCTAssertEqual(error as? CPMInstallationError, .unmanagedTarget)
        }
    }

    func testRemoveDeletesOnlyRecordedInstallAndRecord() async throws {
        let fixture = try Fixture()
        let runner = CopyingPrivilegedRunner()
        let service = fixture.makeService(runner: runner)
        try await service.installOrUpdate()

        try await service.remove()

        XCTAssertEqual(runner.actions, [.install, .remove])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.cpmInstallationRecordFile.path))
        XCTAssertEqual(service.status(), .notInstalled)
    }

    func testRemoveReportsRemovalFailureWhenTargetRemains() async throws {
        let fixture = try Fixture()
        try await fixture.makeService(runner: CopyingPrivilegedRunner()).installOrUpdate()
        let service = fixture.makeService(runner: NonRemovingPrivilegedRunner())

        await XCTAssertThrowsErrorAsync(try await service.remove()) { error in
            XCTAssertEqual(error as? CPMInstallationError, .removalFailed)
            XCTAssertEqual(error.localizedDescription, "cpm removal failed.")
        }
    }

    func testInstallCreatesRecordDirectoryBeforeRunningPrivilegedInstall() async throws {
        let fixture = try Fixture()
        let runner = DirectoryCheckingPrivilegedRunner(directory: fixture.paths.rootDirectory)
        let service = fixture.makeService(runner: runner)

        try await service.installOrUpdate()

        XCTAssertTrue(runner.didObserveDirectory)
    }
}

private struct NonRemovingPrivilegedRunner: PrivilegedCPMCommandRunning {
    func run(action: CPMInstallationAction, source: URL?, target: URL) async throws {}
}

private final class DirectoryCheckingPrivilegedRunner: PrivilegedCPMCommandRunning, @unchecked Sendable {
    private let directory: URL
    private(set) var didObserveDirectory = false

    init(directory: URL) {
        self.directory = directory
    }

    func run(action: CPMInstallationAction, source: URL?, target: URL) async throws {
        didObserveDirectory = FileManager.default.fileExists(atPath: directory.path)
        guard let source else {
            XCTFail("Install requires a source")
            return
        }
        try FileManager.default.copyItem(at: source, to: target)
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let target: URL
    let paths: ManagedPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CPMInstallationServiceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("CLIProxyManager.app/Contents/Helpers/cpm")
        target = root.appendingPathComponent("usr/local/bin/cpm")
        paths = ManagedPaths(rootDirectory: root.appendingPathComponent("managed", isDirectory: true))

        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bundled cpm".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
    }

    func makeService(
        runner: any PrivilegedCPMCommandRunning = CopyingPrivilegedRunner(),
        bundledVersion: String = "0.1.13",
        currentRevision: Int = 1
    ) -> CPMInstallationService {
        CPMInstallationService(
            sourceURL: source,
            targetURL: target,
            bundledVersion: bundledVersion,
            availableVersion: { bundledVersion },
            currentRevision: currentRevision,
            paths: paths,
            runner: runner
        )
    }

    func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class CopyingPrivilegedRunner: PrivilegedCPMCommandRunning, @unchecked Sendable {
    private(set) var actions: [CPMInstallationAction] = []

    func run(action: CPMInstallationAction, source: URL?, target: URL) async throws {
        actions.append(action)
        switch action {
        case .install:
            guard let source else {
                XCTFail("Install requires a source")
                return
            }
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        case .remove:
            try FileManager.default.removeItem(at: target)
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

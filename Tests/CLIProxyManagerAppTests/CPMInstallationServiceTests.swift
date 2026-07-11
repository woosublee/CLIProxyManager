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

    func testStatusReportsOutdatedWhenBundledHelperChangesAfterInstallation() async throws {
        let fixture = try Fixture()
        let service = fixture.makeService(runner: CopyingPrivilegedRunner())
        try await service.installOrUpdate()
        try Data("new cpm".utf8).write(to: fixture.source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.source.path)

        XCTAssertEqual(
            service.status(),
            .installedOutdated(installedVersion: "0.1.13", availableVersion: "0.1.14")
        )
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

    func makeService(runner: any PrivilegedCPMCommandRunning = CopyingPrivilegedRunner()) -> CPMInstallationService {
        CPMInstallationService(
            sourceURL: source,
            targetURL: target,
            bundledVersion: "0.1.13",
            availableVersion: { "0.1.14" },
            paths: paths,
            runner: runner
        )
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

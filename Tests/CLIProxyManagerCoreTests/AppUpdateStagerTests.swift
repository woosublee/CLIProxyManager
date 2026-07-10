import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppUpdateStagerTests: XCTestCase {
    func testStageCopiesVerifiedAppAndBothHelpersIntoManagedPath() async throws {
        let paths = try makePaths()
        let mounted = verifiedMountedApp(version: "0.1.13", build: 16)
        let inspector = MountedDMGInspectorDouble(bundle: mounted)
        let stager = AppUpdateStager(paths: paths, mountedInspector: inspector, now: { "2026-07-10T00:00:00Z" })

        let staged = try await stager.stage(release: makeRelease(version: "0.1.13", build: 16), artifact: Data("signed-dmg".utf8))

        XCTAssertEqual(staged.version, "0.1.13")
        XCTAssertEqual(staged.build, 16)
        let stageDir = paths.appUpdateDirectory(build: 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageDir.appendingPathComponent("CLIProxyManager.app").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: stageDir.appendingPathComponent("cpm").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: stageDir.appendingPathComponent("cliproxy-manager").path))
    }

    func testStageLeavesNoDestinationWhenInspectorThrows() async throws {
        let paths = try makePaths()
        let stager = AppUpdateStager(paths: paths, mountedInspector: FailingInspectorDouble(), now: { "2026-07-10T00:00:00Z" })

        do {
            _ = try await stager.stage(release: makeRelease(version: "0.1.13", build: 16), artifact: Data("dmg".utf8))
            XCTFail("Expected error")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appUpdateDirectory(build: 16).path))
    }

    func testStagedUpdateReturnsHighestBuildManifest() async throws {
        let paths = try makePaths()
        let stager = AppUpdateStager(paths: paths, mountedInspector: MountedDMGInspectorDouble(bundle: verifiedMountedApp(version: "0.1.14", build: 17)), now: { "2026-07-10T00:00:00Z" })
        _ = try await stager.stage(release: makeRelease(version: "0.1.14", build: 17), artifact: Data("newer-dmg".utf8))

        let found = try stager.stagedUpdate()

        XCTAssertEqual(found?.build, 17)
        XCTAssertEqual(found?.version, "0.1.14")
    }

    // MARK: - Helpers

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateStagerTests")
            .appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ManagedPaths(rootDirectory: root)
    }

    private func verifiedMountedApp(version: String, build: Int) -> MountedAppBundle {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("AppUpdateStagerTests-fixture")
            .appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("CLIProxyManager.app")
        let helpersDir = appURL.appendingPathComponent("Contents/Helpers")
        try? fm.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        let cpmHelper = helpersDir.appendingPathComponent("cpm")
        let legacyHelper = helpersDir.appendingPathComponent("cliproxy-manager")
        fm.createFile(atPath: cpmHelper.path, contents: Data("#!/bin/sh".utf8))
        fm.createFile(atPath: legacyHelper.path, contents: Data("#!/bin/sh".utf8))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cpmHelper.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacyHelper.path)
        return MountedAppBundle(appURL: appURL, cpmHelperURL: cpmHelper, legacyHelperURL: legacyHelper, version: version, build: build)
    }

    private func makeRelease(version: String, build: Int) -> AppUpdateRelease {
        AppUpdateRelease(
            version: version,
            build: build,
            enclosureURL: URL(string: "https://example.com/\(version).dmg")!,
            expectedLength: 10,
            edSignature: "sig"
        )
    }
}

// MARK: - Test doubles

private struct MountedDMGInspectorDouble: MountedDMGInspecting {
    let bundle: MountedAppBundle
    func inspect(release: AppUpdateRelease, artifact: Data) async throws -> MountedAppBundle { bundle }
}

private struct FailingInspectorDouble: MountedDMGInspecting {
    func inspect(release: AppUpdateRelease, artifact: Data) async throws -> MountedAppBundle {
        throw CLIProxyManagerCommandError.operation("Mounted DMG has unexpected bundle identifier.")
    }
}

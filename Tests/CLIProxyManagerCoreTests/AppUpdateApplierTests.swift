import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppUpdateApplierTests: XCTestCase {
    func testPreflightFailureDoesNotReplaceAnyTarget() async throws {
        let fixture = try makeTargets()
        let applier = makeApplier(targets: fixture.targets, lifecycle: AppLifecycleDouble(running: false), permissionAllowed: false)

        do {
            _ = try await applier.apply(staged: fixture.staged, stageDir: fixture.stageDir)
            XCTFail("Expected error")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite("Current user cannot update all app and helper installation paths."))
        }

        XCTAssertEqual(try String(contentsOf: fixture.appTarget, encoding: .utf8), "old app")
        XCTAssertEqual(try String(contentsOf: fixture.cpmTarget, encoding: .utf8), "old cpm")
        XCTAssertEqual(try String(contentsOf: fixture.legacyTarget, encoding: .utf8), "old legacy")
    }

    func testSuccessfulApplyStartsOnlyPreexistingRunningApp() async throws {
        let lifecycle = AppLifecycleDouble(running: true)
        let fixture = try makeTargets()
        let applier = makeApplier(targets: fixture.targets, lifecycle: lifecycle)

        let result = try await applier.apply(staged: fixture.staged, stageDir: fixture.stageDir)

        XCTAssertEqual(lifecycle.calls, [.stop, .start])
        XCTAssertTrue(result.appRestarted)
    }

    func testSuccessfulApplyDoesNotRestartWhenAppWasStopped() async throws {
        let lifecycle = AppLifecycleDouble(running: false)
        let fixture = try makeTargets()
        let applier = makeApplier(targets: fixture.targets, lifecycle: lifecycle)

        let result = try await applier.apply(staged: fixture.staged, stageDir: fixture.stageDir)

        XCTAssertTrue(lifecycle.calls.isEmpty)
        XCTAssertFalse(result.appRestarted)
    }

    func testRootUserIsRejected() async throws {
        let fixture = try makeTargets()
        let applier = AppUpdateApplier(targets: fixture.targets, lifecycle: AppLifecycleDouble(running: false), currentUID: { 0 })

        do {
            _ = try await applier.apply(staged: fixture.staged, stageDir: fixture.stageDir)
            XCTFail("Expected error")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite("cpm must run as the macOS user that owns ~/.cliproxy-manager; do not use sudo."))
        }
    }

    // MARK: - Helpers

    private struct Fixture {
        let targets: AppInstallTargets
        let staged: StagedAppUpdate
        let stageDir: URL
        let appTarget: URL
        let cpmTarget: URL
        let legacyTarget: URL
    }

    private func makeTargets() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateApplierTests")
            .appendingPathComponent(UUID().uuidString)
        let appDir = root.appendingPathComponent("Applications")
        let binDir = root.appendingPathComponent("usr/local/bin")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let appTarget = appDir.appendingPathComponent("CLIProxyManager.app")
        let cpmTarget = binDir.appendingPathComponent("cpm")
        let legacyTarget = binDir.appendingPathComponent("cliproxy-manager")

        try Data("old app".utf8).write(to: appTarget)
        try Data("old cpm".utf8).write(to: cpmTarget)
        try Data("old legacy".utf8).write(to: legacyTarget)

        let stageDir = root.appendingPathComponent("stage/16")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let stagedApp = stageDir.appendingPathComponent("CLIProxyManager.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        let newApp = stageDir.appendingPathComponent("CLIProxyManager.app")
        try Data("new app bundle".utf8).write(to: newApp.appendingPathComponent("Info.plist"))
        let stagedCPM = stageDir.appendingPathComponent("cpm")
        let stagedLegacy = stageDir.appendingPathComponent("cliproxy-manager")
        try Data("new cpm".utf8).write(to: stagedCPM)
        try Data("new legacy".utf8).write(to: stagedLegacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedCPM.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedLegacy.path)

        let staged = StagedAppUpdate(version: "0.1.13", build: 16, sourceURL: "https://example.com/16.dmg", artifactSHA256: "sha256", expectedLength: 1000, stagedAt: "2026-07-10T00:00:00Z")
        let targets = AppInstallTargets(app: appTarget, cpm: cpmTarget, legacyHelper: legacyTarget)
        return Fixture(targets: targets, staged: staged, stageDir: stageDir, appTarget: appTarget, cpmTarget: cpmTarget, legacyTarget: legacyTarget)
    }

    private func makeApplier(targets: AppInstallTargets, lifecycle: AppLifecycleDouble, permissionAllowed: Bool = true) -> AppUpdateApplier {
        AppUpdateApplier(
            targets: targets,
            lifecycle: lifecycle,
            currentUID: { 501 },
            permissionChecker: StubPermissionChecker(allowed: permissionAllowed)
        )
    }
}

// MARK: - Test doubles

private final class AppLifecycleDouble: AppLifecycleControlling, @unchecked Sendable {
    enum Call: Equatable { case stop, start }
    private(set) var calls: [Call] = []
    private let running: Bool
    init(running: Bool) { self.running = running }

    func status() async throws -> AppLifecycleStatus {
        AppLifecycleStatus(installed: true, running: running, path: nil, version: nil, build: nil)
    }
    func start() async throws -> AppLifecycleStatus { calls.append(.start); return try await status() }
    func stop() async throws -> AppLifecycleStatus { calls.append(.stop); return AppLifecycleStatus(installed: true, running: false, path: nil, version: nil, build: nil) }
    func restart() async throws -> AppLifecycleStatus { try await status() }
}

private struct StubPermissionChecker: PermissionChecking {
    let allowed: Bool
    func canWrite(to url: URL) -> Bool { allowed }
}

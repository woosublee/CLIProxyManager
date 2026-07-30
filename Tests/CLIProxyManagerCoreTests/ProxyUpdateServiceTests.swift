import CryptoKit
import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyUpdateServiceTests: XCTestCase {
    // MARK: - check() tests

    func testCheckReportsAvailableWhenReleaseIsNewerThanActiveBinary() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")))

        let result = try await service.check()

        XCTAssertEqual(result, .available(current: "7.2.41", release: makeRelease(version: "7.2.50")))
    }

    func testCheckReportsUpToDateWhenReleaseEqualsCurrentBinary() async throws {
        let paths = try makePaths(activeVersion: "7.2.50")
        let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")))

        let result = try await service.check()
        XCTAssertEqual(result, .upToDate(current: "7.2.50"))
    }

    func testCheckReportsPendingBeforeAvailableRelease() async throws {
        let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
        let store = CLIProxyAPIBinaryStore(paths: paths)
        let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")))

        let result = try await service.check()
        let pending = try XCTUnwrap(store.pendingManifest())

        XCTAssertEqual(result, .pending(current: "7.2.41", pending: pending))
    }

    // MARK: - stage() tests

    func testStageDownloadsVerifiesAndStoresPendingBinary() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let (binaryURL, manifest) = try makeVerificationFixture(version: "7.2.50")
        let downloaded = CLIProxyAPIBinaryVerificationResult(binaryURL: binaryURL, manifest: manifest)
        let downloader = DownloaderDouble(result: downloaded)
        let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")), downloader: downloader)

        let result = try await service.stage()

        XCTAssertEqual(result, ProxyUpdateStageResult(version: "7.2.50", staged: true))
        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest()?.version, "7.2.50")
        XCTAssertEqual(downloader.cleanedResults.count, 1)
    }

    func testBlockedStageDoesNotInvokeDownloaderOrStoreMutation() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let (binaryURL, manifest) = try makeVerificationFixture(version: "7.2.50")
        let downloader = DownloaderDouble(result: .init(binaryURL: binaryURL, manifest: manifest))
        let service = makeService(
            paths: paths,
            checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")),
            downloader: downloader,
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer(action: .stageProxyUpdate)
        )

        do {
            _ = try await service.stage()
            XCTFail("Expected compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage))
        }

        XCTAssertEqual(downloader.requests, [])
        XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
    }

    func testStageBlocksBeforeDownloadWhenActiveArtifactTargetMismatches() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        var active = try XCTUnwrap(CLIProxyAPIBinaryStore(paths: paths).activeManifest())
        active.target = .init(operatingSystem: .darwin, architecture: .x86_64)
        try JSONEncoder().encode(active).write(to: paths.activeClipProxyManifest)
        let (binaryURL, manifest) = try makeVerificationFixture(version: "7.2.50")
        let downloader = DownloaderDouble(result: .init(binaryURL: binaryURL, manifest: manifest))
        let service = makeService(
            paths: paths,
            checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")),
            downloader: downloader,
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )

        do {
            _ = try await service.stage()
            XCTFail("Expected compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage))
        }
        XCTAssertEqual(downloader.requests, [])
        XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
    }

    func testStageBlocksBeforeDownloadWhenBundledArtifactTargetIsUnknown() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let bundledManifestURL = paths.rootDirectory.appendingPathComponent("bundle/manifest.json")
        var bundled = try XCTUnwrap(CLIProxyAPIBinaryStore(paths: paths).activeManifest())
        bundled.sourceKind = .bundled
        bundled.upstreamAsset = "unknown-artifact.tar.gz"
        bundled.target = nil
        try FileManager.default.createDirectory(at: bundledManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bundled).write(to: bundledManifestURL)
        let (binaryURL, manifest) = try makeVerificationFixture(version: "7.2.50")
        let downloader = DownloaderDouble(result: .init(binaryURL: binaryURL, manifest: manifest))
        let service = makeService(
            paths: paths,
            checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")),
            downloader: downloader,
            bundledManifestURL: bundledManifestURL,
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )

        do {
            _ = try await service.stage()
            XCTFail("Expected compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage))
        }
        XCTAssertEqual(downloader.requests, [])
        XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
    }

    func testProductionInitializerBlocksUnknownBundledManifestBeforeStageMutation() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let bundledManifestURL = paths.rootDirectory.appendingPathComponent("bundle/manifest.json")
        var bundled = try XCTUnwrap(CLIProxyAPIBinaryStore(paths: paths).activeManifest())
        bundled.target = nil
        bundled.upstreamAsset = "unrecognized-artifact.tar.gz"
        try FileManager.default.createDirectory(at: bundledManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bundled).write(to: bundledManifestURL)
        let (binaryURL, manifest) = try makeVerificationFixture(version: "7.2.50")
        let downloader = DownloaderDouble(result: .init(binaryURL: binaryURL, manifest: manifest))
        let service = ProxyUpdateService(
            paths: paths,
            checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")),
            downloader: downloader,
            appBundleLocator: StaticAppBundleLocator(manifestURL: bundledManifestURL),
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer()
        )

        do {
            _ = try await service.stage()
            XCTFail("Expected bundled manifest compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage))
        }

        XCTAssertEqual(downloader.requests, [])
        XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
    }

    func testProductionInitializerBlocksMismatchedBundledManifestBeforeApplyMutation() async throws {
        let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
        let bundledManifestURL = paths.rootDirectory.appendingPathComponent("bundle/manifest.json")
        var bundled = try XCTUnwrap(CLIProxyAPIBinaryStore(paths: paths).activeManifest())
        bundled.target = .init(operatingSystem: .darwin, architecture: .x86_64)
        try FileManager.default.createDirectory(at: bundledManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bundled).write(to: bundledManifestURL)
        let runtime = ProxyRuntimeUpdateDouble(statuses: [
            ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.41", pendingVersion: "7.2.50")
        ])
        let service = ProxyUpdateService(
            paths: paths,
            runtime: runtime,
            appBundleLocator: StaticAppBundleLocator(manifestURL: bundledManifestURL),
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )

        do {
            _ = try await service.apply()
            XCTFail("Expected bundled manifest compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage))
        }

        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).activeManifest()?.version, "7.2.41")
        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest()?.version, "7.2.50")
        XCTAssertEqual(runtime.restartCount, 0)
    }

    func testStageDoesNotDownloadWhenCurrentBinaryIsAlreadyNewer() async throws {
        let paths = try makePaths(activeVersion: "7.2.60")
        let downloader = DownloaderDouble(result: nil)
        let service = makeService(paths: paths, checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")), downloader: downloader)

        let result = try await service.stage()

        XCTAssertEqual(result, ProxyUpdateStageResult(version: "7.2.60", staged: false))
        XCTAssertTrue(downloader.requests.isEmpty)
    }

    func testStageLeavesExistingPendingAndActiveFilesUntouchedWhenVerificationFails() async throws {
        let paths = try makePaths(activeVersion: "7.2.41")
        let service = makeService(
            paths: paths,
            checker: ReleaseCheckerDouble(release: makeRelease(version: "7.2.50")),
            downloader: DownloaderDouble(error: CLIProxyManagerCommandError.operation("Verification failed"))
        )

        do {
            _ = try await service.stage()
            XCTFail("Expected error")
        } catch {}
        XCTAssertNil(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest())
        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).activeManifest()?.version, "7.2.41")
    }

    // MARK: - apply() tests

    func testApplyRestartsAndChecksReadyWhenProxyWasRunning() async throws {
        let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
        let runtime = ProxyRuntimeUpdateDouble(statuses: [
            ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.41", pendingVersion: "7.2.50"),
            ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.50", pendingVersion: nil)
        ])
        let service = makeService(paths: paths, runtime: runtime)

        let result = try await service.apply()

        XCTAssertEqual(runtime.restartCount, 1)
        XCTAssertEqual(result, ProxyUpdateApplyResult(version: "7.2.50", restartedProxy: true, proxyReady: true))
    }

    func testBlockedApplyLeavesPendingBinaryAndRunningProxyUntouched() async throws {
        let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
        let runtime = ProxyRuntimeUpdateDouble(statuses: [
            ProxyRuntimeStatus(port: 8317, running: true, health: .ready, activeVersion: "7.2.41", pendingVersion: "7.2.50")
        ])
        let service = makeService(
            paths: paths,
            runtime: runtime,
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer(action: .applyProxyUpdate)
        )

        do {
            _ = try await service.apply()
            XCTFail("Expected compatibility block")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite(RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage))
        }

        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).activeManifest()?.version, "7.2.41")
        XCTAssertEqual(try CLIProxyAPIBinaryStore(paths: paths).pendingManifest()?.version, "7.2.50")
        XCTAssertEqual(runtime.restartCount, 0)
    }

    func testApplyDoesNotStartProxyWhenItWasStopped() async throws {
        let paths = try makePaths(activeVersion: "7.2.41", pendingVersion: "7.2.50")
        let runtime = ProxyRuntimeUpdateDouble(statuses: [
            ProxyRuntimeStatus(port: 8317, running: false, health: .stopped, activeVersion: "7.2.41", pendingVersion: "7.2.50")
        ])
        let service = makeService(paths: paths, runtime: runtime)

        let result = try await service.apply()

        XCTAssertEqual(runtime.restartCount, 0)
        XCTAssertEqual(result, ProxyUpdateApplyResult(version: "7.2.50", restartedProxy: false, proxyReady: false))
    }

    func testApplyFailsWithoutPendingBinary() async throws {
        let service = makeService(paths: try makePaths(activeVersion: "7.2.41"))

        do {
            _ = try await service.apply()
            XCTFail("Expected error")
        } catch let error as CLIProxyManagerCommandError {
            XCTAssertEqual(error, .prerequisite("No staged CLIProxyAPI update is available. Run cpm update stage proxy first."))
        }
    }

    // MARK: - Helpers

    private func makePaths(activeVersion: String, pendingVersion: String? = nil) throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyUpdateServiceTests")
            .appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedPaths(rootDirectory: root)

        let (activeBinary, activeManifest) = try makeVerificationFixture(version: activeVersion)
        try FileManager.default.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: activeBinary, to: paths.clipProxyBinary)
        let manifestData = try JSONEncoder().encode(activeManifest)
        try manifestData.write(to: paths.activeClipProxyManifest)

        if let pending = pendingVersion {
            let (pendingBinary, pendingManifest) = try makeVerificationFixture(version: pending)
            try CLIProxyAPIBinaryStore(paths: paths).savePending(binaryURL: pendingBinary, manifest: pendingManifest, validate: false)
        }
        return paths
    }

    private func makeVerificationFixture(version: String) throws -> (URL, CLIProxyAPIBinaryManifest) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyUpdateServiceTests-fixture")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }
        let binaryURL = tmpDir.appendingPathComponent("cliproxyapi")
        let content = "#!/bin/sh\necho version-\(version)"
        try Data(content.utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        let size = try binaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sha = try binaryURL.sha256HexDigest()
        let manifest = makeManifest(version: version, sha: sha, size: size)
        return (binaryURL, manifest)
    }

    private func makeManifest(version: String, sha: String, size: Int) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: version,
            commit: "commit-\(version)",
            builtAt: "2026-07-10T00:00:00Z",
            sourceKind: .userUpdated,
            source: "https://github.com/router-for-me/CLIProxyAPI/releases/download/v\(version)/CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: "v\(version)",
            upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            upstreamAssetSha256: "archive-sha-\(version)",
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: sha,
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api"
        )
    }

    private func makeRelease(version: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(
            version: CLIProxyAPIVersion(version)!,
            tagName: "v\(version)",
            assetName: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://github.com/router-for-me/CLIProxyAPI/releases/download/v\(version)/CLIProxyAPI_\(version)_darwin_aarch64.tar.gz")!,
            assetSha256: "sha256-\(version)"
        )
    }

    private func makeService(
        paths: ManagedPaths,
        checker: any ProxyUpdateChecking = ReleaseCheckerDouble(release: nil),
        downloader: any ProxyUpdateDownloading = DownloaderDouble(result: nil),
        runtime: (any ProxyRuntimeUpdating)? = nil,
        bundledManifestURL: URL? = nil,
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RejectingCompatibilityAuthorizer()
    ) -> ProxyUpdateService {
        ProxyUpdateService(
            store: CLIProxyAPIBinaryStore(paths: paths),
            checker: checker,
            downloader: downloader,
            runtime: runtime,
            bundledManifestURL: bundledManifestURL,
            compatibilityAuthorizer: compatibilityAuthorizer
        )
    }
}

// MARK: - Test doubles

private struct RejectingCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing {
    let action: CompatibilityAction?

    init(action: CompatibilityAction? = nil) {
        self.action = action
    }

    func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        RuntimeCompatibilityReport(
            findings: action == nil
                ? []
                : [.unsupportedArchitecture(expected: .arm64, actual: .x86_64)],
            decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { candidate in
                (candidate, CompatibilityDecision(
                    action: candidate,
                    disposition: candidate == action ? .blocked : .allowed
                ))
            })
        )
    }

    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        staticReport(artifacts: artifacts)
    }

    func require(_ action: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {
        if action == self.action {
            throw RuntimeCompatibilityError.actionBlocked(action)
        }
    }
}

private struct ArtifactMismatchAuthorizer: RuntimeCompatibilityAuthorizing {
    func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        let hasUnsupportedArtifact = [artifacts.bundled, artifacts.active, artifacts.pending].contains {
            guard case let .explicit(target) = $0 else { return false }
            return target != .darwinArm64
        }
        return RuntimeCompatibilityReport(
            findings: hasUnsupportedArtifact
                ? [.unsupportedArtifactTarget(expected: .darwinArm64, actual: .init(operatingSystem: .darwin, architecture: .x86_64))]
                : [],
            decisions: Dictionary(uniqueKeysWithValues: CompatibilityAction.allCases.map { action in
                (action, CompatibilityDecision(action: action, disposition: hasUnsupportedArtifact ? .blocked : .allowed))
            })
        )
    }

    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        staticReport(artifacts: artifacts)
    }

    func require(_ action: CompatibilityAction, artifacts: CompatibilityArtifacts) throws {
        if staticReport(artifacts: artifacts).decision(for: action).disposition == .blocked {
            throw RuntimeCompatibilityError.actionBlocked(action)
        }
    }
}

private struct StaticAppBundleLocator: AppBundleLocating {
    let manifestURL: URL

    func locateInstalledApp() throws -> ManagedAppBundle {
        ManagedAppBundle(
            appURL: manifestURL.deletingLastPathComponent().appendingPathComponent("CLIProxyManager.app"),
            proxyBinaryURL: manifestURL.deletingLastPathComponent().appendingPathComponent("cliproxyapi"),
            proxyManifestURL: manifestURL,
            version: "0.1.0",
            build: "1"
        )
    }
}

private struct ReleaseCheckerDouble: ProxyUpdateChecking {
    let release: CLIProxyAPIRelease?
    init(release: CLIProxyAPIRelease?) { self.release = release }
    func latestRelease() async throws -> CLIProxyAPIRelease {
        guard let release else { throw CLIProxyManagerCommandError.operation("No release") }
        return release
    }
}

private final class DownloaderDouble: ProxyUpdateDownloading, @unchecked Sendable {
    private(set) var requests: [CLIProxyAPIRelease] = []
    private(set) var cleanedResults: [CLIProxyAPIBinaryVerificationResult] = []
    private let result: CLIProxyAPIBinaryVerificationResult?
    private let error: Error?

    init(result: CLIProxyAPIBinaryVerificationResult?) { self.result = result; self.error = nil }
    init(error: Error) { self.result = nil; self.error = error }

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        requests.append(release)
        if let error { throw error }
        return result!
    }
    func cleanup(_ r: CLIProxyAPIBinaryVerificationResult) { cleanedResults.append(r) }
}

private final class ProxyRuntimeUpdateDouble: ProxyRuntimeUpdating, @unchecked Sendable {
    private var statuses: [ProxyRuntimeStatus]
    private(set) var restartCount = 0
    private let lock = NSLock()

    init(statuses: [ProxyRuntimeStatus]) { self.statuses = statuses }

    func status() async throws -> ProxyRuntimeStatus {
        lock.withLock { statuses.first! }
    }

    func restart() async throws -> ProxyRuntimeStatus {
        lock.withLock {
            restartCount += 1
            if statuses.count > 1 { statuses.removeFirst() }
            return statuses.first!
        }
    }
}

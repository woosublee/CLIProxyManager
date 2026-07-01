import Foundation
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class CLIProxyAPIUpdateServiceTests: XCTestCase {
    func testAutomaticCheckSkipsWhenLastCheckIsWithin24Hours() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeState(lastCheckedAt: Date(), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() })

        await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 0)
        XCTAssertNil(service.availableUpdate)
    }

    func testAutomaticCheckPublishesNewerReleaseWhenLastCheckIsOld() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let oldDate = Date(timeIntervalSince1970: 0)
        try writeState(lastCheckedAt: oldDate, to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 90_000) })

        await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testManualCheckIgnoresLastCheckThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeState(lastCheckedAt: Date(), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() })

        await service.checkNow()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testDeferredVersionSuppressesRepeatedAutomaticPrompt() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 100_000) })

        await service.checkNow()
        service.deferAvailableUpdate()
        service.availableUpdate = nil
        await service.checkAutomaticallyOnLaunch()

        XCTAssertNil(service.availableUpdate)
    }

    func testDownloadAvailableUpdateSavesPendingBinary() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let release = release("7.2.42")
        let checker = StubUpdateChecking(release: release)
        let downloader = StubUpdateDownloading(result: CLIProxyAPIBinaryVerificationResult(
            binaryURL: sandbox.appendingPathComponent("verified/cliproxyapi"),
            manifest: manifest("7.2.42")
        ))
        try writeExecutable("#!/bin/sh\n", to: downloader.result!.binaryURL)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: downloader, store: store, now: { Date() })
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(store.savedPendingVersions, ["7.2.42"])
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
    }

    func testApplyPendingNowCallsStore() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() })

        try service.applyPendingNow()

        XCTAssertEqual(store.applyPendingCallCount, 1)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("CLIProxyAPIUpdateServiceTests").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        return sandbox
    }

    private func release(_ version: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(version: CLIProxyAPIVersion(version)!, tagName: "v\(version)", assetName: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", assetURL: URL(string: "https://example.com/archive.tar.gz")!, assetSha256: "archive-sha")
    }

    private func manifest(_ version: String) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: .userUpdated, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api")
    }

    private func writeState(lastCheckedAt: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "{\"lastCheckedAt\":\"\(ISO8601DateFormatter().string(from: lastCheckedAt))\"}"
        try Data(text.utf8).write(to: url)
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private final class StubUpdateChecking: CLIProxyAPIUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let release: CLIProxyAPIRelease
    private var _invocationCount = 0
    var invocationCount: Int { lock.withLock { _invocationCount } }

    init(release: CLIProxyAPIRelease) { self.release = release }

    func latestRelease() async throws -> CLIProxyAPIRelease {
        lock.withLock { _invocationCount += 1 }
        return release
    }
}

private final class StubUpdateDownloading: CLIProxyAPIUpdateDownloading, @unchecked Sendable {
    let result: CLIProxyAPIBinaryVerificationResult?

    init(result: CLIProxyAPIBinaryVerificationResult? = nil) {
        self.result = result
    }

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        if let result { return result }
        throw NSError(domain: "test", code: 1)
    }
}

private final class StubUpdateBinaryStore: CLIProxyAPIUpdateBinaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let current: CLIProxyAPIVersion?
    private var _savedPendingVersions: [String] = []
    private var _applyPendingCallCount = 0

    var savedPendingVersions: [String] { lock.withLock { _savedPendingVersions } }
    var applyPendingCallCount: Int { lock.withLock { _applyPendingCallCount } }

    init(currentVersion: String?) {
        self.current = currentVersion.flatMap(CLIProxyAPIVersion.init)
    }

    func currentVersion() throws -> CLIProxyAPIVersion? { current }
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? { nil }

    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        lock.withLock { _savedPendingVersions.append(manifest.version) }
    }

    func applyPending() throws {
        lock.withLock { _applyPendingCallCount += 1 }
    }
}

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

    func testAutomaticFailureRecordsLastCheckedAtForThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let now = Date(timeIntervalSince1970: 123_456)
        let checker = StubUpdateChecking(error: NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"]))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { now })

        await service.checkAutomaticallyOnLaunch()

        let data = try Data(contentsOf: paths.clipProxyUpdateStateFile)
        let state = try JSONDecoder().decode(CLIProxyAPIUpdateState.self, from: data)
        XCTAssertEqual(state.lastCheckedAt, ISO8601DateFormatter().string(from: now))
        XCTAssertEqual(state.lastFailureMessage, "offline")
    }

    func testCurrentVersionFallsBackToBundledManifestWhenActiveManifestIsMissing() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeManifest(manifest("7.2.42", sourceKind: .bundled), to: bundledManifest)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, bundledManifestURL: bundledManifest, now: { Date() })

        await service.checkNow()

        XCTAssertNil(service.availableUpdate)
        if case .upToDate = service.state {} else {
            XCTFail("Expected upToDate, got \(service.state)")
        }
        XCTAssertEqual(service.currentVersionText, "7.2.42")
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
            manifest: manifest("7.2.42"),
            temporaryDirectory: sandbox.appendingPathComponent("verified")
        ))
        try writeExecutable("#!/bin/sh\n", to: downloader.result!.binaryURL)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: downloader, store: store, now: { Date() })
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(store.savedPendingVersions, ["7.2.42"])
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
        XCTAssertNil(service.availableUpdate)
        XCTAssertEqual(downloader.cleanedTemporaryDirectories.map(\.path), [sandbox.appendingPathComponent("verified").path])
    }

    func testInitClearsStalePendingStateAfterAutostartPromotion() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeFullState(CLIProxyAPIUpdateState(lastAvailableVersion: "7.2.42", pendingVersion: "7.2.42"), to: paths.clipProxyUpdateStateFile)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.42", pending: nil)

        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() })

        XCTAssertNil(service.pendingUpdate)
        XCTAssertEqual(service.currentVersionText, "7.2.42")
        let data = try Data(contentsOf: paths.clipProxyUpdateStateFile)
        let state = try JSONDecoder().decode(CLIProxyAPIUpdateState.self, from: data)
        XCTAssertNil(state.pendingVersion)
        XCTAssertNil(state.lastAvailableVersion)
    }

    func testApplyPendingNowClearsAvailableAndPersistedAvailableVersion() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeFullState(CLIProxyAPIUpdateState(lastAvailableVersion: "7.2.42", lastDeferredVersion: "7.2.42", pendingVersion: "7.2.42"), to: paths.clipProxyUpdateStateFile)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"), currentAfterApply: "7.2.42")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() })
        service.availableUpdate = release("7.2.42")

        try service.applyPendingNow()

        XCTAssertNil(service.pendingUpdate)
        XCTAssertNil(service.availableUpdate)
        XCTAssertEqual(service.currentVersionText, "7.2.42")
        let data = try Data(contentsOf: paths.clipProxyUpdateStateFile)
        let state = try JSONDecoder().decode(CLIProxyAPIUpdateState.self, from: data)
        XCTAssertNil(state.pendingVersion)
        XCTAssertNil(state.lastAvailableVersion)
        XCTAssertNil(state.lastDeferredVersion)
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

    private func manifest(_ version: String, sourceKind: CLIProxyAPIBinarySourceKind = .userUpdated) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: sourceKind, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api")
    }

    private func writeManifest(_ manifest: CLIProxyAPIBinaryManifest, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url)
    }

    private func writeState(lastCheckedAt: Date, to url: URL) throws {
        var state = CLIProxyAPIUpdateState()
        state.lastCheckedAt = ISO8601DateFormatter().string(from: lastCheckedAt)
        try writeFullState(state, to: url)
    }

    private func writeFullState(_ state: CLIProxyAPIUpdateState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url)
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private final class StubUpdateChecking: CLIProxyAPIUpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let release: CLIProxyAPIRelease?
    private let error: Error?
    private var _invocationCount = 0
    var invocationCount: Int { lock.withLock { _invocationCount } }

    init(release: CLIProxyAPIRelease) {
        self.release = release
        self.error = nil
    }

    init(error: Error) {
        self.release = nil
        self.error = error
    }

    func latestRelease() async throws -> CLIProxyAPIRelease {
        lock.withLock { _invocationCount += 1 }
        if let error { throw error }
        return release!
    }
}

private final class StubUpdateDownloading: CLIProxyAPIUpdateDownloading, @unchecked Sendable {
    private let lock = NSLock()
    let result: CLIProxyAPIBinaryVerificationResult?
    private var _cleanedTemporaryDirectories: [URL] = []

    var cleanedTemporaryDirectories: [URL] { lock.withLock { _cleanedTemporaryDirectories } }

    init(result: CLIProxyAPIBinaryVerificationResult? = nil) {
        self.result = result
    }

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        if let result { return result }
        throw NSError(domain: "test", code: 1)
    }

    func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) {
        guard let temporaryDirectory = result.temporaryDirectory else { return }
        lock.withLock { _cleanedTemporaryDirectories.append(temporaryDirectory) }
    }
}

private final class StubUpdateBinaryStore: CLIProxyAPIUpdateBinaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CLIProxyAPIVersion?
    private var pending: CLIProxyAPIBinaryManifest?
    private let currentAfterApply: CLIProxyAPIVersion?
    private var _savedPendingVersions: [String] = []
    private var _applyPendingCallCount = 0

    var savedPendingVersions: [String] { lock.withLock { _savedPendingVersions } }
    var applyPendingCallCount: Int { lock.withLock { _applyPendingCallCount } }

    init(currentVersion: String?, pending: CLIProxyAPIBinaryManifest? = nil, currentAfterApply: String? = nil) {
        self.current = currentVersion.flatMap(CLIProxyAPIVersion.init)
        self.pending = pending
        self.currentAfterApply = currentAfterApply.flatMap(CLIProxyAPIVersion.init)
    }

    func currentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? { lock.withLock { current } }
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? { lock.withLock { pending } }

    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        lock.withLock {
            _savedPendingVersions.append(manifest.version)
            pending = manifest
        }
    }

    func applyPending() throws {
        lock.withLock {
            _applyPendingCallCount += 1
            pending = nil
            if let currentAfterApply {
                current = currentAfterApply
            }
        }
    }
}

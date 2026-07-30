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

        _ = await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 0)
        XCTAssertNil(service.availableUpdate)
    }

    func testAutomaticCheckRefreshesStoredStatusBeforeThrottleReturn() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeFullState(CLIProxyAPIUpdateState(lastCheckedAt: ISO8601DateFormatter().string(from: Date()), pendingVersion: "7.2.42"), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, now: { Date() })
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
        store.replaceState(currentVersion: "7.2.42", pending: nil)

        _ = await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 0)
        XCTAssertNil(service.pendingUpdate)
        XCTAssertEqual(service.currentVersionText, "7.2.42")
        let data = try Data(contentsOf: paths.clipProxyUpdateStateFile)
        let state = try JSONDecoder().decode(CLIProxyAPIUpdateState.self, from: data)
        XCTAssertNil(state.pendingVersion)
    }

    func testAutomaticCheckPublishesNewerReleaseWhenLastCheckIsOld() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let oldDate = Date(timeIntervalSince1970: 0)
        try writeState(lastCheckedAt: oldDate, to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 90_000) })

        _ = await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testAutomaticFailureRecordsLastCheckedAtForThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let now = Date(timeIntervalSince1970: 123_456)
        let checker = StubUpdateChecking(error: NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"]))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { now })

        _ = await service.checkAutomaticallyOnLaunch()

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

    func testCurrentVersionIgnoresStaleActiveManifestWhenBinaryIsMissing() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledManifest = sandbox.appendingPathComponent("bundle/cliproxyapi.manifest.json")
        try writeManifest(manifest("7.2.42", sourceKind: .bundled), to: bundledManifest)
        try writeManifest(manifest("9.0.0", sourceKind: .userUpdated), to: paths.activeClipProxyManifest)
        let checker = StubUpdateChecking(release: release("7.2.43"))
        let store = CLIProxyAPIBinaryStore(paths: paths)
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, bundledManifestURL: bundledManifest, now: { Date() })

        await service.checkNow()

        XCTAssertEqual(service.currentVersionText, "7.2.42")
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.43")
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

    func testManualCheckKeepsMatchingPendingReleaseInPendingState() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, now: { Date() })

        await service.checkNow()

        XCTAssertNil(service.availableUpdate)
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
        if case .pending = service.state {} else {
            XCTFail("Expected pending, got \(service.state)")
        }
    }

    func testDeferredVersionSuppressesRepeatedAutomaticPrompt() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 100_000) })

        await service.checkNow()
        service.deferAvailableUpdate()
        service.availableUpdate = nil
        _ = await service.checkAutomaticallyOnLaunch()

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

    func testBlockedDownloadDoesNotInvokeDownloaderOrStoreMutation() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let downloader = StubUpdateDownloading(result: CLIProxyAPIBinaryVerificationResult(
            binaryURL: sandbox.appendingPathComponent("verified/cliproxyapi"),
            manifest: manifest("7.2.42"),
            temporaryDirectory: sandbox.appendingPathComponent("verified")
        ))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: downloader,
            store: store,
            now: { Date() },
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer(action: .stageProxyUpdate)
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(downloader.invocationCount, 0)
        XCTAssertEqual(store.savedPendingVersions, [])
        XCTAssertEqual(service.lastErrorMessage, RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage)
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

    func testSchedulePendingForNextServerStartCallsStoreAndKeepsPendingState() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() }
        )

        XCTAssertTrue(service.schedulePendingForNextServerStart())

        XCTAssertEqual(store.schedulePendingCallCount, 1)
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
        XCTAssertEqual(service.state, .pending)
    }

    func testBlockedScheduleDoesNotMutateStore() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() },
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer(action: .scheduleProxyUpdate)
        )

        XCTAssertFalse(service.schedulePendingForNextServerStart())

        XCTAssertEqual(store.schedulePendingCallCount, 0)
        XCTAssertEqual(service.lastErrorMessage, RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage)
    }

    func testSchedulePendingForNextServerStartRecordsFailure() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(
            currentVersion: "7.2.41",
            pending: manifest("7.2.42"),
            scheduleError: CocoaError(.fileWriteNoPermission)
        )
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() }
        )

        XCTAssertFalse(service.schedulePendingForNextServerStart())

        XCTAssertEqual(store.schedulePendingCallCount, 1)
        if case .failed(let message) = service.state {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected failed state")
        }
    }

    func testReloadStoredStatusPublishesReconciledActiveAndPendingVersions() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.72", pending: nil)
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.92")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() }
        )
        store.replaceState(currentVersion: "7.2.91", pending: manifest("7.2.92"))

        service.reloadStoredStatus()

        XCTAssertEqual(service.currentVersionText, "7.2.91")
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.92")
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

    func testBlockedApplyDoesNotMutateStore() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() },
            compatibilityAuthorizer: RejectingCompatibilityAuthorizer(action: .applyProxyUpdate)
        )

        XCTAssertThrowsError(try service.applyPendingNow()) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite(RuntimeCompatibilityBlocker.unsupportedArchitecture.recoveryMessage)
            )
        }
        XCTAssertEqual(store.applyPendingCallCount, 0)
    }

    func testUpdateOperationsRecordTypedLifecycleEvents() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let logger = UpdateRecordingAppLogger()
        let release = release("7.2.42")
        let downloader = StubUpdateDownloading(result: CLIProxyAPIBinaryVerificationResult(
            binaryURL: sandbox.appendingPathComponent("verified/cliproxyapi"),
            manifest: manifest("7.2.42"),
            temporaryDirectory: sandbox.appendingPathComponent("verified")
        ))
        try writeExecutable("#!/bin/sh\n", to: downloader.result!.binaryURL)
        let store = StubUpdateBinaryStore(
            currentVersion: "7.2.41",
            currentAfterApply: "7.2.42"
        )
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release),
            downloader: downloader,
            store: store,
            now: { Date() },
            appLogger: logger
        )

        await service.checkNow()
        await service.downloadAvailableUpdate()
        try service.applyPendingNow()

        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .check, result: .started)))
        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .check, result: .succeeded)))
        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .download, result: .succeeded)))
        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .apply, result: .succeeded)))
    }

    func testDownloadFailureFromNetworkErrorLogsNetworkFailureKind() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let logger = UpdateRecordingAppLogger()
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let downloader = StubUpdateDownloading(downloadError: HTTPClientError.timedOut)
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: checker,
            downloader: downloader,
            store: StubUpdateBinaryStore(currentVersion: "7.2.41"),
            now: { Date() },
            appLogger: logger
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.network))))
        XCTAssertFalse(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.updateVerification))))
    }

    func testDownloadFailureFromArchiveVerificationErrorLogsVerificationFailureKind() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let logger = UpdateRecordingAppLogger()
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let downloader = StubUpdateDownloading(downloadError: CLIProxyAPIArchiveVerifierError.archiveChecksumMismatch)
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: checker,
            downloader: downloader,
            store: StubUpdateBinaryStore(currentVersion: "7.2.41"),
            now: { Date() },
            appLogger: logger
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.updateVerification))))
        XCTAssertFalse(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.network))))
    }

    func testDownloadFailureFromPendingSaveLogsFileSystemFailureKind() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let logger = UpdateRecordingAppLogger()
        let release = release("7.2.42")
        let checker = StubUpdateChecking(release: release)
        let downloader = StubUpdateDownloading(result: CLIProxyAPIBinaryVerificationResult(
            binaryURL: sandbox.appendingPathComponent("verified/cliproxyapi"),
            manifest: manifest("7.2.42"),
            temporaryDirectory: sandbox.appendingPathComponent("verified")
        ))
        try writeExecutable("#!/bin/sh\n", to: downloader.result!.binaryURL)
        let store = StubUpdateBinaryStore(
            currentVersion: "7.2.41",
            saveError: CocoaError(.fileWriteNoPermission)
        )
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: checker,
            downloader: downloader,
            store: store,
            now: { Date() },
            appLogger: logger
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.fileSystem))))
        XCTAssertTrue(store.savedPendingVersions.isEmpty)
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

private final class UpdateRecordingAppLogger: AppLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [AppLogEvent] = []
    private var level = LogLevel.info

    var minimumLevel: LogLevel { lock.withLock { level } }
    var diagnostics: AppLogDiagnostics { .unavailable(reason: .notConfigured) }
    var events: [AppLogEvent] { lock.withLock { recordedEvents } }

    func configure(minimumLevel: LogLevel) {
        lock.withLock { level = minimumLevel }
    }

    func record(_ event: AppLogEvent) {
        lock.withLock { recordedEvents.append(event) }
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
    private let downloadError: Error
    private var _cleanedTemporaryDirectories: [URL] = []
    private var _invocationCount = 0

    var cleanedTemporaryDirectories: [URL] { lock.withLock { _cleanedTemporaryDirectories } }
    var invocationCount: Int { lock.withLock { _invocationCount } }

    init(result: CLIProxyAPIBinaryVerificationResult? = nil, downloadError: Error = NSError(domain: "test", code: 1)) {
        self.result = result
        self.downloadError = downloadError
    }

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        lock.withLock { _invocationCount += 1 }
        if let result { return result }
        throw downloadError
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
    private let scheduleError: Error?
    private let saveError: Error?
    private var _savedPendingVersions: [String] = []
    private var _applyPendingCallCount = 0
    private var _schedulePendingCallCount = 0

    var savedPendingVersions: [String] { lock.withLock { _savedPendingVersions } }
    var applyPendingCallCount: Int { lock.withLock { _applyPendingCallCount } }
    var schedulePendingCallCount: Int { lock.withLock { _schedulePendingCallCount } }

    init(
        currentVersion: String?,
        pending: CLIProxyAPIBinaryManifest? = nil,
        currentAfterApply: String? = nil,
        scheduleError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.current = currentVersion.flatMap(CLIProxyAPIVersion.init)
        self.pending = pending
        self.currentAfterApply = currentAfterApply.flatMap(CLIProxyAPIVersion.init)
        self.scheduleError = scheduleError
        self.saveError = saveError
    }

    func validatedCurrentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? { lock.withLock { current } }
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? { lock.withLock { pending } }

    func replaceState(currentVersion: String?, pending: CLIProxyAPIBinaryManifest?) {
        lock.withLock {
            current = currentVersion.flatMap(CLIProxyAPIVersion.init)
            self.pending = pending
        }
    }

    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        try lock.withLock {
            if let saveError { throw saveError }
            _savedPendingVersions.append(manifest.version)
            pending = manifest
        }
    }

    func schedulePendingForNextStart() throws {
        try lock.withLock {
            _schedulePendingCallCount += 1
            if let scheduleError { throw scheduleError }
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

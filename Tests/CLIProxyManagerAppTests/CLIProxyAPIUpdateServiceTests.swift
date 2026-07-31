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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())
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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 90_000) }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

        _ = await service.checkAutomaticallyOnLaunch()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testAutomaticFailureRecordsLastCheckedAtForThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let now = Date(timeIntervalSince1970: 123_456)
        let checker = StubUpdateChecking(error: NSError(domain: "Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"]))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { now }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
        let store = CLIProxyAPIBinaryStore(paths: paths, compatibilityAuthorizer: supportedCompatibilityAuthorizer())
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, bundledManifestURL: bundledManifest, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
        let store = CLIProxyAPIBinaryStore(paths: paths, compatibilityAuthorizer: supportedCompatibilityAuthorizer())
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, bundledManifestURL: bundledManifest, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

        await service.checkNow()

        XCTAssertEqual(service.currentVersionText, "7.2.42")
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.43")
    }

    func testManualCheckIgnoresLastCheckThrottle() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeState(lastCheckedAt: Date(), to: paths.clipProxyUpdateStateFile)
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

        await service.checkNow()

        XCTAssertEqual(checker.invocationCount, 1)
        XCTAssertEqual(service.availableUpdate?.version.description, "7.2.42")
    }

    func testManualCheckKeepsMatchingPendingReleaseInPendingState() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let checker = StubUpdateChecking(release: release("7.2.42"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: StubUpdateDownloading(), store: StubUpdateBinaryStore(currentVersion: "7.2.41"), now: { Date(timeIntervalSince1970: 100_000) }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: checker, downloader: downloader, store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())
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

    func testBlockedDownloadDoesNotInvokeDownloaderWhenActiveArtifactMismatches() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = manifest(
            "7.2.41",
            target: .init(operatingSystem: .darwin, architecture: .x86_64)
        )
        let downloader = StubUpdateDownloading()
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: downloader,
            store: StubUpdateBinaryStore(currentVersion: "7.2.41", activeManifest: active),
            now: { Date() },
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(downloader.invocationCount, 0)
        XCTAssertEqual(service.lastErrorMessage, RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage)
    }

    func testBlockedDownloadDoesNotInvokeDownloaderWhenBundledArtifactIsUnknown() async throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledManifestURL = sandbox.appendingPathComponent("bundle/manifest.json")
        var bundled = manifest("7.2.41", sourceKind: .bundled)
        bundled.upstreamAsset = "unknown-artifact.tar.gz"
        try writeManifest(bundled, to: bundledManifestURL)
        let downloader = StubUpdateDownloading()
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: downloader,
            store: StubUpdateBinaryStore(currentVersion: "7.2.41"),
            bundledManifestURL: bundledManifestURL,
            now: { Date() },
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertEqual(downloader.invocationCount, 0)
        XCTAssertEqual(service.lastErrorMessage, RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage)
    }

    func testInitClearsStalePendingStateAfterAutostartPromotion() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        try writeFullState(CLIProxyAPIUpdateState(lastAvailableVersion: "7.2.42", pendingVersion: "7.2.42"), to: paths.clipProxyUpdateStateFile)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.42", pending: nil)

        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

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
            now: { Date() },
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
            now: { Date() },
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
            now: { Date() },
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())
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

    func testApplyPendingNowRejectsUnreadablePendingManifestWithoutMutating() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() },
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
        )
        store.setPendingReadError(NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/Users/sensitive-user/pending-manifest.json"]
        ))

        XCTAssertThrowsError(try service.applyPendingNow()) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("Unable to read the staged CLIProxyAPI update. Refresh status and try again.")
            )
        }

        XCTAssertEqual(store.applyPendingCallCount, 0)
        XCTAssertEqual(service.pendingUpdate?.version, "7.2.42")
    }

    func testBlockedApplyDoesNotMutateStoreWhenActiveArtifactMismatches() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let active = manifest(
            "7.2.41",
            target: .init(operatingSystem: .darwin, architecture: .x86_64)
        )
        let store = StubUpdateBinaryStore(
            currentVersion: "7.2.41",
            activeManifest: active,
            pending: manifest("7.2.42")
        )
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            now: { Date() },
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )

        XCTAssertThrowsError(try service.applyPendingNow()) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite(RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage)
            )
        }
        XCTAssertEqual(store.applyPendingCallCount, 0)
    }

    func testBlockedScheduleDoesNotMutateStoreWhenBundledArtifactIsUnknown() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let bundledManifestURL = sandbox.appendingPathComponent("bundle/manifest.json")
        var bundled = manifest("7.2.41", sourceKind: .bundled)
        bundled.upstreamAsset = "unknown-artifact.tar.gz"
        try writeManifest(bundled, to: bundledManifestURL)
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41", pending: manifest("7.2.42"))
        let service = CLIProxyAPIUpdateService(
            paths: paths,
            checker: StubUpdateChecking(release: release("7.2.42")),
            downloader: StubUpdateDownloading(),
            store: store,
            bundledManifestURL: bundledManifestURL,
            now: { Date() },
            compatibilityAuthorizer: ArtifactMismatchAuthorizer()
        )

        XCTAssertFalse(service.schedulePendingForNextServerStart())
        XCTAssertEqual(store.schedulePendingCallCount, 0)
        XCTAssertEqual(service.lastErrorMessage, RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage)
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
            appLogger: logger,
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
            appLogger: logger,
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
            appLogger: logger,
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
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
            appLogger: logger,
            compatibilityAuthorizer: supportedCompatibilityAuthorizer()
        )
        await service.checkNow()

        await service.downloadAvailableUpdate()

        XCTAssertTrue(logger.events.contains(.update(target: .proxy, action: .download, result: .failed(.fileSystem))))
        XCTAssertTrue(store.savedPendingVersions.isEmpty)
    }

    func testApplyPendingNowRejectsNoPendingUpdateWithoutApplying() throws {
        let sandbox = try makeSandbox()
        let paths = ManagedPaths(rootDirectory: sandbox.appendingPathComponent("managed"))
        let store = StubUpdateBinaryStore(currentVersion: "7.2.41")
        let service = CLIProxyAPIUpdateService(paths: paths, checker: StubUpdateChecking(release: release("7.2.42")), downloader: StubUpdateDownloading(), store: store, now: { Date() }, compatibilityAuthorizer: supportedCompatibilityAuthorizer())

        XCTAssertThrowsError(try service.applyPendingNow()) { error in
            XCTAssertEqual(
                error as? CLIProxyManagerCommandError,
                .prerequisite("No staged CLIProxyAPI update is available. Run cpm update stage proxy first.")
            )
        }

        XCTAssertEqual(store.applyPendingCallCount, 0)
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

    private func manifest(
        _ version: String,
        sourceKind: CLIProxyAPIBinarySourceKind = .userUpdated,
        target: CLIProxyAPIArtifactTarget? = nil
    ) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: sourceKind, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api", target: target)
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

private func supportedCompatibilityAuthorizer() -> RuntimeCompatibilityPreflight {
    RuntimeCompatibilityPreflight(environment: SupportedMacOSEnvironment())
}

private struct SupportedMacOSEnvironment: RuntimeEnvironmentProviding {
    func snapshot() -> RuntimeEnvironmentSnapshot {
        RuntimeEnvironmentSnapshot(
            operatingSystem: .macOS(major: 15, minor: 0),
            architecture: .arm64,
            loginShell: "/bin/zsh"
        )
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
    private var active: CLIProxyAPIBinaryManifest?
    private var pending: CLIProxyAPIBinaryManifest?
    private var pendingReadError: Error?
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
        activeManifest: CLIProxyAPIBinaryManifest? = nil,
        pending: CLIProxyAPIBinaryManifest? = nil,
        currentAfterApply: String? = nil,
        scheduleError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.current = currentVersion.flatMap(CLIProxyAPIVersion.init)
        self.active = activeManifest
        self.pending = pending
        self.currentAfterApply = currentAfterApply.flatMap(CLIProxyAPIVersion.init)
        self.scheduleError = scheduleError
        self.saveError = saveError
    }

    func validatedCurrentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? { lock.withLock { current } }
    func activeManifest() throws -> CLIProxyAPIBinaryManifest? { lock.withLock { active } }
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest? {
        try lock.withLock {
            if let pendingReadError { throw pendingReadError }
            return pending
        }
    }

    func setPendingReadError(_ error: Error?) {
        lock.withLock { pendingReadError = error }
    }

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

import CLIProxyManagerCore
import Foundation

protocol CLIProxyAPIUpdateChecking: Sendable {
    func latestRelease() async throws -> CLIProxyAPIRelease
}

protocol CLIProxyAPIUpdateDownloading: Sendable {
    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult
    func cleanup(_ result: CLIProxyAPIBinaryVerificationResult)
}

extension CLIProxyAPIUpdateDownloading {
    func cleanup(_: CLIProxyAPIBinaryVerificationResult) {}
}

protocol CLIProxyAPIUpdateBinaryStoring: Sendable {
    func validatedCurrentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion?
    func activeManifest() throws -> CLIProxyAPIBinaryManifest?
    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest?
    func schedulePendingForNextStart() throws
    func applyPending() throws
}

extension CLIProxyAPIUpdateBinaryStoring {
    func activeManifest() throws -> CLIProxyAPIBinaryManifest? { nil }
}

struct CLIProxyAPIUpdateState: Codable, Equatable {
    var lastCheckedAt: String?
    var lastAvailableVersion: String?
    var lastDeferredVersion: String?
    var pendingVersion: String?
    var lastFailureMessage: String?
    var lastFailureAt: String?
}

enum CLIProxyAPIUpdateServiceState: Equatable {
    case idle
    case checking
    case updateAvailable
    case downloading
    case pending
    case upToDate
    case failed(String)
}

enum CLIProxyAPIAutomaticCheckResult: Equatable {
    case none
    case availableUpdate
    case pendingUpdate
}

extension CLIProxyAPIReleaseClient: CLIProxyAPIUpdateChecking {}

struct CLIProxyAPIUpdateDownloader: CLIProxyAPIUpdateDownloading {
    let client: CLIProxyAPIReleaseClient
    let verifier: CLIProxyAPIArchiveVerifier

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        let data = try await client.downloadArchive(for: release)
        return try await verifier.verify(archiveData: data, release: release)
    }

    func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) {
        verifier.cleanup(result)
    }
}

extension CLIProxyAPIBinaryStore: CLIProxyAPIUpdateBinaryStoring {}

@MainActor
final class CLIProxyAPIUpdateService: ObservableObject {
    @Published var state: CLIProxyAPIUpdateServiceState = .idle
    @Published var availableUpdate: CLIProxyAPIRelease?
    @Published var pendingUpdate: CLIProxyAPIBinaryManifest?
    @Published var currentVersionText: String = "Unknown"
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var lastErrorMessage: String?

    private let paths: ManagedPaths
    private let checker: any CLIProxyAPIUpdateChecking
    private let downloader: any CLIProxyAPIUpdateDownloading
    private let store: any CLIProxyAPIUpdateBinaryStoring
    private let bundledManifestURL: URL?
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let appLogger: any AppLogging
    private let compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        paths: ManagedPaths = ManagedPaths(),
        checker: any CLIProxyAPIUpdateChecking = CLIProxyAPIReleaseClient(),
        downloader: (any CLIProxyAPIUpdateDownloading)? = nil,
        store: (any CLIProxyAPIUpdateBinaryStoring)? = nil,
        bundledManifestURL: URL? = BundledProxyBinary.manifestURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        appLogger: any AppLogging = DisabledAppLogger(),
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight()
    ) {
        self.paths = paths
        self.checker = checker
        let concreteClient = CLIProxyAPIReleaseClient()
        self.downloader = downloader ?? CLIProxyAPIUpdateDownloader(client: concreteClient, verifier: CLIProxyAPIArchiveVerifier())
        self.store = store ?? CLIProxyAPIBinaryStore(paths: paths)
        self.bundledManifestURL = bundledManifestURL
        self.now = now
        self.fileManager = fileManager
        self.appLogger = appLogger
        self.compatibilityAuthorizer = compatibilityAuthorizer
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        refreshStoredStatus()
    }

    func checkAutomaticallyOnLaunch() async -> CLIProxyAPIAutomaticCheckResult {
        refreshStoredStatus()
        let storedState = loadState()
        if let lastCheckedAt = storedState.lastCheckedAt.flatMap(Self.parseDate), now().timeIntervalSince(lastCheckedAt) < 86_400 {
            return pendingUpdate == nil ? .none : .pendingUpdate
        }
        return await check(suppressDeferredVersion: true)
    }

    func checkNow() async {
        _ = await check(suppressDeferredVersion: false)
    }

    func deferAvailableUpdate() {
        guard let availableUpdate else { return }
        var state = loadState()
        state.lastDeferredVersion = availableUpdate.version.description
        saveState(state)
        self.availableUpdate = nil
        self.state = .idle
    }

    func downloadAvailableUpdate() async {
        guard let release = availableUpdate, !isUpdating else { return }
        do {
            try requireCompatibility(for: .stageProxyUpdate, candidate: .explicit(release.target))
        } catch {
            recordFailure(error)
            return
        }
        appLogger.record(.update(target: .proxy, action: .download, result: .started))
        isUpdating = true
        state = .downloading
        defer { isUpdating = false }

        let result: CLIProxyAPIBinaryVerificationResult
        do {
            result = try await downloader.downloadAndVerify(release)
        } catch {
            appLogger.record(.update(
                target: .proxy,
                action: .download,
                result: .failed(Self.downloadFailureKind(for: error))
            ))
            recordFailure(error)
            return
        }

        defer { downloader.cleanup(result) }
        do {
            try store.savePending(binaryURL: result.binaryURL, manifest: result.manifest)
            pendingUpdate = result.manifest
            availableUpdate = nil
            currentVersionText = (try? store.validatedCurrentVersion(bundledManifestURL: bundledManifestURL)?.description) ?? currentVersionText
            var updateState = loadState()
            updateState.pendingVersion = result.manifest.version
            updateState.lastAvailableVersion = nil
            saveState(reconciled(updateState, currentVersion: try? store.validatedCurrentVersion(bundledManifestURL: bundledManifestURL)))
            state = .pending
            appLogger.record(.update(target: .proxy, action: .download, result: .succeeded))
            appLogger.record(.debug(.updatePending))
        } catch {
            appLogger.record(.update(target: .proxy, action: .download, result: .failed(.fileSystem)))
            recordFailure(error)
        }
    }

    private func requireCompatibility(
        for action: CompatibilityAction,
        candidate: RuntimeCompatibilityArtifact
    ) throws {
        let artifacts: CompatibilityArtifacts
        do {
            artifacts = CompatibilityArtifacts(
                bundled: try bundledArtifact(),
                active: try compatibilityArtifact(for: store.activeManifest()),
                pending: candidate
            )
        } catch let error as CLIProxyManagerCommandError {
            throw error
        } catch {
            throw CLIProxyManagerCommandError.prerequisite(
                RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage
            )
        }
        do {
            try compatibilityAuthorizer.require(action, artifacts: artifacts)
        } catch {
            throw CLIProxyManagerCommandError.prerequisite(
                RuntimeCompatibilityBlocker(
                    report: compatibilityAuthorizer.staticReport(artifacts: artifacts)
                ).recoveryMessage
            )
        }
    }

    private func bundledArtifact() throws -> RuntimeCompatibilityArtifact? {
        guard let bundledManifestURL else { return nil }
        let manifest = try JSONDecoder().decode(
            CLIProxyAPIBinaryManifest.self,
            from: Data(contentsOf: bundledManifestURL)
        )
        return try compatibilityArtifact(forCandidate: manifest)
    }

    private func compatibilityArtifact(for manifest: CLIProxyAPIBinaryManifest?) throws -> RuntimeCompatibilityArtifact? {
        guard let manifest else { return nil }
        return try compatibilityArtifact(forCandidate: manifest)
    }

    private func compatibilityArtifact(forCandidate manifest: CLIProxyAPIBinaryManifest) throws -> RuntimeCompatibilityArtifact {
        guard let target = manifest.target else {
            guard manifest.upstreamAsset == "CLIProxyAPI_\(manifest.version)_darwin_aarch64.tar.gz" else {
                throw CLIProxyManagerCommandError.prerequisite(
                    RuntimeCompatibilityBlocker.unsupportedArtifactTarget.recoveryMessage
                )
            }
            return .legacy
        }
        return .explicit(target)
    }

    private static func downloadFailureKind(for error: Error) -> AppLogFailureKind {
        switch error {
        case is HTTPClientError, is URLError:
            return .network
        case is CLIProxyAPIArchiveVerifierError:
            return .updateVerification
        default:
            return .updateVerification
        }
    }

    func applyPendingNow() throws {
        refreshStoredStatus()
        if let pendingUpdate {
            try requireCompatibility(for: .applyProxyUpdate, candidate: try compatibilityArtifact(forCandidate: pendingUpdate))
        }
        appLogger.record(.update(target: .proxy, action: .apply, result: .started))
        do {
            try store.applyPending()
        } catch {
            appLogger.record(.update(target: .proxy, action: .apply, result: .failed(.fileSystem)))
            throw error
        }
        pendingUpdate = nil
        availableUpdate = nil
        let current = try? store.validatedCurrentVersion(bundledManifestURL: bundledManifestURL)
        currentVersionText = current?.description ?? currentVersionText
        var updateState = loadState()
        updateState.pendingVersion = nil
        updateState.lastAvailableVersion = nil
        updateState.lastDeferredVersion = reconcileDeferredVersion(updateState.lastDeferredVersion, currentVersion: current)
        saveState(updateState)
        refreshStoredStatus()
        state = .idle
        appLogger.record(.update(target: .proxy, action: .apply, result: .succeeded))
    }

    @discardableResult
    func schedulePendingForNextServerStart() -> Bool {
        refreshStoredStatus()
        guard let pendingUpdate else {
            recordFailure(CLIProxyAPIBinaryStoreError.missingPendingManifest)
            return false
        }
        do {
            try requireCompatibility(for: .scheduleProxyUpdate, candidate: try compatibilityArtifact(forCandidate: pendingUpdate))
            try store.schedulePendingForNextStart()
            refreshStoredStatus()
            state = .pending
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    func reloadStoredStatus() {
        refreshStoredStatus()
    }

    private func check(suppressDeferredVersion: Bool) async -> CLIProxyAPIAutomaticCheckResult {
        guard !isChecking else { return .none }
        appLogger.record(.update(target: .proxy, action: .check, result: .started))
        isChecking = true
        state = .checking
        var checkFailed = false
        defer {
            isChecking = false
            appLogger.record(.update(
                target: .proxy,
                action: .check,
                result: checkFailed ? .failed(.network) : .succeeded
            ))
        }
        do {
            let release = try await checker.latestRelease()
            var updateState = loadState()
            updateState.lastCheckedAt = Self.formatDate(now())
            updateState.lastAvailableVersion = release.version.description
            saveState(updateState)
            let current = try store.validatedCurrentVersion(bundledManifestURL: bundledManifestURL)
            currentVersionText = current?.description ?? "Unknown"
            updateState = reconciled(updateState, currentVersion: current)
            saveState(updateState)
            pendingUpdate = try? store.pendingManifest()
            if let pendingUpdate, pendingUpdate.parsedVersion == release.version {
                updateState.lastAvailableVersion = nil
                saveState(updateState)
                availableUpdate = nil
                state = .pending
                return .pendingUpdate
            }
            if let current, release.version <= current {
                availableUpdate = nil
                state = .upToDate
                return .none
            }
            if suppressDeferredVersion, updateState.lastDeferredVersion == release.version.description {
                availableUpdate = nil
                state = .idle
                return .none
            }
            availableUpdate = release
            state = .updateAvailable
            return .availableUpdate
        } catch {
            checkFailed = true
            recordFailure(error)
            return .none
        }
    }

    private func recordFailure(_ error: Error) {
        let message: String
        if let error = error as? CLIProxyManagerCommandError {
            message = error.description
        } else {
            message = error.localizedDescription
        }
        lastErrorMessage = message
        var state = loadState()
        let timestamp = Self.formatDate(now())
        state.lastCheckedAt = timestamp
        state.lastFailureMessage = message
        state.lastFailureAt = timestamp
        saveState(state)
        self.state = .failed(message)
    }

    private func refreshStoredStatus() {
        pendingUpdate = try? store.pendingManifest()
        let current = try? store.validatedCurrentVersion(bundledManifestURL: bundledManifestURL)
        currentVersionText = current?.description ?? "Unknown"
        let updateState = reconciled(loadState(), currentVersion: current)
        saveState(updateState)
        if let current, let availableUpdate, availableUpdate.version <= current {
            self.availableUpdate = nil
        }
    }

    private func reconciled(_ state: CLIProxyAPIUpdateState, currentVersion: CLIProxyAPIVersion?) -> CLIProxyAPIUpdateState {
        var reconciledState = state
        if let pending = try? store.pendingManifest() {
            reconciledState.pendingVersion = pending.version
        } else {
            reconciledState.pendingVersion = nil
        }
        guard let currentVersion else { return reconciledState }
        if reconciledState.lastAvailableVersion.flatMap(CLIProxyAPIVersion.init).map({ $0 <= currentVersion }) == true {
            reconciledState.lastAvailableVersion = nil
        }
        reconciledState.lastDeferredVersion = reconcileDeferredVersion(reconciledState.lastDeferredVersion, currentVersion: currentVersion)
        return reconciledState
    }

    private func reconcileDeferredVersion(_ version: String?, currentVersion: CLIProxyAPIVersion?) -> String? {
        guard let version, let currentVersion, let deferredVersion = CLIProxyAPIVersion(version) else { return version }
        return deferredVersion <= currentVersion ? nil : version
    }

    private func loadState() -> CLIProxyAPIUpdateState {
        guard fileManager.fileExists(atPath: paths.clipProxyUpdateStateFile.path),
              let data = try? Data(contentsOf: paths.clipProxyUpdateStateFile),
              let state = try? decoder.decode(CLIProxyAPIUpdateState.self, from: data) else {
            return CLIProxyAPIUpdateState()
        }
        return state
    }

    private func saveState(_ state: CLIProxyAPIUpdateState) {
        do {
            try fileManager.createDirectory(at: paths.clipProxyUpdateStateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: paths.clipProxyUpdateStateFile, options: .atomic)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

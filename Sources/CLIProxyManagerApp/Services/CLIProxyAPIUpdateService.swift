import CLIProxyManagerCore
import Foundation

protocol CLIProxyAPIUpdateChecking: Sendable {
    func latestRelease() async throws -> CLIProxyAPIRelease
}

protocol CLIProxyAPIUpdateDownloading: Sendable {
    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult
}

protocol CLIProxyAPIUpdateBinaryStoring: Sendable {
    func currentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion?
    func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws
    func pendingManifest() throws -> CLIProxyAPIBinaryManifest?
    func applyPending() throws
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

extension CLIProxyAPIReleaseClient: CLIProxyAPIUpdateChecking {}

struct CLIProxyAPIUpdateDownloader: CLIProxyAPIUpdateDownloading {
    let client: CLIProxyAPIReleaseClient
    let verifier: CLIProxyAPIArchiveVerifier

    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        let data = try await client.downloadArchive(for: release)
        return try await verifier.verify(archiveData: data, release: release)
    }
}

extension CLIProxyAPIBinaryStore: CLIProxyAPIUpdateBinaryStoring {
    public func currentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? {
        if let activeVersion = try activeManifest()?.parsedVersion {
            return activeVersion
        }
        guard let bundledManifestURL else { return nil }
        guard FileManager.default.fileExists(atPath: bundledManifestURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: Data(contentsOf: bundledManifestURL))
        return manifest.parsedVersion
    }
}

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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        paths: ManagedPaths = ManagedPaths(),
        checker: any CLIProxyAPIUpdateChecking = CLIProxyAPIReleaseClient(),
        downloader: (any CLIProxyAPIUpdateDownloading)? = nil,
        store: (any CLIProxyAPIUpdateBinaryStoring)? = nil,
        bundledManifestURL: URL? = BundledProxyBinary.manifestURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.checker = checker
        let concreteClient = CLIProxyAPIReleaseClient()
        self.downloader = downloader ?? CLIProxyAPIUpdateDownloader(client: concreteClient, verifier: CLIProxyAPIArchiveVerifier())
        self.store = store ?? CLIProxyAPIBinaryStore(paths: paths)
        self.bundledManifestURL = bundledManifestURL
        self.now = now
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.pendingUpdate = try? self.store.pendingManifest()
        self.currentVersionText = (try? self.store.currentVersion(bundledManifestURL: bundledManifestURL)?.description) ?? "Unknown"
    }

    func checkAutomaticallyOnLaunch() async {
        let state = loadState()
        if let lastCheckedAt = state.lastCheckedAt.flatMap(Self.parseDate), now().timeIntervalSince(lastCheckedAt) < 86_400 {
            return
        }
        await check(suppressDeferredVersion: true)
    }

    func checkNow() async {
        await check(suppressDeferredVersion: false)
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
        isUpdating = true
        state = .downloading
        defer { isUpdating = false }
        do {
            let result = try await downloader.downloadAndVerify(release)
            try store.savePending(binaryURL: result.binaryURL, manifest: result.manifest)
            pendingUpdate = result.manifest
            currentVersionText = (try? store.currentVersion(bundledManifestURL: bundledManifestURL)?.description) ?? currentVersionText
            var updateState = loadState()
            updateState.pendingVersion = result.manifest.version
            saveState(updateState)
            state = .pending
        } catch {
            recordFailure(error)
        }
    }

    func applyPendingNow() throws {
        try store.applyPending()
        currentVersionText = (try? store.currentVersion(bundledManifestURL: bundledManifestURL)?.description) ?? currentVersionText
        pendingUpdate = nil
        var updateState = loadState()
        updateState.pendingVersion = nil
        saveState(updateState)
        state = .idle
    }

    private func check(suppressDeferredVersion: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        state = .checking
        defer { isChecking = false }
        do {
            let release = try await checker.latestRelease()
            var updateState = loadState()
            updateState.lastCheckedAt = Self.formatDate(now())
            updateState.lastAvailableVersion = release.version.description
            saveState(updateState)
            let current = try store.currentVersion(bundledManifestURL: bundledManifestURL)
            currentVersionText = current?.description ?? "Unknown"
            if let current, release.version <= current {
                availableUpdate = nil
                state = .upToDate
                return
            }
            if suppressDeferredVersion, updateState.lastDeferredVersion == release.version.description {
                availableUpdate = nil
                state = .idle
                return
            }
            availableUpdate = release
            state = .updateAvailable
        } catch {
            recordFailure(error)
        }
    }

    private func recordFailure(_ error: Error) {
        let message = error.localizedDescription
        lastErrorMessage = message
        var state = loadState()
        let timestamp = Self.formatDate(now())
        state.lastCheckedAt = timestamp
        state.lastFailureMessage = message
        state.lastFailureAt = timestamp
        saveState(state)
        self.state = .failed(message)
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

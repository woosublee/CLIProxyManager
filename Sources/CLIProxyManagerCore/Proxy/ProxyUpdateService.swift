import Foundation

// MARK: - Result types

public enum ProxyUpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String?)
    case available(current: String?, release: CLIProxyAPIRelease)
    case pending(current: String?, pending: CLIProxyAPIBinaryManifest)
}

public struct ProxyUpdateStageResult: Equatable, Sendable {
    public let version: String
    public let staged: Bool

    public init(version: String, staged: Bool) {
        self.version = version
        self.staged = staged
    }
}

public struct ProxyUpdateApplyResult: Equatable, Sendable {
    public let version: String
    public let restartedProxy: Bool
    public let proxyReady: Bool

    public init(version: String, restartedProxy: Bool, proxyReady: Bool) {
        self.version = version
        self.restartedProxy = restartedProxy
        self.proxyReady = proxyReady
    }
}

// MARK: - Protocols

public protocol ProxyUpdateChecking: Sendable {
    func latestRelease() async throws -> CLIProxyAPIRelease
}

extension CLIProxyAPIReleaseClient: ProxyUpdateChecking {}

public protocol ProxyUpdateDownloading: Sendable {
    func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult
    func cleanup(_ result: CLIProxyAPIBinaryVerificationResult)
}

extension ProxyUpdateDownloading {
    func cleanup(_: CLIProxyAPIBinaryVerificationResult) {}
}

public protocol ProxyRuntimeUpdating: Sendable {
    func status() async throws -> ProxyRuntimeStatus
    func restart() async throws -> ProxyRuntimeStatus
}

// MARK: - Downloader

public struct ProxyUpdateDownloader: ProxyUpdateDownloading, Sendable {
    private let client: CLIProxyAPIReleaseClient
    private let verifier: CLIProxyAPIArchiveVerifier

    public init(
        client: CLIProxyAPIReleaseClient = CLIProxyAPIReleaseClient(),
        verifier: CLIProxyAPIArchiveVerifier = CLIProxyAPIArchiveVerifier()
    ) {
        self.client = client
        self.verifier = verifier
    }

    public func downloadAndVerify(_ release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        let archive = try await client.downloadArchive(for: release)
        return try await verifier.verify(archiveData: archive, release: release)
    }

    public func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) {
        verifier.cleanup(result)
    }
}

// MARK: - Service

extension ProxyUpdateService: ProxyUpdating {}

public struct ProxyUpdateService: Sendable {
    private let store: CLIProxyAPIBinaryStore
    private let checker: any ProxyUpdateChecking
    private let downloader: any ProxyUpdateDownloading
    private let runtime: (any ProxyRuntimeUpdating)?

    public init(
        paths: ManagedPaths = ManagedPaths(),
        checker: any ProxyUpdateChecking = CLIProxyAPIReleaseClient(),
        downloader: any ProxyUpdateDownloading = ProxyUpdateDownloader(),
        runtime: (any ProxyRuntimeUpdating)? = nil
    ) {
        self.store = CLIProxyAPIBinaryStore(paths: paths)
        self.checker = checker
        self.downloader = downloader
        self.runtime = runtime ?? ProxyRuntimeService(paths: paths)
    }

    init(
        store: CLIProxyAPIBinaryStore,
        checker: any ProxyUpdateChecking,
        downloader: any ProxyUpdateDownloading,
        runtime: (any ProxyRuntimeUpdating)?
    ) {
        self.store = store
        self.checker = checker
        self.downloader = downloader
        self.runtime = runtime
    }

    public func check() async throws -> ProxyUpdateCheckResult {
        let current = try store.validatedCurrentVersion(bundledManifestURL: nil)
        let currentString = current?.description

        if let pending = try? store.pendingManifest(),
           let pendingVersion = pending.parsedVersion,
           current.map({ pendingVersion > $0 }) ?? true {
            return .pending(current: currentString, pending: pending)
        }

        let release = try await checker.latestRelease()
        guard let releaseVersion = CLIProxyAPIVersion(release.version.description) else {
            return .available(current: currentString, release: release)
        }

        if let current, releaseVersion <= current {
            return .upToDate(current: currentString)
        }
        return .available(current: currentString, release: release)
    }

    public func stage() async throws -> ProxyUpdateStageResult {
        let checkResult = try await check()
        switch checkResult {
        case .upToDate(let current):
            return ProxyUpdateStageResult(version: current ?? "unknown", staged: false)
        case .pending(_, let pending):
            return ProxyUpdateStageResult(version: pending.version, staged: false)
        case .available(_, let release):
            let verification = try await downloader.downloadAndVerify(release)
            defer { downloader.cleanup(verification) }
            try store.savePending(binaryURL: verification.binaryURL, manifest: verification.manifest)
            return ProxyUpdateStageResult(version: verification.manifest.version, staged: true)
        }
    }

    public func apply() async throws -> ProxyUpdateApplyResult {
        guard let pending = try store.pendingManifest() else {
            throw CLIProxyManagerCommandError.prerequisite(
                "No staged CLIProxyAPI update is available. Run cpm update stage proxy first."
            )
        }
        let version = pending.version
        guard let runtime else {
            throw CLIProxyManagerCommandError.operation("Runtime service unavailable.")
        }
        let preStatus = try await runtime.status()
        try store.applyPending()
        guard preStatus.running else {
            return ProxyUpdateApplyResult(version: version, restartedProxy: false, proxyReady: false)
        }
        let postStatus = try await runtime.restart()
        guard postStatus.running else {
            throw CLIProxyManagerCommandError.operation(
                "CLIProxyAPI \(version) was applied, but the proxy did not become ready after restart. Check cpm logs for details."
            )
        }
        return ProxyUpdateApplyResult(version: version, restartedProxy: true, proxyReady: true)
    }
}

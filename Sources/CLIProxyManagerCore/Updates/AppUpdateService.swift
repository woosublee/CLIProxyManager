import Foundation

public struct AppUpdateArtifactDownloader: AppUpdateArtifactDownloading, Sendable {
    private let httpClient: any HTTPClient

    public init() {
        self.httpClient = URLSessionHTTPClient(session: URLSessionHTTPClient.makeExternalUpdateSession())
    }

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    public func download(_ url: URL) async throws -> Data {
        try await httpClient.get(url, headers: [:])
    }
}

public struct AppUpdateService: AppUpdating, Sendable {
    private let bundleLocator: any AppBundleLocating
    private let appcastClient: any AppcastFetching
    private let signatureVerifier: SparkleSignatureVerifier
    private let artifactDownloader: any AppUpdateArtifactDownloading
    private let stager: any AppUpdateStaging
    private let applier: AppUpdateApplier
    private let paths: ManagedPaths
    private let publicKey: String

    public init(
        paths: ManagedPaths = ManagedPaths(),
        bundleLocator: any AppBundleLocating = AppBundleLocator()
    ) {
        self.paths = paths
        self.bundleLocator = bundleLocator
        self.appcastClient = AppcastClient()
        self.signatureVerifier = SparkleSignatureVerifier()
        self.artifactDownloader = AppUpdateArtifactDownloader(httpClient: URLSessionHTTPClient())
        self.stager = AppUpdateStager(paths: paths)
        self.applier = AppUpdateApplier()
        self.publicKey = Self.loadPublicKey()
    }

    init(
        paths: ManagedPaths,
        bundleLocator: any AppBundleLocating,
        appcastClient: any AppcastFetching,
        artifactDownloader: any AppUpdateArtifactDownloading,
        stager: any AppUpdateStaging,
        applier: AppUpdateApplier,
        publicKey: String
    ) {
        self.paths = paths
        self.bundleLocator = bundleLocator
        self.appcastClient = appcastClient
        self.signatureVerifier = SparkleSignatureVerifier()
        self.artifactDownloader = artifactDownloader
        self.stager = stager
        self.applier = applier
        self.publicKey = publicKey
    }

    public func check() async throws -> AppUpdateCheckResult {
        let currentBuild: Int
        do {
            let bundle = try bundleLocator.locateInstalledApp()
            currentBuild = Int(bundle.build) ?? 0
        } catch {
            currentBuild = 0
        }
        let currentVersion = (try? bundleLocator.locateInstalledApp())?.version

        if let staged = try? stager.stagedUpdate(), staged.build > currentBuild {
            return .pending(current: currentVersion, pending: staged)
        }
        if let release = try await appcastClient.fetchLatest(afterBuild: currentBuild) {
            return .available(current: currentVersion, release: release)
        }
        return .upToDate(current: currentVersion)
    }

    public func stage() async throws -> AppUpdateStageResult {
        let checkResult = try await check()
        switch checkResult {
        case .upToDate(let current):
            return AppUpdateStageResult(version: current ?? "unknown", staged: false)
        case .pending(_, let staged):
            return AppUpdateStageResult(version: staged.version, staged: false)
        case .available(_, let release):
            let artifact = try await artifactDownloader.download(release.enclosureURL)
            try signatureVerifier.verify(
                artifact: artifact,
                expectedLength: release.expectedLength,
                base64Signature: release.edSignature,
                base64PublicKey: publicKey
            )
            let staged = try await stager.stage(release: release, artifact: artifact)
            return AppUpdateStageResult(version: staged.version, staged: true)
        }
    }

    public func apply() async throws -> AppUpdateApplyResult {
        guard let staged = try stager.stagedUpdate() else {
            throw CLIProxyManagerCommandError.prerequisite(
                "No staged CLIProxyManager update is available. Run cpm update stage app first."
            )
        }
        let stageDir = paths.appUpdateDirectory(build: staged.build)
        return try await applier.apply(staged: staged, stageDir: stageDir)
    }

    private static func loadPublicKey() -> String {
        // When cpm runs as a CLI tool, Bundle.main is not the app bundle.
        // Read SUPublicEDKey from the installed app's Info.plist instead.
        if let bundle = try? AppBundleLocator().locateInstalledApp(),
           let appBundle = Bundle(url: bundle.appURL),
           let key = appBundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           !key.isEmpty {
            return key
        }
        // Fallback: running inside the app bundle itself
        return Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    }
}

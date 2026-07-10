import Foundation

public struct AppUpdateRelease: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let enclosureURL: URL
    public let expectedLength: Int
    public let edSignature: String

    public init(version: String, build: Int, enclosureURL: URL, expectedLength: Int, edSignature: String) {
        self.version = version
        self.build = build
        self.enclosureURL = enclosureURL
        self.expectedLength = expectedLength
        self.edSignature = edSignature
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String?)
    case available(current: String?, release: AppUpdateRelease)
    case pending(current: String?, pending: StagedAppUpdate)
}

public struct AppUpdateStageResult: Equatable, Sendable {
    public let version: String
    public let staged: Bool

    public init(version: String, staged: Bool) {
        self.version = version
        self.staged = staged
    }
}

public struct AppUpdateApplyResult: Equatable, Sendable {
    public let version: String
    public let appRestarted: Bool
    public let appRestartWarning: String?

    public init(version: String, appRestarted: Bool, appRestartWarning: String?) {
        self.version = version
        self.appRestarted = appRestarted
        self.appRestartWarning = appRestartWarning
    }
}

public struct StagedAppUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let sourceURL: String
    public let artifactSHA256: String
    public let expectedLength: Int
    public let stagedAt: String

    public init(version: String, build: Int, sourceURL: String, artifactSHA256: String, expectedLength: Int, stagedAt: String) {
        self.version = version
        self.build = build
        self.sourceURL = sourceURL
        self.artifactSHA256 = artifactSHA256
        self.expectedLength = expectedLength
        self.stagedAt = stagedAt
    }
}

public protocol AppcastFetching: Sendable {
    func fetchLatest(afterBuild: Int) async throws -> AppUpdateRelease?
}

public protocol AppUpdateArtifactDownloading: Sendable {
    func download(_ url: URL) async throws -> Data
}

public protocol AppUpdating: Sendable {
    func check() async throws -> AppUpdateCheckResult
    func stage() async throws -> AppUpdateStageResult
    func apply() async throws -> AppUpdateApplyResult
}

public protocol AppUpdateStaging: Sendable {
    func stage(release: AppUpdateRelease, artifact: Data) async throws -> StagedAppUpdate
    func stagedUpdate() throws -> StagedAppUpdate?
}

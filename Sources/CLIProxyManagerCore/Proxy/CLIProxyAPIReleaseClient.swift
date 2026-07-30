import Foundation

public struct CLIProxyAPIRelease: Equatable, Sendable {
    public let version: CLIProxyAPIVersion
    public let tagName: String
    public let assetName: String
    public let assetURL: URL
    public let assetSha256: String
    public let target: CLIProxyAPIArtifactTarget

    public init(
        version: CLIProxyAPIVersion,
        tagName: String,
        assetName: String,
        assetURL: URL,
        assetSha256: String,
        target: CLIProxyAPIArtifactTarget = .darwinArm64
    ) {
        self.version = version
        self.tagName = tagName
        self.assetName = assetName
        self.assetURL = assetURL
        self.assetSha256 = assetSha256
        self.target = target
    }
}

public enum CLIProxyAPIReleaseClientError: Error, Equatable {
    case invalidVersion(String)
    case prereleaseUnsupported(String)
    case missingAsset(String)
    case missingChecksumAsset
    case missingChecksumEntry(String)
    case invalidAssetURL(String)
    case unsupportedTarget(CLIProxyAPIArtifactTarget)
}

public struct CLIProxyAPIReleaseClient: Sendable {
    private static let userAgentHeaders = ["User-Agent": "CLIProxyManager"]
    private static let githubReleaseHeaders = [
        "Accept": "application/vnd.github+json",
        "User-Agent": "CLIProxyManager"
    ]

    private let httpClient: any HTTPClient
    private let latestReleaseURL: URL

    public init(
        httpClient: any HTTPClient = URLSessionHTTPClient(session: URLSessionHTTPClient.makeExternalUpdateSession()),
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
    ) {
        self.httpClient = httpClient
        self.latestReleaseURL = latestReleaseURL
    }

    public func latestRelease() async throws -> CLIProxyAPIRelease {
        let data = try await httpClient.get(latestReleaseURL, headers: Self.githubReleaseHeaders)
        let githubRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = CLIProxyAPIVersion(githubRelease.tagName) else {
            throw CLIProxyAPIReleaseClientError.invalidVersion(githubRelease.tagName)
        }
        guard githubRelease.prerelease == false else {
            throw CLIProxyAPIReleaseClientError.prereleaseUnsupported(githubRelease.tagName)
        }
        let target = CLIProxyAPIArtifactTarget.darwinArm64
        guard let assetName = Self.assetName(for: version, target: target) else {
            throw CLIProxyAPIReleaseClientError.unsupportedTarget(target)
        }
        guard let archiveAsset = githubRelease.assets.first(where: { $0.name == assetName }) else {
            throw CLIProxyAPIReleaseClientError.missingAsset(assetName)
        }
        guard let checksumAsset = githubRelease.assets.first(where: { $0.name == "checksums.txt" }) else {
            throw CLIProxyAPIReleaseClientError.missingChecksumAsset
        }
        guard let archiveURL = URL(string: archiveAsset.browserDownloadURL) else {
            throw CLIProxyAPIReleaseClientError.invalidAssetURL(archiveAsset.browserDownloadURL)
        }
        guard let checksumURL = URL(string: checksumAsset.browserDownloadURL) else {
            throw CLIProxyAPIReleaseClientError.invalidAssetURL(checksumAsset.browserDownloadURL)
        }
        let checksums = try await httpClient.get(checksumURL, headers: Self.userAgentHeaders)
        guard let assetSha = Self.checksum(for: assetName, in: checksums) else {
            throw CLIProxyAPIReleaseClientError.missingChecksumEntry(assetName)
        }
        return CLIProxyAPIRelease(
            version: version,
            tagName: githubRelease.tagName,
            assetName: assetName,
            assetURL: archiveURL,
            assetSha256: assetSha,
            target: target
        )
    }

    public func downloadArchive(for release: CLIProxyAPIRelease) async throws -> Data {
        try await httpClient.get(release.assetURL, headers: Self.userAgentHeaders)
    }

    private static func assetName(for version: CLIProxyAPIVersion, target: CLIProxyAPIArtifactTarget) -> String? {
        guard target == .darwinArm64 else { return nil }
        return "CLIProxyAPI_\(version.description)_darwin_aarch64.tar.gz"
    }

    static func checksum(for assetName: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let filename = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : parts[1]
            if filename == assetName {
                return parts[0]
            }
        }
        return nil
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let assets: [GitHubAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

import Foundation

public enum CLIProxyAPIBinarySourceKind: String, Codable, Equatable, Sendable {
    case bundled
    case userUpdated = "user-updated"
}

public struct CLIProxyAPIBinaryManifest: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var commit: String
    public var builtAt: String
    public var sourceKind: CLIProxyAPIBinarySourceKind
    public var source: String
    public var upstreamRepository: String
    public var upstreamTag: String
    public var upstreamAsset: String
    public var upstreamAssetSha256: String
    public var vendoredBinaryName: String
    public var vendoredBinarySha256: String
    public var vendoredBinarySizeBytes: Int
    public var vendoredFromArchivePath: String
    public var downloadedAt: String?
    public var appliedAt: String?
    public var target: CLIProxyAPIArtifactTarget?

    public init(
        name: String,
        version: String,
        commit: String,
        builtAt: String,
        sourceKind: CLIProxyAPIBinarySourceKind,
        source: String,
        upstreamRepository: String,
        upstreamTag: String,
        upstreamAsset: String,
        upstreamAssetSha256: String,
        vendoredBinaryName: String,
        vendoredBinarySha256: String,
        vendoredBinarySizeBytes: Int,
        vendoredFromArchivePath: String,
        downloadedAt: String? = nil,
        appliedAt: String? = nil,
        target: CLIProxyAPIArtifactTarget? = nil
    ) {
        self.name = name
        self.version = version
        self.commit = commit
        self.builtAt = builtAt
        self.sourceKind = sourceKind
        self.source = source
        self.upstreamRepository = upstreamRepository
        self.upstreamTag = upstreamTag
        self.upstreamAsset = upstreamAsset
        self.upstreamAssetSha256 = upstreamAssetSha256
        self.vendoredBinaryName = vendoredBinaryName
        self.vendoredBinarySha256 = vendoredBinarySha256
        self.vendoredBinarySizeBytes = vendoredBinarySizeBytes
        self.vendoredFromArchivePath = vendoredFromArchivePath
        self.downloadedAt = downloadedAt
        self.appliedAt = appliedAt
        self.target = target
    }

    public var parsedVersion: CLIProxyAPIVersion? {
        CLIProxyAPIVersion(version)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, commit, builtAt, sourceKind, source
        case upstreamRepository, upstreamTag, upstreamAsset, upstreamAssetSha256
        case vendoredBinaryName, vendoredBinarySha256, vendoredBinarySizeBytes, vendoredFromArchivePath
        case downloadedAt, appliedAt, target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.commit = try c.decode(String.self, forKey: .commit)
        self.builtAt = try c.decode(String.self, forKey: .builtAt)
        self.sourceKind = try c.decodeIfPresent(CLIProxyAPIBinarySourceKind.self, forKey: .sourceKind) ?? .bundled
        self.source = try c.decode(String.self, forKey: .source)
        self.upstreamRepository = try c.decode(String.self, forKey: .upstreamRepository)
        self.upstreamTag = try c.decode(String.self, forKey: .upstreamTag)
        self.upstreamAsset = try c.decode(String.self, forKey: .upstreamAsset)
        self.upstreamAssetSha256 = try c.decode(String.self, forKey: .upstreamAssetSha256)
        self.vendoredBinaryName = try c.decode(String.self, forKey: .vendoredBinaryName)
        self.vendoredBinarySha256 = try c.decode(String.self, forKey: .vendoredBinarySha256)
        self.vendoredBinarySizeBytes = try c.decode(Int.self, forKey: .vendoredBinarySizeBytes)
        self.vendoredFromArchivePath = try c.decode(String.self, forKey: .vendoredFromArchivePath)
        self.downloadedAt = try c.decodeIfPresent(String.self, forKey: .downloadedAt)
        self.appliedAt = try c.decodeIfPresent(String.self, forKey: .appliedAt)
        self.target = try c.decodeIfPresent(CLIProxyAPIArtifactTarget.self, forKey: .target)
    }
}

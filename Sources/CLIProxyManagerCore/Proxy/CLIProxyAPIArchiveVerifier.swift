import Foundation

public enum CLIProxyAPIArchiveVerifierError: Error, Equatable {
    case archiveChecksumMismatch
    case extractionFailed(String)
    case missingExtractedBinary
    case versionCommandFailed(String)
    case versionMetadataMissing(String)
    case versionMismatch(expected: String, actual: String)
}

public struct CLIProxyAPIBinaryVerificationResult: Equatable, Sendable {
    public let binaryURL: URL
    public let manifest: CLIProxyAPIBinaryManifest
    public let temporaryDirectory: URL?

    public init(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest, temporaryDirectory: URL? = nil) {
        self.binaryURL = binaryURL
        self.manifest = manifest
        self.temporaryDirectory = temporaryDirectory
    }
}

public struct CLIProxyAPIArchiveVerifier: Sendable {
    private let runner: any ProcessRunning
    private let fileManager: FileManagerBox
    private let extractedBinaryLocator: @Sendable (URL) throws -> URL

    public init(
        runner: any ProcessRunning = ProcessRunner(timeout: 30),
        fileManager: FileManager = .default,
        extractedBinaryLocator: @escaping @Sendable (URL) throws -> URL = { $0.appendingPathComponent("cli-proxy-api") }
    ) {
        self.runner = runner
        self.fileManager = FileManagerBox(fileManager)
        self.extractedBinaryLocator = extractedBinaryLocator
    }

    public func verify(archiveData: Data, release: CLIProxyAPIRelease) async throws -> CLIProxyAPIBinaryVerificationResult {
        guard archiveData.sha256HexDigest() == release.assetSha256 else {
            throw CLIProxyAPIArchiveVerifierError.archiveChecksumMismatch
        }
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxyapi-update")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        var didTransferTemporaryDirectoryOwnership = false
        defer {
            if !didTransferTemporaryDirectoryOwnership {
                try? fileManager.removeItem(at: tempDirectory)
            }
        }
        let archiveURL = tempDirectory.appendingPathComponent(release.assetName)
        try archiveData.write(to: archiveURL, options: .atomic)

        let extraction = await runner.run("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", tempDirectory.path])
        guard extraction.exitCode == 0 else {
            throw CLIProxyAPIArchiveVerifierError.extractionFailed(extraction.stderr)
        }
        let binaryURL = try extractedBinaryLocator(tempDirectory)
        guard fileManager.fileExists(atPath: binaryURL.path) else {
            throw CLIProxyAPIArchiveVerifierError.missingExtractedBinary
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        let version = await runner.run(binaryURL.path, ["--version"])
        let versionOutput = version.stdout + "\n" + version.stderr
        guard let metadata = Self.parseVersionLine(versionOutput) else {
            if version.exitCode == 0 {
                throw CLIProxyAPIArchiveVerifierError.versionMetadataMissing(version.stdout)
            }
            throw CLIProxyAPIArchiveVerifierError.versionCommandFailed(version.stderr)
        }
        guard metadata.version == release.version.description else {
            throw CLIProxyAPIArchiveVerifierError.versionMismatch(expected: release.version.description, actual: metadata.version)
        }
        let size = try binaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let manifest = CLIProxyAPIBinaryManifest(
            name: "cliproxyapi",
            version: metadata.version,
            commit: metadata.commit,
            builtAt: metadata.builtAt,
            sourceKind: .userUpdated,
            source: release.assetURL.absoluteString,
            upstreamRepository: "router-for-me/CLIProxyAPI",
            upstreamTag: release.tagName,
            upstreamAsset: release.assetName,
            upstreamAssetSha256: release.assetSha256,
            vendoredBinaryName: "cliproxyapi",
            vendoredBinarySha256: try binaryURL.sha256HexDigest(),
            vendoredBinarySizeBytes: size,
            vendoredFromArchivePath: "cli-proxy-api",
            downloadedAt: ISO8601DateFormatter().string(from: Date()),
            target: release.target
        )
        didTransferTemporaryDirectoryOwnership = true
        return CLIProxyAPIBinaryVerificationResult(binaryURL: binaryURL, manifest: manifest, temporaryDirectory: tempDirectory)
    }

    public func cleanup(_ result: CLIProxyAPIBinaryVerificationResult) {
        guard let temporaryDirectory = result.temporaryDirectory else { return }
        try? fileManager.removeItem(at: temporaryDirectory)
    }

    static func parseVersionLine(_ output: String) -> (version: String, commit: String, builtAt: String)? {
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init) {
            guard line.contains("CLIProxyAPI Version:") else { continue }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            let version = parts[0].replacingOccurrences(of: "CLIProxyAPI Version:", with: "").trimmingCharacters(in: .whitespaces)
            let commit = parts[1].replacingOccurrences(of: "Commit:", with: "").trimmingCharacters(in: .whitespaces)
            let builtAt = parts[2].replacingOccurrences(of: "BuiltAt:", with: "").trimmingCharacters(in: .whitespaces)
            guard version.isEmpty == false, commit.isEmpty == false, builtAt.isEmpty == false else { return nil }
            return (version, commit, builtAt)
        }
        return nil
    }
}

private final class FileManagerBox: @unchecked Sendable {
    private let fileManager: FileManager

    init(_ fileManager: FileManager) {
        self.fileManager = fileManager
    }

    var temporaryDirectory: URL {
        fileManager.temporaryDirectory
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

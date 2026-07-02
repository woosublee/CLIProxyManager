import CryptoKit
import Foundation

public enum CLIProxyAPIBinaryStoreError: Error, Equatable {
    case missingBundledBinary
    case missingBundledManifest
    case invalidManifestVersion(String)
    case binaryChecksumMismatch
    case binarySizeMismatch
    case missingPendingBinary
    case missingPendingManifest
}

public struct CLIProxyAPIBinaryStore: @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ManagedPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func activeManifest() throws -> CLIProxyAPIBinaryManifest? {
        try readManifestIfExists(paths.activeClipProxyManifest)
    }

    public func pendingManifest() throws -> CLIProxyAPIBinaryManifest? {
        try readManifestIfExists(paths.pendingClipProxyManifest)
    }

    public func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        try savePending(binaryURL: binaryURL, manifest: manifest, validate: true)
    }

    public func savePending(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest, validate: Bool) throws {
        if validate {
            try validateBinary(at: binaryURL, manifest: manifest)
        }
        try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
        try replaceFile(from: binaryURL, to: paths.pendingClipProxyBinary)
        try writeManifest(manifest, to: paths.pendingClipProxyManifest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.pendingClipProxyBinary.path)
    }

    public func applyPending() throws {
        guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) else {
            throw CLIProxyAPIBinaryStoreError.missingPendingBinary
        }
        guard var manifest = try pendingManifest() else {
            throw CLIProxyAPIBinaryStoreError.missingPendingManifest
        }

        try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
        manifest.appliedAt = Self.iso8601Now()
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)

        let backup = paths.clipProxyDirectory.appendingPathComponent("cliproxyapi.backup")
        if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: paths.clipProxyBinary, to: backup)
        }

        do {
            try fileManager.moveItem(at: paths.pendingClipProxyBinary, to: paths.clipProxyBinary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
            try writeManifest(manifest, to: paths.activeClipProxyManifest)
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: paths.clipProxyBinary)
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: paths.clipProxyBinary)
            }
            throw error
        }
    }

    public func prepareActiveBinary(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws {
        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                return
            }
            throw CLIProxyAPIBinaryStoreError.missingBundledBinary
        }
        guard let bundledManifestURL, let bundledManifest = try readManifestIfExists(bundledManifestURL) else {
            throw CLIProxyAPIBinaryStoreError.missingBundledManifest
        }
        guard let bundledVersion = bundledManifest.parsedVersion else {
            throw CLIProxyAPIBinaryStoreError.invalidManifestVersion(bundledManifest.version)
        }

        let active = try validActiveManifest()
        let activeVersion = active?.parsedVersion
        try applyUsablePendingIfNewest(bundledVersion: bundledVersion, activeVersion: activeVersion)

        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path), let active = try activeManifest() else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            return
        }
        guard let activeVersion = active.parsedVersion else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            return
        }

        switch active.sourceKind {
        case .bundled:
            let activeBinaryMatches = try binaryMatches(paths.clipProxyBinary, manifest: active)
            if activeVersion < bundledVersion || !activeBinaryMatches {
                try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            } else {
                try ensureExecutable(paths.clipProxyBinary)
            }
        case .userUpdated:
            let activeBinaryMatches = try binaryMatches(paths.clipProxyBinary, manifest: active)
            if activeVersion < bundledVersion || !activeBinaryMatches {
                try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            } else {
                try ensureExecutable(paths.clipProxyBinary)
            }
        }
    }

    private func validActiveManifest() throws -> CLIProxyAPIBinaryManifest? {
        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path),
              let active = try activeManifest(),
              active.parsedVersion != nil,
              try binaryMatches(paths.clipProxyBinary, manifest: active) else {
            return nil
        }
        return active
    }

    private func applyUsablePendingIfNewest(bundledVersion: CLIProxyAPIVersion, activeVersion: CLIProxyAPIVersion?) throws {
        guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) || fileManager.fileExists(atPath: paths.pendingClipProxyManifest.path) else {
            return
        }
        guard let pending = try? pendingManifest(),
              let pendingVersion = pending.parsedVersion,
              pendingVersion > bundledVersion,
              activeVersion.map({ pendingVersion > $0 }) ?? true,
              (try? binaryMatches(paths.pendingClipProxyBinary, manifest: pending)) == true else {
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            return
        }
        try applyPending()
    }

    private func installBundled(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        try fileManager.createDirectory(at: paths.clipProxyDirectory, withIntermediateDirectories: true)
        try replaceFile(from: binaryURL, to: paths.clipProxyBinary)
        var active = manifest
        active.sourceKind = .bundled
        active.appliedAt = Self.iso8601Now()
        try writeManifest(active, to: paths.activeClipProxyManifest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
    }

    private func readManifestIfExists(_ url: URL) throws -> CLIProxyAPIBinaryManifest? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(CLIProxyAPIBinaryManifest.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ manifest: CLIProxyAPIBinaryManifest, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func validateBinary(at url: URL, manifest: CLIProxyAPIBinaryManifest) throws {
        if try Data(contentsOf: url).sha256HexDigest() != manifest.vendoredBinarySha256 {
            throw CLIProxyAPIBinaryStoreError.binaryChecksumMismatch
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        if size != manifest.vendoredBinarySizeBytes {
            throw CLIProxyAPIBinaryStoreError.binarySizeMismatch
        }
    }

    private func binaryMatches(_ url: URL, manifest: CLIProxyAPIBinaryManifest) throws -> Bool {
        do {
            try validateBinary(at: url, manifest: manifest)
            return true
        } catch {
            return false
        }
    }

    private func ensureExecutable(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func replaceFile(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp")
        let backup = directory.appendingPathComponent(".\(destination.lastPathComponent).backup")
        try? fileManager.removeItem(at: temporary)
        try? fileManager.removeItem(at: backup)
        try fileManager.copyItem(at: source, to: temporary)
        let hadDestination = fileManager.fileExists(atPath: destination.path)
        if hadDestination {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if hadDestination, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

extension Data {
    func sha256HexDigest() -> String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

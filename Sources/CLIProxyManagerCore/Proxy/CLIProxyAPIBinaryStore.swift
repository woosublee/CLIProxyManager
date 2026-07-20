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
    private static let operationLock = NSLock()

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
        try Self.operationLock.withLock {
            try savePendingLocked(binaryURL: binaryURL, manifest: manifest, validate: validate)
        }
    }

    public func applyPending() throws {
        try Self.operationLock.withLock {
            try applyPendingLocked()
        }
    }

    public func schedulePendingForNextStart() throws {
        try Self.operationLock.withLock {
            guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path) else {
                throw CLIProxyAPIBinaryStoreError.missingPendingBinary
            }
            guard let manifest = try pendingManifest() else {
                throw CLIProxyAPIBinaryStoreError.missingPendingManifest
            }
            try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
            try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
            try Data("scheduled\n".utf8).write(
                to: paths.pendingClipProxyApplyOnNextStartMarker,
                options: .atomic
            )
        }
    }

    public func prepareActiveBinary(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws {
        try Self.operationLock.withLock {
            try prepareActiveBinaryLocked(bundledBinaryURL: bundledBinaryURL, bundledManifestURL: bundledManifestURL)
        }
    }

    public func validatedCurrentVersion(bundledManifestURL: URL?) throws -> CLIProxyAPIVersion? {
        try Self.operationLock.withLock {
            if let activeVersion = validActiveManifest()?.parsedVersion {
                return activeVersion
            }
            guard let bundledManifestURL else { return nil }
            guard fileManager.fileExists(atPath: bundledManifestURL.path) else { return nil }
            return try readManifestIfExists(bundledManifestURL)?.parsedVersion
        }
    }

    private func savePendingLocked(binaryURL: URL, manifest: CLIProxyAPIBinaryManifest, validate: Bool) throws {
        if validate {
            try validateBinary(at: binaryURL, manifest: manifest)
        }
        try clearPendingApplyOnNextStartMarker()
        try fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
        try replaceFile(from: binaryURL, to: paths.pendingClipProxyBinary)
        try writeManifest(manifest, to: paths.pendingClipProxyManifest)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.pendingClipProxyBinary.path)
    }

    private func applyPendingLocked() throws {
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

        var movedPendingToActive = false
        do {
            try fileManager.moveItem(at: paths.pendingClipProxyBinary, to: paths.clipProxyBinary)
            movedPendingToActive = true
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.clipProxyBinary.path)
            try writeManifest(manifest, to: paths.activeClipProxyManifest)
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            try? fileManager.removeItem(at: backup)
        } catch {
            if movedPendingToActive, fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                try? fileManager.createDirectory(at: paths.pendingClipProxyDirectory, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: paths.pendingClipProxyBinary)
                try? fileManager.moveItem(at: paths.clipProxyBinary, to: paths.pendingClipProxyBinary)
            } else {
                try? fileManager.removeItem(at: paths.clipProxyBinary)
            }
            if fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: paths.clipProxyBinary)
            }
            throw error
        }
    }

    private func prepareActiveBinaryLocked(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws {
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

        let active = validActiveManifest()
        let activeVersion = active?.parsedVersion
        try applyUsablePendingIfNewest(bundledVersion: bundledVersion, activeVersion: activeVersion)

        guard let active = validActiveManifest(), let activeVersion = active.parsedVersion else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            return
        }

        switch active.sourceKind {
        case .bundled, .userUpdated:
            if activeVersion < bundledVersion {
                try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            } else {
                try ensureExecutable(paths.clipProxyBinary)
            }
        }
    }

    private func validActiveManifest() -> CLIProxyAPIBinaryManifest? {
        guard fileManager.fileExists(atPath: paths.clipProxyBinary.path),
              let active = try? activeManifest(),
              active.parsedVersion != nil,
              binaryMatches(paths.clipProxyBinary, manifest: active) else {
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
              binaryMatches(paths.pendingClipProxyBinary, manifest: pending) else {
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            return
        }
        guard isPendingScheduledForNextStart() else { return }
        try applyPendingLocked()
    }

    private func isPendingScheduledForNextStart() -> Bool {
        fileManager.fileExists(atPath: paths.pendingClipProxyApplyOnNextStartMarker.path)
    }

    private func clearPendingApplyOnNextStartMarker() throws {
        guard isPendingScheduledForNextStart() else { return }
        try fileManager.removeItem(at: paths.pendingClipProxyApplyOnNextStartMarker)
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
        if try url.sha256HexDigest() != manifest.vendoredBinarySha256 {
            throw CLIProxyAPIBinaryStoreError.binaryChecksumMismatch
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        if size != manifest.vendoredBinarySizeBytes {
            throw CLIProxyAPIBinaryStoreError.binarySizeMismatch
        }
    }

    private func binaryMatches(_ url: URL, manifest: CLIProxyAPIBinaryManifest) -> Bool {
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


extension URL {
    func sha256HexDigest() throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: self)
        defer { try? fileHandle.close() }
        var sha256 = SHA256()
        while let data = try fileHandle.read(upToCount: 64 * 1024), data.isEmpty == false {
            sha256.update(data: data)
        }
        return sha256.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

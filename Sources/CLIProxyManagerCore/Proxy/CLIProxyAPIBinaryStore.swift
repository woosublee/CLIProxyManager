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
    case unsupportedArtifactTarget
}

public enum BundledProxyReconciliationResult: Equatable, Sendable {
    case unchanged(version: CLIProxyAPIVersion)
    case installed(previousVersion: CLIProxyAPIVersion?, newVersion: CLIProxyAPIVersion)
    case recoveredInvalidActive(newVersion: CLIProxyAPIVersion)

    public var activeVersion: CLIProxyAPIVersion {
        switch self {
        case .unchanged(let version):
            return version
        case .installed(_, let newVersion), .recoveredInvalidActive(let newVersion):
            return newVersion
        }
    }

    public var didChangeBinary: Bool {
        switch self {
        case .unchanged:
            return false
        case .installed, .recoveredInvalidActive:
            return true
        }
    }
}

public struct CLIProxyAPIBinaryStore: @unchecked Sendable {
    private static let operationLock = NSLock()

    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        paths: ManagedPaths,
        fileManager: FileManager = .default,
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.compatibilityAuthorizer = compatibilityAuthorizer
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
            guard var manifest = try pendingManifest() else {
                throw CLIProxyAPIBinaryStoreError.missingPendingManifest
            }
            try requireCompatibleTarget(manifest: manifest, action: .scheduleProxyUpdate)
            try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
            inferLegacyTarget(in: &manifest)
            try writeManifest(manifest, to: paths.pendingClipProxyManifest)
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

    public func reconcileBundledBinary(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult {
        try Self.operationLock.withLock {
            try reconcileBundledBinaryLocked(
                bundledBinaryURL: bundledBinaryURL,
                bundledManifestURL: bundledManifestURL
            )
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
        try requireCompatibleTarget(manifest: manifest, action: .stageProxyUpdate)
        var manifest = manifest
        if validate {
            try validateBinary(at: binaryURL, manifest: manifest)
            inferLegacyTarget(in: &manifest)
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

        try requireCompatibleTarget(manifest: manifest, action: .applyProxyUpdate)
        if let active = try activeManifest() {
            try requireCompatibleTarget(manifest: active, action: .applyProxyUpdate)
        }
        try validateBinary(at: paths.pendingClipProxyBinary, manifest: manifest)
        inferLegacyTarget(in: &manifest)
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

    private func reconcileBundledBinaryLocked(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult {
        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            throw CLIProxyAPIBinaryStoreError.missingBundledBinary
        }
        guard let bundledManifestURL,
              var bundledManifest = try readManifestIfExists(bundledManifestURL) else {
            throw CLIProxyAPIBinaryStoreError.missingBundledManifest
        }
        try requireCompatibleTarget(manifest: bundledManifest, action: .recoverProxyArtifact)
        if let active = try? activeManifest() {
            try requireCompatibleTarget(manifest: active, action: .recoverProxyArtifact)
        }
        try requireCompatiblePendingTargetIfPresent(action: .recoverProxyArtifact)
        guard let bundledVersion = bundledManifest.parsedVersion else {
            throw CLIProxyAPIBinaryStoreError.invalidManifestVersion(bundledManifest.version)
        }
        try validateBinary(at: bundledBinaryURL, manifest: bundledManifest)
        inferLegacyTarget(in: &bundledManifest)

        let existingVersion = (try? activeManifest())?.parsedVersion
        guard let active = validActiveManifest(), let activeVersion = active.parsedVersion else {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            try removePendingUnlessNewer(than: bundledVersion)
            return .recoveredInvalidActive(newVersion: bundledVersion)
        }

        if activeVersion < bundledVersion {
            try installBundled(binaryURL: bundledBinaryURL, manifest: bundledManifest)
            try removePendingUnlessNewer(than: bundledVersion)
            return .installed(previousVersion: existingVersion, newVersion: bundledVersion)
        }

        try ensureExecutable(paths.clipProxyBinary)
        try removePendingUnlessNewer(than: activeVersion)
        return .unchanged(version: activeVersion)
    }

    private func prepareActiveBinaryLocked(bundledBinaryURL: URL?, bundledManifestURL: URL?) throws {
        guard let bundledBinaryURL, fileManager.fileExists(atPath: bundledBinaryURL.path) else {
            if fileManager.fileExists(atPath: paths.clipProxyBinary.path) {
                return
            }
            throw CLIProxyAPIBinaryStoreError.missingBundledBinary
        }
        guard let bundledManifestURL, var bundledManifest = try readManifestIfExists(bundledManifestURL) else {
            throw CLIProxyAPIBinaryStoreError.missingBundledManifest
        }
        try requireCompatibleTarget(manifest: bundledManifest, action: .recoverProxyArtifact)
        if let active = try? activeManifest() {
            try requireCompatibleTarget(manifest: active, action: .recoverProxyArtifact)
        }
        guard let bundledVersion = bundledManifest.parsedVersion else {
            throw CLIProxyAPIBinaryStoreError.invalidManifestVersion(bundledManifest.version)
        }
        try validateBinary(at: bundledBinaryURL, manifest: bundledManifest)
        inferLegacyTarget(in: &bundledManifest)

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
        guard let pending = try? pendingManifest() else {
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            return
        }
        try requireCompatibleTarget(manifest: pending, action: .applyProxyUpdate)
        guard let pendingVersion = pending.parsedVersion,
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

    private func removePendingUnlessNewer(than activeVersion: CLIProxyAPIVersion) throws {
        guard fileManager.fileExists(atPath: paths.pendingClipProxyBinary.path)
                || fileManager.fileExists(atPath: paths.pendingClipProxyManifest.path) else {
            return
        }
        guard let pending = try? pendingManifest() else {
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            return
        }
        try requireCompatibleTarget(manifest: pending, action: .recoverProxyArtifact)
        guard let pendingVersion = pending.parsedVersion,
              pendingVersion > activeVersion,
              binaryMatches(paths.pendingClipProxyBinary, manifest: pending) else {
            try? fileManager.removeItem(at: paths.pendingClipProxyDirectory)
            return
        }
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

    private func requireCompatiblePendingTargetIfPresent(action: CompatibilityAction) throws {
        guard let pending = try? pendingManifest() else { return }
        try requireCompatibleTarget(manifest: pending, action: action)
    }

    private func requireCompatibleTarget(
        manifest: CLIProxyAPIBinaryManifest,
        action: CompatibilityAction
    ) throws {
        let target: CLIProxyAPIArtifactTarget
        if let explicitTarget = manifest.target {
            target = explicitTarget
        } else if manifest.upstreamAsset == legacyProductionAsset(for: manifest) {
            target = .darwinArm64
        } else {
            throw CLIProxyAPIBinaryStoreError.unsupportedArtifactTarget
        }

        let artifacts = CompatibilityArtifacts(bundled: nil, active: nil, pending: .explicit(target))
        let report = compatibilityAuthorizer.staticReport(artifacts: artifacts)
        if report.findings.contains(where: { finding in
            if case .unsupportedArtifactTarget = finding {
                return true
            }
            return false
        }) {
            throw CLIProxyAPIBinaryStoreError.unsupportedArtifactTarget
        }
        try compatibilityAuthorizer.require(action, artifacts: artifacts)
    }

    private func inferLegacyTarget(in manifest: inout CLIProxyAPIBinaryManifest) {
        guard manifest.target == nil, manifest.upstreamAsset == legacyProductionAsset(for: manifest) else {
            return
        }
        manifest.target = .darwinArm64
    }

    private func legacyProductionAsset(for manifest: CLIProxyAPIBinaryManifest) -> String {
        "CLIProxyAPI_\(manifest.version)_darwin_aarch64.tar.gz"
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

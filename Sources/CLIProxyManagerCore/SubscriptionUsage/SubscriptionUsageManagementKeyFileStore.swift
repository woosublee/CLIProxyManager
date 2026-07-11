import Darwin
import Foundation

public struct SubscriptionUsageManagementKeyFileStore: SubscriptionUsageManagementKeyProviding, @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let key: String
    }

    private let secretFile: URL
    private let fileManager: FileManager
    private let account = "subscription-usage-management-key"

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.secretFile = paths.subscriptionUsageManagementKeyFile
        self.fileManager = fileManager
    }

    public func isConfigured() -> Bool {
        (try? managementKey()).map { !$0.isEmpty } ?? false
    }

    public func createManagementKeyIfNeeded() throws -> Bool {
        try withExclusiveLock {
            do {
                _ = try readManagementKeyLocked()
                return false
            } catch SecretStoreError.missingSecret {
                try writeManagementKeyLocked(generateManagementKey())
                return true
            }
        }
    }

    public func setManagementKey(_ value: String) throws {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            throw SecretStoreError.writeFailed(account)
        }

        try withExclusiveLock {
            do {
                _ = try readManagementKeyLocked()
            } catch SecretStoreError.missingSecret {
                // A missing file is safe to create. Other invalid file states are rejected.
            }
            try writeManagementKeyLocked(normalizedValue)
        }
    }

    public func deleteManagementKey() throws {
        try withExclusiveLock {
            guard try validateSecretFileForDeletionLocked() else { return }
            guard unlink(secretFile.path) == 0 else {
                throw SecretStoreError.writeFailed(account)
            }
        }
    }

    func managementKey() throws -> String {
        try withExclusiveLock {
            try readManagementKeyLocked()
        }
    }

    private func readManagementKeyLocked() throws -> String {
        let fileDescriptor = open(secretFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT {
                throw SecretStoreError.missingSecret(account)
            }
            throw SecretStoreError.readFailed(account)
        }
        defer { close(fileDescriptor) }

        try validateSecretFileDescriptor(fileDescriptor)

        do {
            let data = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let key = envelope.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard envelope.version == 1, !key.isEmpty else {
                throw SecretStoreError.readFailed(account)
            }
            return key
        } catch let error as SecretStoreError {
            throw error
        } catch {
            throw SecretStoreError.readFailed(account)
        }
    }

    private func validateSecretFileForDeletionLocked() throws -> Bool {
        let fileDescriptor = open(secretFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT {
                return false
            }
            throw SecretStoreError.readFailed(account)
        }
        defer { close(fileDescriptor) }

        try validateSecretFileDescriptor(fileDescriptor)
        return true
    }

    private func validateSecretFileDescriptor(_ fileDescriptor: Int32) throws {
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == getuid(),
              Int(fileStatus.st_mode) & 0o777 == 0o600 else {
            throw SecretStoreError.readFailed(account)
        }
    }

    private func writeManagementKeyLocked(_ key: String) throws {
        let envelopeData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            envelopeData = try encoder.encode(Envelope(version: 1, key: key))
        } catch {
            throw SecretStoreError.writeFailed(account)
        }

        let temporaryFile = secretFile.deletingLastPathComponent()
            .appendingPathComponent(".subscription-usage-management-key-\(UUID().uuidString).json")
        var temporaryFileExists = false
        defer {
            if temporaryFileExists {
                _ = unlink(temporaryFile.path)
            }
        }

        let fileDescriptor = open(
            temporaryFile.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        temporaryFileExists = true
        defer { close(fileDescriptor) }

        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        try writeAll(envelopeData, to: fileDescriptor)
        guard fsync(fileDescriptor) == 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        guard rename(temporaryFile.path, secretFile.path) == 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        temporaryFileExists = false
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SecretStoreError.writeFailed(account)
            }

            var writtenBytes = 0
            while writtenBytes < buffer.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: writtenBytes),
                    buffer.count - writtenBytes
                )
                guard result > 0 else {
                    throw SecretStoreError.writeFailed(account)
                }
                writtenBytes += result
            }
        }
    }

    private func generateManagementKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            arc4random_buf(buffer.baseAddress, buffer.count)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try fileManager.createDirectory(
                at: secretFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SecretStoreError.writeFailed(account)
        }

        let lockFile = secretFile.appendingPathExtension("lock")
        let fileDescriptor = open(
            lockFile.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        defer { close(fileDescriptor) }

        var lockStatus = stat()
        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0,
              fstat(fileDescriptor, &lockStatus) == 0,
              lockStatus.st_mode & S_IFMT == S_IFREG,
              lockStatus.st_uid == getuid(),
              flock(fileDescriptor, LOCK_EX) == 0 else {
            throw SecretStoreError.writeFailed(account)
        }
        defer { _ = flock(fileDescriptor, LOCK_UN) }

        return try body()
    }
}

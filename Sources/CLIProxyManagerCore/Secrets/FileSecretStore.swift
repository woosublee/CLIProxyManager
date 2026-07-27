import Darwin
import Foundation

public struct FileSecretStore: SecretStore, @unchecked Sendable {
    private struct Envelope: Codable {
        let version: Int
        let value: String
    }

    private let paths: ManagedPaths
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func get(_ key: SecretReference) throws -> String {
        try withExclusiveLock(for: key) {
            try readSecretLocked(for: key)
        }
    }

    public func set(_ value: String, for key: SecretReference) throws {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            throw SecretStoreError.writeFailed(key.rawValue)
        }

        try withExclusiveLock(for: key) {
            try writeSecretLocked(normalizedValue, for: key)
        }
    }

    public func delete(_ key: SecretReference) throws {
        try withExclusiveLock(for: key) {
            let secretFile = paths.apiKeyFile(for: key)
            guard try validateSecretFileForDeletionLocked(secretFile, key: key) else { return }
            guard unlink(secretFile.path) == 0 else {
                throw SecretStoreError.writeFailed(key.rawValue)
            }
        }
    }

    private func readSecretLocked(for key: SecretReference) throws -> String {
        let secretFile = paths.apiKeyFile(for: key)
        let fileDescriptor = open(secretFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT {
                throw SecretStoreError.missingSecret(key.rawValue)
            }
            throw SecretStoreError.readFailed(key.rawValue)
        }
        defer { close(fileDescriptor) }

        try validateSecretFileDescriptor(fileDescriptor, key: key)

        do {
            let data = try FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false).readToEnd() ?? Data()
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            let value = envelope.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard envelope.version == 1, !value.isEmpty else {
                throw SecretStoreError.readFailed(key.rawValue)
            }
            return value
        } catch let error as SecretStoreError {
            throw error
        } catch {
            throw SecretStoreError.readFailed(key.rawValue)
        }
    }

    private func validateSecretFileForDeletionLocked(_ secretFile: URL, key: SecretReference) throws -> Bool {
        let fileDescriptor = open(secretFile.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT {
                return false
            }
            throw SecretStoreError.readFailed(key.rawValue)
        }
        defer { close(fileDescriptor) }

        try validateSecretFileDescriptor(fileDescriptor, key: key)
        return true
    }

    private func validateSecretFileDescriptor(_ fileDescriptor: Int32, key: SecretReference) throws {
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_uid == getuid(),
              Int(fileStatus.st_mode) & 0o777 == 0o600 else {
            throw SecretStoreError.readFailed(key.rawValue)
        }
    }

    private func writeSecretLocked(_ value: String, for key: SecretReference) throws {
        let envelopeData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            envelopeData = try encoder.encode(Envelope(version: 1, value: value))
        } catch {
            throw SecretStoreError.writeFailed(key.rawValue)
        }

        let secretFile = paths.apiKeyFile(for: key)
        let temporaryFile = paths.apiKeysDirectory
            .appendingPathComponent(".\(key.rawValue)-\(UUID().uuidString).json")
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
            throw SecretStoreError.writeFailed(key.rawValue)
        }
        temporaryFileExists = true
        defer { close(fileDescriptor) }

        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw SecretStoreError.writeFailed(key.rawValue)
        }
        try writeAll(envelopeData, to: fileDescriptor, key: key)
        guard fsync(fileDescriptor) == 0,
              rename(temporaryFile.path, secretFile.path) == 0 else {
            throw SecretStoreError.writeFailed(key.rawValue)
        }
        temporaryFileExists = false
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32, key: SecretReference) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw SecretStoreError.writeFailed(key.rawValue)
            }

            var writtenBytes = 0
            while writtenBytes < buffer.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: writtenBytes),
                    buffer.count - writtenBytes
                )
                guard result > 0 else {
                    throw SecretStoreError.writeFailed(key.rawValue)
                }
                writtenBytes += result
            }
        }
    }

    private func withExclusiveLock<T>(for key: SecretReference, _ body: () throws -> T) throws -> T {
        try prepareAPIKeysDirectory()
        let lockFile = paths.apiKeyFile(for: key).appendingPathExtension("lock")
        let fileDescriptor = open(
            lockFile.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw SecretStoreError.writeFailed(key.rawValue)
        }
        defer { close(fileDescriptor) }

        var lockStatus = stat()
        guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0,
              fstat(fileDescriptor, &lockStatus) == 0,
              lockStatus.st_mode & S_IFMT == S_IFREG,
              lockStatus.st_uid == getuid(),
              Int(lockStatus.st_mode) & 0o777 == 0o600,
              flock(fileDescriptor, LOCK_EX) == 0 else {
            throw SecretStoreError.writeFailed(key.rawValue)
        }
        defer { _ = flock(fileDescriptor, LOCK_UN) }

        return try body()
    }

    private func prepareAPIKeysDirectory() throws {
        let directory = paths.apiKeysDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SecretStoreError.writeFailed("api-keys")
        }

        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == getuid() else {
            throw SecretStoreError.writeFailed("api-keys")
        }

        guard chmod(directory.path, S_IRWXU) == 0,
              lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == getuid(),
              Int(directoryStatus.st_mode) & 0o777 == 0o700 else {
            throw SecretStoreError.writeFailed("api-keys")
        }
    }
}

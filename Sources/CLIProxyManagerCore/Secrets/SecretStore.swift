import Foundation

public enum SecretKey: String, Sendable {
    case claudeAPIKey = "claude-api-key"
}

public enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    case missingSecret(String)
    case writeFailed(String)
    case readFailed(String)

    public var description: String {
        switch self {
        case .missingSecret(let key):
            "Missing secret: \(key)"
        case .writeFailed(let key):
            "Failed to write secret: \(key)"
        case .readFailed(let key):
            "Failed to read secret: \(key)"
        }
    }
}

public protocol SecretStore: Sendable {
    func get(_ key: SecretKey) throws -> String
    func set(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String]
    private let lock = NSLock()

    public init(values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func get(_ key: SecretKey) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let value = values[key] else {
            throw SecretStoreError.missingSecret(key.rawValue)
        }

        return value
    }

    public func set(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }

        values[key] = value
    }

    public func delete(_ key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }

        values.removeValue(forKey: key)
    }
}

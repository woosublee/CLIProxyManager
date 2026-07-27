import Foundation

public struct SecretReference: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let reference = SecretReference(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid secret reference."
            )
        }
        self = reference
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claudeAPIKey = SecretReference(rawValue: "claude-api-key")!
    public static let codexAPIKey = SecretReference(rawValue: "codex-api-key")!

    public static func apiKeyProfile(_ profileID: String) -> SecretReference? {
        SecretReference(rawValue: "\(profileID)-key")
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 128,
              value.first?.isLowercaseASCIIOrNumber == true,
              value.last?.isLowercaseASCIIOrNumber == true else {
            return false
        }
        return value.allSatisfy { character in
            character.isLowercaseASCIIOrNumber || character == "-"
        }
    }
}

public typealias SecretKey = SecretReference

private extension Character {
    var isLowercaseASCIIOrNumber: Bool {
        guard isASCII, let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (97...122).contains(Int(scalar.value)) || (48...57).contains(Int(scalar.value))
    }
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
    func get(_ key: SecretReference) throws -> String
    func set(_ value: String, for key: SecretReference) throws
    func delete(_ key: SecretReference) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretReference: String]
    private let lock = NSLock()

    public init(values: [SecretReference: String] = [:]) {
        self.values = values
    }

    public func get(_ key: SecretReference) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let value = values[key] else {
            throw SecretStoreError.missingSecret(key.rawValue)
        }

        return value
    }

    public func set(_ value: String, for key: SecretReference) throws {
        lock.lock()
        defer { lock.unlock() }

        values[key] = value
    }

    public func delete(_ key: SecretReference) throws {
        lock.lock()
        defer { lock.unlock() }

        values.removeValue(forKey: key)
    }
}

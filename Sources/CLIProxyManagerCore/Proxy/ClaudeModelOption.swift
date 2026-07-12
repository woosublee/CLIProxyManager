import Foundation

public enum ClaudeModelFamily: String, Codable, Equatable, Sendable {
    case opus
    case sonnet
    case haiku
    case other

    public init(modelID: String) {
        let value = modelID.lowercased()
        if value.hasPrefix("claude-opus-") {
            self = .opus
        } else if value.hasPrefix("claude-sonnet-") {
            self = .sonnet
        } else if value.hasPrefix("claude-haiku-") {
            self = .haiku
        } else {
            self = .other
        }
    }

    public var displayName: String {
        rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
    }
}

public struct ClaudeModelOption: Codable, Equatable, Sendable {
    public let id: String
    public let family: ClaudeModelFamily
    public let created: Int?

    public init(id: String, family: ClaudeModelFamily? = nil, created: Int? = nil) {
        self.id = id
        self.family = family ?? ClaudeModelFamily(modelID: id)
        self.created = created
    }
}

public enum ClaudeModelDiscoveryError: Error, Equatable, LocalizedError {
    case emptyModelPrefix

    public var errorDescription: String? {
        "This Claude account does not have a routing prefix. Save the account settings, then retry."
    }
}

public protocol ClaudeModelListing: Sendable {
    func claudeModelOptions(port: Int, modelPrefix: String) async throws -> [ClaudeModelOption]
}

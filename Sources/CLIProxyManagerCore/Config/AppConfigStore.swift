import Foundation

public enum AppConfigStoreError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Config schema version \(version) is newer than this app supports."
        }
    }
}

public struct AppConfigStore: @unchecked Sendable {
    public let paths: ManagedPaths
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func loadDocument() throws -> AppConfigLoadResult {
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            return .canonical(.default)
        }
        let data = try Data(contentsOf: paths.configFile)
        let schemaVersion = try LegacyAppConfigDecoder.schemaVersion(in: data)
        guard schemaVersion <= AppConfig.currentSchemaVersion else {
            throw AppConfigStoreError.unsupportedSchemaVersion(schemaVersion)
        }
        if schemaVersion < AppConfig.currentSchemaVersion {
            return try LegacyAppConfigDecoder.decode(data)
        }
        return .canonical(try JSONDecoder().decode(AppConfig.self, from: data))
    }

    public func load() throws -> AppConfig {
        try loadDocument().config
    }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: paths.configFile, options: .atomic)
    }
}

import Foundation

public struct AppConfigStore: @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> AppConfig {
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            return .default
        }
        let data = try Data(contentsOf: paths.configFile)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: paths.configFile, options: .atomic)
    }
}

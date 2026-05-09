import Foundation

public struct AppConfigStore: @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load() throws -> AppConfig {
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            return .default
        }
        let data = try Data(contentsOf: paths.configFile)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: paths.configFile, options: .atomic)
    }
}

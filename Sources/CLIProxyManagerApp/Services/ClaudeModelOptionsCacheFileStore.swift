import CLIProxyManagerCore
import Foundation

protocol ClaudeModelOptionsCaching: Sendable {
    func load() -> [String: [ClaudeModelOption]]
    func save(_ optionsByProvider: [String: [ClaudeModelOption]]) throws
}

struct ClaudeModelOptionsCacheFileStore: ClaudeModelOptionsCaching, @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager

    init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() -> [String: [ClaudeModelOption]] {
        guard let data = try? Data(contentsOf: paths.claudeModelOptionsCacheFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [ClaudeModelOption]].self, from: data)) ?? [:]
    }

    func save(_ optionsByProvider: [String: [ClaudeModelOption]]) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(optionsByProvider)
        try data.write(to: paths.claudeModelOptionsCacheFile, options: .atomic)
    }
}

import CLIProxyManagerCore
import Foundation

protocol CodexResetCreditsSnapshotCaching: Sendable {
    func load() -> [String: CodexResetCreditsSnapshot]
    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws
    func clear() throws
}

struct CodexResetCreditsSnapshotCacheFileStore: CodexResetCreditsSnapshotCaching, @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager

    init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() -> [String: CodexResetCreditsSnapshot] {
        guard let data = try? Data(contentsOf: paths.codexResetCreditsSnapshotCacheFile) else { return [:] }
        return (try? JSONDecoder().decode([String: CodexResetCreditsSnapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [String: CodexResetCreditsSnapshot]) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: paths.codexResetCreditsSnapshotCacheFile, options: .atomic)
    }

    func clear() throws {
        let url = paths.codexResetCreditsSnapshotCacheFile
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

import CLIProxyManagerCore
import Foundation

protocol SubscriptionUsageSnapshotCaching: Sendable {
    func load() -> [String: SubscriptionUsageSnapshot]
    func save(_ snapshots: [String: SubscriptionUsageSnapshot]) throws
    func clear() throws
}

struct SubscriptionUsageSnapshotCacheFileStore: SubscriptionUsageSnapshotCaching, @unchecked Sendable {
    private let paths: ManagedPaths
    private let fileManager: FileManager

    init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func load() -> [String: SubscriptionUsageSnapshot] {
        guard let data = try? Data(contentsOf: paths.subscriptionUsageSnapshotCacheFile) else { return [:] }
        return (try? JSONDecoder().decode([String: SubscriptionUsageSnapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [String: SubscriptionUsageSnapshot]) throws {
        try fileManager.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshots)
        try data.write(to: paths.subscriptionUsageSnapshotCacheFile, options: .atomic)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: paths.subscriptionUsageSnapshotCacheFile.path) else { return }
        try fileManager.removeItem(at: paths.subscriptionUsageSnapshotCacheFile)
    }
}

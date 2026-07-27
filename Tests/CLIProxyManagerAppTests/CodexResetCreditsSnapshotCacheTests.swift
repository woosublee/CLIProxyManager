import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CodexResetCreditsSnapshotCacheTests: XCTestCase {
    func testCachePersistsAndRestoresRedactedSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)
        let store = CodexResetCreditsSnapshotCacheFileStore(paths: paths)
        let snapshot = CodexResetCreditsSnapshot(
            profileID: "codex-work.json",
            reportedAvailableCount: 1,
            reportedTotalEarnedCount: 2,
            credits: [.init(
                title: "Full reset",
                status: "available",
                resetType: "full",
                expiresAt: Date(timeIntervalSince1970: 200),
                grantedAt: Date(timeIntervalSince1970: 100)
            )],
            fetchedAt: Date(timeIntervalSince1970: 150)
        )

        try store.save([snapshot.profileID: snapshot])

        XCTAssertEqual(store.load(), [snapshot.profileID: snapshot])
        XCTAssertEqual(paths.codexResetCreditsSnapshotCacheFile.lastPathComponent, "codex-reset-credits.json")
    }

    func testMalformedCacheLoadsAsEmptyAndClearRemovesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ManagedPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: paths.codexResetCreditsSnapshotCacheFile)
        let store = CodexResetCreditsSnapshotCacheFileStore(paths: paths)

        XCTAssertEqual(store.load(), [:])
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.codexResetCreditsSnapshotCacheFile.path))
    }
}

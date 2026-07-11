import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class SubscriptionUsageSnapshotCacheTests: XCTestCase {
    func testCachePersistsAndRestoresSuccessfulSnapshots() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = SubscriptionUsageSnapshotCacheFileStore(paths: ManagedPaths(rootDirectory: root))
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        try store.save([snapshot.profileID: snapshot])

        XCTAssertEqual(store.load(), [snapshot.profileID: snapshot])
    }
}

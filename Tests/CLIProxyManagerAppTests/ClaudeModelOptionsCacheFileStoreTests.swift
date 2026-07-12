import CLIProxyManagerCore
import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class ClaudeModelOptionsCacheFileStoreTests: XCTestCase {
    func testRoundTripsProviderScopedClaudeModels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeModelOptionsCacheFileStore(paths: ManagedPaths(rootDirectory: root))
        let cached = [
            "claude-work": [ClaudeModelOption(id: "claude-opus-4-8", created: 500)],
            ProviderRowState.ID.claudeAPI.rawValue: [ClaudeModelOption(id: "claude-sonnet-5", created: 400)]
        ]

        try store.save(cached)

        XCTAssertEqual(store.load(), cached)
    }
}

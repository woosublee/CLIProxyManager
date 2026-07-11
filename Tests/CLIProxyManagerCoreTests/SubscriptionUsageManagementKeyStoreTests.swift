import XCTest
@testable import CLIProxyManagerCore

final class SubscriptionUsageManagementKeyStoreTests: XCTestCase {
    func testCreateManagementKeyIfNeededCreatesPersistentKeyOnlyOnce() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        defer { try? store.deleteManagementKey() }

        XCTAssertFalse(store.isConfigured())
        XCTAssertTrue(try store.createManagementKeyIfNeeded())
        let first = try store.managementKey()
        XCTAssertGreaterThanOrEqual(first.count, 43)
        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), first)
    }

    func testCreateManagementKeyIfNeededPreservesExistingKey() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        defer { try? store.deleteManagementKey() }
        try store.setManagementKey("preexisting-test-key")

        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), "preexisting-test-key")
    }

    func testDeleteManagementKeyRemovesGeneratedKey() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        _ = try store.createManagementKeyIfNeeded()
        try store.deleteManagementKey()

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
    }
}

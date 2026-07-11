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

    func testConcurrentCreateManagementKeyIfNeededCreatesOneKeyWithoutErrors() throws {
        let service = "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)"
        let stores = (0 ..< 2).map { _ in SubscriptionUsageManagementKeyStore(service: service) }
        let results = ConcurrentCreationResults()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        defer { try? SubscriptionUsageManagementKeyStore(service: service).deleteManagementKey() }

        for store in stores {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                results.append(Result { try store.createManagementKeyIfNeeded() })
                group.leave()
            }
        }
        for _ in stores {
            start.signal()
        }
        group.wait()

        let values = results.snapshot()
        XCTAssertEqual(values.count, stores.count)
        XCTAssertTrue(values.allSatisfy {
            if case .success = $0 { return true }
            return false
        })
        XCTAssertEqual(values.compactMap { try? $0.get() }.filter { $0 }.count, 1)
        XCTAssertTrue(SubscriptionUsageManagementKeyStore(service: service).isConfigured())
    }

    func testDeleteManagementKeyRemovesGeneratedKey() throws {
        let store = SubscriptionUsageManagementKeyStore(service: "io.woosublee.CLIProxyManager.tests.\(UUID().uuidString)")
        _ = try store.createManagementKeyIfNeeded()
        try store.deleteManagementKey()

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
    }
}

private final class ConcurrentCreationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Bool, Error>] = []

    func append(_ result: Result<Bool, Error>) {
        lock.withLock {
            values.append(result)
        }
    }

    func snapshot() -> [Result<Bool, Error>] {
        lock.withLock { values }
    }
}

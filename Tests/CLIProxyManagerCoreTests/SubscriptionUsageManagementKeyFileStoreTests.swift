import Darwin
import XCTest
@testable import CLIProxyManagerCore

final class SubscriptionUsageManagementKeyFileStoreTests: XCTestCase {
    func testCreateManagementKeyIfNeededCreatesPersistentKeyOnlyOnce() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        XCTAssertFalse(store.isConfigured())
        XCTAssertTrue(try store.createManagementKeyIfNeeded())
        let first = try store.managementKey()
        XCTAssertGreaterThanOrEqual(first.count, 43)
        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.subscriptionUsageManagementKeyFile.path))
    }

    func testCreateManagementKeyIfNeededPreservesExistingKey() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)
        try store.setManagementKey("preexisting-test-key")

        XCTAssertFalse(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try store.managementKey(), "preexisting-test-key")
    }

    func testSetManagementKeyStoresVersionedOwnerOnlyEnvelope() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        try store.setManagementKey("test-management-key")

        let data = try Data(contentsOf: paths.subscriptionUsageManagementKeyFile)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(filePermissions(at: paths.subscriptionUsageManagementKeyFile), 0o600)
        XCTAssertEqual(try store.managementKey(), "test-management-key")
    }

    func testConcurrentCreateManagementKeyIfNeededCreatesOneKeyWithoutErrors() throws {
        let paths = try makePaths()
        let stores = (0 ..< 2).map { _ in SubscriptionUsageManagementKeyFileStore(paths: paths) }
        let results = ConcurrentCreationResults()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

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
        XCTAssertTrue(SubscriptionUsageManagementKeyFileStore(paths: paths).isConfigured())
    }

    func testDeleteManagementKeyIsIdempotentAndRemovesGeneratedKey() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)
        _ = try store.createManagementKeyIfNeeded()

        try store.deleteManagementKey()
        try store.deleteManagementKey()

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.subscriptionUsageManagementKeyFile.path))
    }

    func testMalformedEnvelopeIsRejectedWithoutOverwritingIt() throws {
        let paths = try makePaths()
        try write(Data("not-json".utf8), to: paths.subscriptionUsageManagementKeyFile)
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
        XCTAssertThrowsError(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try Data(contentsOf: paths.subscriptionUsageManagementKeyFile), Data("not-json".utf8))
    }

    func testNonUTF8EnvelopeIsRejectedWithoutOverwritingIt() throws {
        let paths = try makePaths()
        let originalData = Data([0xFF, 0xFE, 0x00])
        try write(originalData, to: paths.subscriptionUsageManagementKeyFile)
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
        XCTAssertThrowsError(try store.createManagementKeyIfNeeded())
        XCTAssertEqual(try Data(contentsOf: paths.subscriptionUsageManagementKeyFile), originalData)
    }

    func testBlankOrUnsupportedEnvelopeIsRejected() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        try write(Data(#"{"version":1,"key":"   "}"#.utf8), to: paths.subscriptionUsageManagementKeyFile)
        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())

        try write(Data(#"{"version":2,"key":"test-key"}"#.utf8), to: paths.subscriptionUsageManagementKeyFile)
        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
    }

    func testDirectoryAndSymlinkSecretPathsAreRejected() throws {
        let directoryPaths = try makePaths()
        try FileManager.default.createDirectory(at: directoryPaths.subscriptionUsageManagementKeyFile, withIntermediateDirectories: true)
        let directoryStore = SubscriptionUsageManagementKeyFileStore(paths: directoryPaths)

        XCTAssertFalse(directoryStore.isConfigured())
        XCTAssertThrowsError(try directoryStore.managementKey())
        XCTAssertThrowsError(try directoryStore.deleteManagementKey())

        let symlinkPaths = try makePaths()
        let target = symlinkPaths.rootDirectory.appendingPathComponent("target.json")
        try write(Data(#"{"version":1,"key":"test-key"}"#.utf8), to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkPaths.subscriptionUsageManagementKeyFile,
            withDestinationURL: target
        )
        let symlinkStore = SubscriptionUsageManagementKeyFileStore(paths: symlinkPaths)

        XCTAssertFalse(symlinkStore.isConfigured())
        XCTAssertThrowsError(try symlinkStore.managementKey())
        XCTAssertThrowsError(try symlinkStore.setManagementKey("replacement-key"))
        XCTAssertEqual(try Data(contentsOf: target), Data(#"{"version":1,"key":"test-key"}"#.utf8))
        XCTAssertThrowsError(try symlinkStore.deleteManagementKey())
    }

    func testInsecureSecretFilePermissionsAreRejected() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)
        try store.setManagementKey("test-management-key")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.subscriptionUsageManagementKeyFile.path)

        XCTAssertFalse(store.isConfigured())
        XCTAssertThrowsError(try store.managementKey())
    }

    func testWritesLeaveNoTemporarySecretFiles() throws {
        let paths = try makePaths()
        let store = SubscriptionUsageManagementKeyFileStore(paths: paths)

        try store.setManagementKey("first-key")
        try store.setManagementKey("second-key")

        let names = try FileManager.default.contentsOfDirectory(atPath: paths.rootDirectory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".subscription-usage-management-key-") })
        XCTAssertEqual(try store.managementKey(), "second-key")
    }

    private func makePaths() throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionUsageManagementKeyFileStoreTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ManagedPaths(rootDirectory: root)
    }

    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func filePermissions(at file: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
            .map { $0 & 0o777 }
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

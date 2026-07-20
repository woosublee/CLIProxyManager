import Foundation
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class BundledProxyReconciliationServiceTests: XCTestCase {
    func testReconcileForwardsBundledURLsAndReturnsStoreResult() throws {
        let binary = URL(fileURLWithPath: "/tmp/bundle/cliproxyapi")
        let manifest = URL(fileURLWithPath: "/tmp/bundle/cliproxyapi.manifest.json")
        let store = BundledProxyBinaryStoreDouble(
            result: .installed(
                previousVersion: CLIProxyAPIVersion("7.2.72"),
                newVersion: CLIProxyAPIVersion("7.2.91")!
            )
        )
        let service = BundledProxyReconciliationService(
            store: store,
            bundledBinaryURL: binary,
            bundledManifestURL: manifest
        )

        let result = try service.reconcile()

        XCTAssertEqual(result.activeVersion.description, "7.2.91")
        XCTAssertEqual(store.binaryURLs, [binary])
        XCTAssertEqual(store.manifestURLs, [manifest])
    }
}

private final class BundledProxyBinaryStoreDouble: BundledProxyBinaryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBinaryURLs: [URL?] = []
    private var recordedManifestURLs: [URL?] = []
    private let result: BundledProxyReconciliationResult

    var binaryURLs: [URL?] { lock.withLock { recordedBinaryURLs } }
    var manifestURLs: [URL?] { lock.withLock { recordedManifestURLs } }

    init(result: BundledProxyReconciliationResult) {
        self.result = result
    }

    func reconcileBundledBinary(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult {
        lock.withLock {
            recordedBinaryURLs.append(bundledBinaryURL)
            recordedManifestURLs.append(bundledManifestURL)
        }
        return result
    }
}

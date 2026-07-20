import CLIProxyManagerCore
import Foundation

protocol BundledProxyBinaryStoring: Sendable {
    func reconcileBundledBinary(
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) throws -> BundledProxyReconciliationResult
}

extension CLIProxyAPIBinaryStore: BundledProxyBinaryStoring {}

protocol BundledProxyReconciling: Sendable {
    func reconcile() throws -> BundledProxyReconciliationResult
}

struct BundledProxyReconciliationService: BundledProxyReconciling, Sendable {
    private let store: any BundledProxyBinaryStoring
    private let bundledBinaryURL: URL?
    private let bundledManifestURL: URL?

    init(
        store: any BundledProxyBinaryStoring,
        bundledBinaryURL: URL?,
        bundledManifestURL: URL?
    ) {
        self.store = store
        self.bundledBinaryURL = bundledBinaryURL
        self.bundledManifestURL = bundledManifestURL
    }

    func reconcile() throws -> BundledProxyReconciliationResult {
        try store.reconcileBundledBinary(
            bundledBinaryURL: bundledBinaryURL,
            bundledManifestURL: bundledManifestURL
        )
    }
}

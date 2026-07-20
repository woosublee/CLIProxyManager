import CLIProxyManagerCore
import Foundation

enum BundledProxyBinary {
    static func url(bundle: Bundle? = nil, appBundle: Bundle = .main) -> URL? {
        if let url = appBundle.url(forResource: "cliproxyapi", withExtension: nil, subdirectory: "cliproxyapi") {
            return url
        }
        return (bundle ?? .module).url(forResource: "cliproxyapi", withExtension: nil, subdirectory: "cliproxyapi")
    }

    static func manifestURL(bundle: Bundle? = nil, appBundle: Bundle = .main) -> URL? {
        if let url = appBundle.url(forResource: "cliproxyapi", withExtension: "manifest.json", subdirectory: "cliproxyapi") {
            return url
        }
        return (bundle ?? .module).url(forResource: "cliproxyapi", withExtension: "manifest.json", subdirectory: "cliproxyapi")
    }

    static func serviceManager(paths: ManagedPaths = ManagedPaths()) -> ProxyServiceManager {
        ProxyServiceManager(paths: paths, bundledBinaryURL: url(), bundledManifestURL: manifestURL())
    }

    static func reconciliationService(paths: ManagedPaths = ManagedPaths()) -> BundledProxyReconciliationService {
        BundledProxyReconciliationService(
            store: CLIProxyAPIBinaryStore(paths: paths),
            bundledBinaryURL: url(),
            bundledManifestURL: manifestURL()
        )
    }
}

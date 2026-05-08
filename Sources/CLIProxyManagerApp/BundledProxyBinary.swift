import CLIProxyManagerCore
import Foundation

enum BundledProxyBinary {
    static func url(bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "cliproxyapi", withExtension: nil, subdirectory: "cliproxyapi")
    }

    static func serviceManager(paths: ManagedPaths = ManagedPaths()) -> ProxyServiceManager {
        ProxyServiceManager(paths: paths, bundledBinaryURL: url())
    }
}

import CLIProxyManagerCore
import Foundation

enum BundledProxyBinary {
    static func url(bundle: Bundle = .module, appBundle: Bundle = .main) -> URL? {
        appBundle.url(forResource: "cliproxyapi", withExtension: nil, subdirectory: "cliproxyapi")
            ?? bundle.url(forResource: "cliproxyapi", withExtension: nil, subdirectory: "cliproxyapi")
    }

    static func serviceManager(paths: ManagedPaths = ManagedPaths()) -> ProxyServiceManager {
        ProxyServiceManager(paths: paths, bundledBinaryURL: url())
    }
}

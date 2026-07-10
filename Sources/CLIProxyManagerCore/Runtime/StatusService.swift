import CryptoKit
import Foundation

public struct HelperInspector: HelperInspecting, Sendable {
    private let helperPath: String
    private let bundledHelperURL: URL?
    private let fileManager: FileManager

    public init(
        helperPath: String = "/usr/local/bin/cpm",
        bundledHelperURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.helperPath = helperPath
        self.bundledHelperURL = bundledHelperURL
        self.fileManager = fileManager
    }

    public func inspect() -> HelperStatus {
        var isDir: ObjCBool = false
        let installed = fileManager.fileExists(atPath: helperPath, isDirectory: &isDir) && !isDir.boolValue
        var matchesBundled = false
        if installed, let bundled = bundledHelperURL {
            var bundledIsDir: ObjCBool = false
            let bundledExists = fileManager.fileExists(atPath: bundled.path, isDirectory: &bundledIsDir) && !bundledIsDir.boolValue
            if bundledExists {
                matchesBundled = filesMatch(helperPath, bundled.path)
            }
        }
        return HelperStatus(path: helperPath, installed: installed, matchesBundled: matchesBundled)
    }

    private func filesMatch(_ path1: String, _ path2: String) -> Bool {
        guard
            let attr1 = try? fileManager.attributesOfItem(atPath: path1),
            let attr2 = try? fileManager.attributesOfItem(atPath: path2),
            let size1 = attr1[.size] as? Int,
            let size2 = attr2[.size] as? Int,
            size1 == size2,
            let data1 = try? Data(contentsOf: URL(fileURLWithPath: path1)),
            let data2 = try? Data(contentsOf: URL(fileURLWithPath: path2))
        else { return false }
        return SHA256.hash(data: data1) == SHA256.hash(data: data2)
    }
}

public struct StatusService: StatusReporting, Sendable {
    private let appLifecycle: any AppLifecycleControlling
    private let proxyRuntime: any ProxyRuntimeServicing
    private let helperInspector: any HelperInspecting
    private let paths: ManagedPaths

    public init(
        appLifecycle: any AppLifecycleControlling = AppLifecycleService(),
        proxyRuntime: any ProxyRuntimeServicing = ProxyRuntimeService(),
        helperInspector: any HelperInspecting = HelperInspector(),
        paths: ManagedPaths = ManagedPaths()
    ) {
        self.appLifecycle = appLifecycle
        self.proxyRuntime = proxyRuntime
        self.helperInspector = helperInspector
        self.paths = paths
    }

    public func status() async throws -> CPMStatus {
        async let appResult = appLifecycle.status()
        async let proxyResult = proxyRuntime.status()
        let helperStatus = helperInspector.inspect()
        let app = try await appResult
        let proxy = try await proxyResult
        return CPMStatus(
            app: CPMStatus.App(
                installed: app.installed,
                path: app.path,
                version: app.version,
                build: app.build,
                running: app.running,
                stagedVersion: nil
            ),
            helper: CPMStatus.Helper(
                path: helperStatus.path,
                installed: helperStatus.installed,
                matchesBundled: helperStatus.matchesBundled
            ),
            proxy: CPMStatus.Proxy(
                port: proxy.port,
                running: proxy.running,
                activeVersion: proxy.activeVersion,
                pendingVersion: proxy.pendingVersion,
                stagedVersion: nil,
                logsPath: paths.proxyLogsDirectory.path
            )
        )
    }
}

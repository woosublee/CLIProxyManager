import CryptoKit
import Foundation

private final class FileManagerAccessLock: @unchecked Sendable {
    static let shared = FileManagerAccessLock()

    let value = NSLock()
}

public struct HelperInspector: HelperInspecting, Sendable {
    private struct FileManagerStorage: @unchecked Sendable {
        let value: FileManager

        func withValue<T>(_ operation: (FileManager) -> T) -> T {
            FileManagerAccessLock.shared.value.lock()
            defer { FileManagerAccessLock.shared.value.unlock() }
            return operation(value)
        }
    }

    private let helperPath: String
    private let bundledHelperURL: URL?
    private let fileManager: FileManagerStorage

    public init(
        helperPath: String = "/usr/local/bin/cpm",
        bundledHelperURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.helperPath = helperPath
        self.bundledHelperURL = bundledHelperURL
        self.fileManager = FileManagerStorage(value: fileManager)
    }

    public func inspect() -> HelperStatus {
        fileManager.withValue { fileManager in
            var isDir: ObjCBool = false
            let installed = fileManager.fileExists(atPath: helperPath, isDirectory: &isDir) && !isDir.boolValue
            var matchesBundled = false
            if installed, let bundled = bundledHelperURL {
                var bundledIsDir: ObjCBool = false
                let bundledExists = fileManager.fileExists(atPath: bundled.path, isDirectory: &bundledIsDir) && !bundledIsDir.boolValue
                if bundledExists {
                    matchesBundled = filesMatch(helperPath, bundled.path, fileManager: fileManager)
                }
            }
            return HelperStatus(path: helperPath, installed: installed, matchesBundled: matchesBundled)
        }
    }

    private func filesMatch(_ path1: String, _ path2: String, fileManager: FileManager) -> Bool {
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
    private let compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing
    private let compatibilityArtifactsProvider: @Sendable () -> CompatibilityArtifacts
    private let paths: ManagedPaths

    public init(
        appLifecycle: any AppLifecycleControlling = AppLifecycleService(),
        proxyRuntime: any ProxyRuntimeServicing = ProxyRuntimeService(),
        helperInspector: any HelperInspecting = HelperInspector(),
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight(),
        compatibilityArtifactsProvider: (@Sendable () -> CompatibilityArtifacts)? = nil,
        paths: ManagedPaths = ManagedPaths()
    ) {
        self.appLifecycle = appLifecycle
        self.proxyRuntime = proxyRuntime
        self.helperInspector = helperInspector
        self.compatibilityAuthorizer = compatibilityAuthorizer
        self.compatibilityArtifactsProvider = compatibilityArtifactsProvider ?? { Self.defaultCompatibilityArtifacts() }
        self.paths = paths
    }

    public func status() async throws -> CPMStatus {
        async let appResult = appLifecycle.status()
        async let proxyResult = proxyRuntime.status()
        let artifacts = compatibilityArtifactsProvider()
        async let compatibilityResult = compatibilityAuthorizer.report(artifacts: artifacts)
        let helperStatus = helperInspector.inspect()
        let app = try await appResult
        let proxy = try await proxyResult
        let compatibility = await compatibilityResult
        return CPMStatus(
            app: CPMStatus.App(
                installed: app.installed,
                path: app.path.map(Self.sanitizedPath),
                version: app.version,
                build: app.build,
                running: app.running,
                stagedVersion: nil
            ),
            helper: CPMStatus.Helper(
                path: Self.sanitizedPath(helperStatus.path),
                installed: helperStatus.installed,
                matchesBundled: helperStatus.matchesBundled
            ),
            proxy: CPMStatus.Proxy(
                port: proxy.port,
                running: proxy.running,
                activeVersion: proxy.activeVersion,
                pendingVersion: proxy.pendingVersion,
                stagedVersion: nil,
                logsPath: Self.sanitizedPath(paths.proxyLogsDirectory.path)
            ),
            compatibility: .init(report: compatibility)
        )
    }

    private static func defaultCompatibilityArtifacts() -> CompatibilityArtifacts {
        let paths = ManagedPaths()
        let store = CLIProxyAPIBinaryStore(paths: paths)
        let bundledManifestURL = try? AppBundleLocator().locateInstalledApp().proxyManifestURL
        return CompatibilityArtifacts(
            bundled: artifact(at: bundledManifestURL),
            active: artifact(reading: Result { try store.activeManifest() }),
            pending: artifact(reading: Result { try store.pendingManifest() })
        )
    }

    private static func artifact(at manifestURL: URL?) -> RuntimeCompatibilityArtifact? {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CLIProxyAPIBinaryManifest.self, from: data)
        else {
            return manifestURL == nil ? nil : unsupportedArtifact
        }
        return artifact(for: manifest)
    }

    private static func artifact(reading result: Result<CLIProxyAPIBinaryManifest?, Error>) -> RuntimeCompatibilityArtifact? {
        switch result {
        case .success(let manifest):
            artifact(for: manifest)
        case .failure:
            unsupportedArtifact
        }
    }

    private static func artifact(for manifest: CLIProxyAPIBinaryManifest?) -> RuntimeCompatibilityArtifact? {
        guard let manifest else { return nil }
        if let target = manifest.target { return .explicit(target) }
        guard manifest.upstreamAsset == "CLIProxyAPI_\(manifest.version)_darwin_aarch64.tar.gz" else {
            return unsupportedArtifact
        }
        return .legacy
    }

    private static let unsupportedArtifact = RuntimeCompatibilityArtifact.explicit(
        CLIProxyAPIArtifactTarget(operatingSystem: .darwin, architecture: .x86_64)
    )

    private static func sanitizedPath(_ path: String) -> String {
        path.hasPrefix("/") ? "<redacted>" : path
    }
}

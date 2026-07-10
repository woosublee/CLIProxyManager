import Foundation

public struct ProxyRuntimeService: ProxyRuntimeServicing, Sendable {
    private let configLoader: @Sendable () throws -> AppConfig
    private let bundleLocator: any AppBundleLocating
    private let proxyServiceFactory: @Sendable (URL?, URL?) -> any ProxyServiceControlling
    private let healthClient: any ProxyHealthChecking
    private let binaryStore: CLIProxyAPIBinaryStore

    public init(
        paths: ManagedPaths = ManagedPaths(),
        bundleLocator: any AppBundleLocating = AppBundleLocator()
    ) {
        self.configLoader = { try AppConfigStore(paths: paths).load() }
        self.bundleLocator = bundleLocator
        self.proxyServiceFactory = { binaryURL, manifestURL in
            ProxyServiceManager(
                paths: paths,
                bundledBinaryURL: binaryURL,
                bundledManifestURL: manifestURL
            )
        }
        self.healthClient = ProxyHealthClient()
        self.binaryStore = CLIProxyAPIBinaryStore(paths: paths)
    }

    init(
        configLoader: @escaping @Sendable () throws -> AppConfig,
        bundleLocator: any AppBundleLocating,
        proxyServiceFactory: @escaping @Sendable (URL?, URL?) -> any ProxyServiceControlling,
        healthClient: any ProxyHealthChecking,
        binaryStore: CLIProxyAPIBinaryStore
    ) {
        self.configLoader = configLoader
        self.bundleLocator = bundleLocator
        self.proxyServiceFactory = proxyServiceFactory
        self.healthClient = healthClient
        self.binaryStore = binaryStore
    }

    public func status() async throws -> ProxyRuntimeStatus {
        let config = try configLoader()
        return await buildStatus(port: config.port)
    }

    public func start() async throws -> ProxyRuntimeStatus {
        let config = try configLoader()
        let bundle = try bundleLocator.locateInstalledApp()
        let service = proxyServiceFactory(bundle.proxyBinaryURL, bundle.proxyManifestURL)
        try await service.start(port: config.port)
        return await buildStatus(port: config.port)
    }

    public func stop() async throws -> ProxyRuntimeStatus {
        let config = try configLoader()
        let service = proxyServiceFactory(nil, nil)
        try await service.stop()
        return await buildStatus(port: config.port)
    }

    public func restart() async throws -> ProxyRuntimeStatus {
        let config = try configLoader()
        let bundle = try bundleLocator.locateInstalledApp()
        let service = proxyServiceFactory(bundle.proxyBinaryURL, bundle.proxyManifestURL)
        try await service.restart(port: config.port)
        return await buildStatus(port: config.port)
    }

    private func buildStatus(port: Int) async -> ProxyRuntimeStatus {
        let diagnostic = await healthClient.status(port: port)
        let activeVersion = try? binaryStore.activeManifest()?.version
        let pendingVersion = try? binaryStore.pendingManifest()?.version
        return ProxyRuntimeStatus(
            port: port,
            running: diagnostic.severity == .ready,
            health: ProxyHealthSummary(title: diagnostic.title, message: diagnostic.message),
            activeVersion: activeVersion,
            pendingVersion: pendingVersion
        )
    }
}

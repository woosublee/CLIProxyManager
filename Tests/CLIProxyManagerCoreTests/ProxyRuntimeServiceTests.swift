import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class ProxyRuntimeServiceTests: XCTestCase {
    func testStartUsesConfiguredPortAndBundleResources() async throws {
        let paths = try makePaths(port: 8317)
        let fixture = try makeAppBundle(version: "0.1.12", build: "15")
        let proxy = ProxyServiceDouble()
        let service = makeService(paths: paths, bundle: fixture, proxy: proxy, health: .ready)

        let status = try await service.start()

        XCTAssertEqual(proxy.events, [.start(8317)])
        XCTAssertEqual(status.port, 8317)
        XCTAssertTrue(status.running)
    }

    func testStopDoesNotRequireBundleLocator() async throws {
        let paths = try makePaths(port: 8317)
        let proxy = ProxyServiceDouble()
        let service = ProxyRuntimeService(
            configLoader: { try AppConfigStore(paths: paths).load() },
            bundleLocator: FailingBundleLocator(),
            proxyServiceFactory: { _, _ in proxy },
            healthClient: HealthClientDouble(severity: .stopped),
            binaryStore: CLIProxyAPIBinaryStore(paths: paths)
        )

        _ = try await service.stop()

        XCTAssertEqual(proxy.events, [.stop])
    }

    func testRestartCallsRestartWithConfiguredPort() async throws {
        let paths = try makePaths(port: 9000)
        let fixture = try makeAppBundle(version: "0.1.12", build: "15")
        let proxy = ProxyServiceDouble()
        let service = makeService(paths: paths, bundle: fixture, proxy: proxy, health: .ready)

        _ = try await service.restart()

        XCTAssertEqual(proxy.events, [.restart(9000)])
    }

    func testStatusReflectsHealthClientSeverity() async throws {
        let paths = try makePaths(port: 8317)
        let fixture = try makeAppBundle(version: "0.1.12", build: "15")
        let proxy = ProxyServiceDouble()
        let service = makeService(paths: paths, bundle: fixture, proxy: proxy, health: .error)

        let status = try await service.status()

        XCTAssertFalse(status.running)
        XCTAssertEqual(status.port, 8317)
    }

    func testStatusProxyFactoryReceivesNilBundleURLs() async throws {
        let paths = try makePaths(port: 8317)
        let receivedURLs = CapturedBundleURLs(
            binaryURL: URL(fileURLWithPath: "/placeholder"),
            manifestURL: URL(fileURLWithPath: "/placeholder")
        )
        let service = ProxyRuntimeService(
            configLoader: { try AppConfigStore(paths: paths).load() },
            bundleLocator: FailingBundleLocator(),
            proxyServiceFactory: { binaryURL, manifestURL in
                receivedURLs.record(binaryURL: binaryURL, manifestURL: manifestURL)
                return ProxyServiceDouble()
            },
            healthClient: HealthClientDouble(severity: .stopped),
            binaryStore: CLIProxyAPIBinaryStore(paths: paths)
        )

        _ = try await service.stop()

        XCTAssertNil(receivedURLs.binaryURL)
        XCTAssertNil(receivedURLs.manifestURL)
    }

    // MARK: - Helpers

    private func makePaths(port: Int) throws -> ManagedPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedPaths(rootDirectory: root)
        var config = AppConfig.default
        config.port = port
        try AppConfigStore(paths: paths).save(config)
        return paths
    }

    private func makeService(paths: ManagedPaths, bundle: URL, proxy: ProxyServiceDouble, health: HealthSeverity) -> ProxyRuntimeService {
        ProxyRuntimeService(
            configLoader: { try AppConfigStore(paths: paths).load() },
            bundleLocator: BundleLocatorDouble(appURL: bundle),
            proxyServiceFactory: { _, _ in proxy },
            healthClient: HealthClientDouble(severity: health),
            binaryStore: CLIProxyAPIBinaryStore(paths: paths)
        )
    }

    private func makeAppBundle(version: String, build: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("CLIProxyManager.app")
        let contents = appURL.appendingPathComponent("Contents")
        addTeardownBlock { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: contents.appendingPathComponent("Resources/cliproxyapi"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        fm.createFile(atPath: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi").path, contents: nil)
        fm.createFile(atPath: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi.manifest.json").path, contents: nil)

        let plist: NSDictionary = [
            "CFBundleIdentifier": "com.woosublee.CLIProxyManager",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }
}

// MARK: - Test doubles

private final class CapturedBundleURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var _binaryURL: URL?
    private var _manifestURL: URL?

    init(binaryURL: URL?, manifestURL: URL?) {
        _binaryURL = binaryURL
        _manifestURL = manifestURL
    }

    var binaryURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _binaryURL
    }

    var manifestURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _manifestURL
    }

    func record(binaryURL: URL?, manifestURL: URL?) {
        lock.lock()
        _binaryURL = binaryURL
        _manifestURL = manifestURL
        lock.unlock()
    }
}

private final class ProxyServiceDouble: ProxyServiceControlling, @unchecked Sendable {
    enum Event: Equatable {
        case start(Int)
        case stop
        case restart(Int)
    }

    private(set) var events: [Event] = []

    func start(port: Int) async throws { events.append(.start(port)) }
    func stop() async throws { events.append(.stop) }
    func restart(port: Int) async throws { events.append(.restart(port)) }
}

private struct BundleLocatorDouble: AppBundleLocating {
    let appURL: URL

    func locateInstalledApp() throws -> ManagedAppBundle {
        let contents = appURL.appendingPathComponent("Contents")
        return ManagedAppBundle(
            appURL: appURL,
            proxyBinaryURL: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi"),
            proxyManifestURL: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi.manifest.json"),
            version: "0.1.12",
            build: "15"
        )
    }
}

private struct FailingBundleLocator: AppBundleLocating {
    func locateInstalledApp() throws -> ManagedAppBundle {
        throw CLIProxyManagerCommandError.prerequisite("CLIProxyManager.app is not installed.")
    }
}

private enum HealthSeverity { case ready, stopped, error }

private struct HealthClientDouble: ProxyHealthChecking {
    let severity: HealthSeverity

    func status(port: Int) async -> DiagnosticStatus {
        switch severity {
        case .ready:
            return DiagnosticStatus(severity: .ready, title: "Running", message: "Models are available on port \(port).")
        case .stopped:
            return DiagnosticStatus(severity: .error, title: "Stopped", message: "Connection refused on port \(port).")
        case .error:
            return DiagnosticStatus(severity: .error, title: "Error", message: "Health check failed.")
        }
    }
}

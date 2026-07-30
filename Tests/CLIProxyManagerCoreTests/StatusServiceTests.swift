import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class StatusServiceTests: XCTestCase {
    func testJSONStatusContainsOnlyStableOperationalFields() async throws {
        let status = try await StatusService(
            appLifecycle: AppLifecycleDouble(running: false),
            proxyRuntime: ProxyRuntimeDouble(port: 8317, running: true, activeVersion: "7.2.41"),
            helperInspector: HelperInspectorDouble(installed: true, matchesBundled: true)
        ).status()

        let data = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((object["app"] as? [String: Any])?["running"] as? Bool, false)
        XCTAssertEqual((object["proxy"] as? [String: Any])?["port"] as? Int, 8317)
        XCTAssertNil((object["proxy"] as? [String: Any])?["authProfiles"])
        XCTAssertNil((object["app"] as? [String: Any])?["apiKey"])
    }

    func testStatusAggregatesAppAndProxyAndHelper() async throws {
        let status = try await StatusService(
            appLifecycle: AppLifecycleDouble(running: true),
            proxyRuntime: ProxyRuntimeDouble(port: 9000, running: false, activeVersion: nil),
            helperInspector: HelperInspectorDouble(installed: false, matchesBundled: false)
        ).status()

        XCTAssertTrue(status.app.running)
        XCTAssertFalse(status.proxy.running)
        XCTAssertEqual(status.proxy.port, 9000)
        XCTAssertFalse(status.helper.installed)
    }

    func testStagedVersionIsAlwaysNilInBasePhase() async throws {
        let status = try await StatusService(
            appLifecycle: AppLifecycleDouble(running: false),
            proxyRuntime: ProxyRuntimeDouble(port: 8317, running: false, activeVersion: nil),
            helperInspector: HelperInspectorDouble(installed: false, matchesBundled: false)
        ).status()

        XCTAssertNil(status.app.stagedVersion)
        XCTAssertNil(status.proxy.stagedVersion)
    }

    func testHelperInspectorRetainsFileManagerInitializer() {
        _ = HelperInspector(fileManager: .default)
    }

    func testHelperInspectorSerializesInjectedFileManagerAccess() async {
        let fileManager = ConcurrentFileManager()
        let inspectors = [
            HelperInspector(fileManager: fileManager),
            HelperInspector(fileManager: fileManager)
        ]

        await withTaskGroup(of: Void.self) { group in
            for inspector in inspectors {
                group.addTask {
                    _ = inspector.inspect()
                }
            }
        }

        XCTAssertEqual(fileManager.maximumConcurrentAccesses, 1)
    }
}

// MARK: - Test doubles

private struct AppLifecycleDouble: AppLifecycleControlling {
    let running: Bool

    func status() async throws -> AppLifecycleStatus {
        AppLifecycleStatus(installed: true, running: running, path: "/Applications/CLIProxyManager.app", version: "0.1.12", build: "15")
    }
    func start() async throws -> AppLifecycleStatus { try await status() }
    func stop() async throws -> AppLifecycleStatus { try await status() }
    func restart() async throws -> AppLifecycleStatus { try await status() }
}

private struct ProxyRuntimeDouble: ProxyRuntimeServicing {
    let port: Int
    let running: Bool
    let activeVersion: String?

    func status() async throws -> ProxyRuntimeStatus {
        ProxyRuntimeStatus(
            port: port,
            running: running,
            health: ProxyHealthSummary(title: "OK", message: "OK"),
            activeVersion: activeVersion,
            pendingVersion: nil
        )
    }
    func start() async throws -> ProxyRuntimeStatus { try await status() }
    func stop() async throws -> ProxyRuntimeStatus { try await status() }
    func restart() async throws -> ProxyRuntimeStatus { try await status() }
}

private struct HelperInspectorDouble: HelperInspecting {
    let installed: Bool
    let matchesBundled: Bool

    func inspect() -> HelperStatus {
        HelperStatus(path: "/usr/local/bin/cpm", installed: installed, matchesBundled: matchesBundled)
    }
}

private final class ConcurrentFileManager: FileManager {
    private let lock = NSLock()
    private var concurrentAccesses = 0
    private var highestConcurrentAccesses = 0

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        lock.lock()
        concurrentAccesses += 1
        highestConcurrentAccesses = max(highestConcurrentAccesses, concurrentAccesses)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.01)

        lock.lock()
        concurrentAccesses -= 1
        lock.unlock()
        return false
    }

    var maximumConcurrentAccesses: Int {
        lock.lock()
        defer { lock.unlock() }
        return highestConcurrentAccesses
    }
}

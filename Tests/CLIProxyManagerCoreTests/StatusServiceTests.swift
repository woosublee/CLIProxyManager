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

    func testStatusPublishesSanitizedCompatibilitySummary() async throws {
        let report = RuntimeCompatibilityPolicy.current.report(
            environment: .init(
                operatingSystem: .macOS(major: 15, minor: 0),
                architecture: .x86_64,
                loginShell: "/Users/example.com/bin/zsh"
            ),
            artifacts: .init(bundled: .explicit(.darwinArm64), active: nil, pending: nil),
        )
        let artifacts = CompatibilityArtifacts(bundled: .legacy, active: .explicit(.darwinArm64), pending: .legacy)
        let authorizer = RecordingStatusCompatibilityAuthorizer(report: report)
        let status = try await StatusService(
            appLifecycle: AppLifecycleDouble(running: false),
            proxyRuntime: ProxyRuntimeDouble(port: 8317, running: false, activeVersion: nil),
            helperInspector: HelperInspectorDouble(installed: false, matchesBundled: false),
            compatibilityAuthorizer: authorizer,
            compatibilityArtifactsProvider: { artifacts },
            paths: ManagedPaths(rootDirectory: URL(fileURLWithPath: "/private/var/folders/example.com/.cliproxy-manager"))
        ).status()

        XCTAssertEqual(authorizer.reportedArtifacts, artifacts)
        XCTAssertEqual(status.compatibility.disposition, .blocked)
        XCTAssertEqual(status.compatibility.findings.map(\.code), ["unsupportedArchitecture"])
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(status), as: UTF8.self).contains("/private/"))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(status), as: UTF8.self).contains("example.com"))
    }

    func testStatusRedactsCustomHomeAbsolutePathsWithFixedPlaceholder() async throws {
        let status = try await StatusService(
            appLifecycle: AppLifecycleDouble(running: false, path: "/Volumes/Data/custom-home"),
            proxyRuntime: ProxyRuntimeDouble(port: 8317, running: false, activeVersion: nil),
            helperInspector: HelperInspectorDouble(
                path: "/Volumes/Data/custom-home/bin/cpm",
                installed: true,
                matchesBundled: true
            ),
            paths: ManagedPaths(rootDirectory: URL(fileURLWithPath: "/Volumes/Data/custom-home/.cliproxy-manager"))
        ).status()

        XCTAssertEqual(status.app.path, "<redacted>")
        XCTAssertEqual(status.helper.path, "<redacted>")
        XCTAssertEqual(status.proxy.logsPath, "<redacted>")
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(status), as: UTF8.self).contains("custom-home"))
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
    let path: String?

    init(running: Bool, path: String? = "/Applications/CLIProxyManager.app") {
        self.running = running
        self.path = path
    }

    func status() async throws -> AppLifecycleStatus {
        AppLifecycleStatus(installed: true, running: running, path: path, version: "0.1.12", build: "15")
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
    let path: String
    let installed: Bool
    let matchesBundled: Bool

    init(path: String = "/usr/local/bin/cpm", installed: Bool, matchesBundled: Bool) {
        self.path = path
        self.installed = installed
        self.matchesBundled = matchesBundled
    }

    func inspect() -> HelperStatus {
        HelperStatus(path: path, installed: installed, matchesBundled: matchesBundled)
    }
}

private final class RecordingStatusCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing, @unchecked Sendable {
    private let reportValue: RuntimeCompatibilityReport
    private let lock = NSLock()
    private var latestArtifacts: CompatibilityArtifacts?

    init(report: RuntimeCompatibilityReport) {
        reportValue = report
    }

    var reportedArtifacts: CompatibilityArtifacts? {
        lock.withLock { latestArtifacts }
    }

    func staticReport(artifacts: CompatibilityArtifacts) -> RuntimeCompatibilityReport {
        lock.withLock { latestArtifacts = artifacts }
        return reportValue
    }

    func report(artifacts: CompatibilityArtifacts) async -> RuntimeCompatibilityReport {
        lock.withLock { latestArtifacts = artifacts }
        return reportValue
    }

    func require(_: CompatibilityAction, artifacts: CompatibilityArtifacts) throws {
        lock.withLock { latestArtifacts = artifacts }
    }
}

private struct FixedStatusCompatibilityAuthorizer: RuntimeCompatibilityAuthorizing {
    let report: RuntimeCompatibilityReport

    func staticReport(artifacts _: CompatibilityArtifacts) -> RuntimeCompatibilityReport { report }

    func report(artifacts _: CompatibilityArtifacts) async -> RuntimeCompatibilityReport { report }

    func require(_: CompatibilityAction, artifacts _: CompatibilityArtifacts) throws {}
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

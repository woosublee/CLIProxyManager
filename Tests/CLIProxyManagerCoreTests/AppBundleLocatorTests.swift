import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class AppBundleLocatorTests: XCTestCase {
    func testLocatesRequiredResourcesInStandardInstallPath() throws {
        let fixture = try makeAppBundle(version: "0.1.12", build: "15")
        let locator = AppBundleLocator(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"),
            standardAppURL: fixture
        )

        let bundle = try locator.locateInstalledApp()

        XCTAssertEqual(bundle.appURL, fixture)
        XCTAssertEqual(bundle.proxyBinaryURL.path, fixture.appendingPathComponent("Contents/Resources/cliproxyapi/cliproxyapi").path)
        XCTAssertNil(bundle.cpmHelperURL)
        XCTAssertEqual(bundle.legacyHelperURL?.path, fixture.appendingPathComponent("Contents/Helpers/cliproxy-manager").path)
        XCTAssertEqual(bundle.version, "0.1.12")
        XCTAssertEqual(bundle.build, "15")
    }

    func testRejectsBundleWithUnexpectedIdentifier() throws {
        let fixture = try makeAppBundle(identifier: "example.invalid", version: "0.1.12", build: "15")
        let locator = AppBundleLocator(executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"), standardAppURL: fixture)

        XCTAssertThrowsError(try locator.locateInstalledApp()) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("CLIProxyManager.app has an unexpected bundle identifier."))
        }
    }

    func testDerivedFromHelperPathUsesEnclosingApp() throws {
        let fixture = try makeAppBundle(version: "0.2.0", build: "7")
        let helperURL = fixture.appendingPathComponent("Contents/Helpers/cpm")
        let locator = AppBundleLocator(executableURL: helperURL, standardAppURL: URL(fileURLWithPath: "/Applications/CLIProxyManager.app"))

        let bundle = try locator.locateInstalledApp()

        XCTAssertEqual(bundle.appURL, fixture)
        XCTAssertEqual(bundle.version, "0.2.0")
    }

    func testMissingProxyBinaryThrowsPrerequisite() throws {
        let fixture = try makeAppBundle(version: "0.1.12", build: "15", includeProxyBinary: false)
        let locator = AppBundleLocator(executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"), standardAppURL: fixture)

        XCTAssertThrowsError(try locator.locateInstalledApp()) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("CLIProxyManager.app is missing the proxy binary."))
        }
    }

    func testMissingProxyManifestThrowsPrerequisite() throws {
        let fixture = try makeAppBundle(version: "0.1.12", build: "15", includeProxyManifest: false)
        let locator = AppBundleLocator(executableURL: URL(fileURLWithPath: "/usr/local/bin/cpm"), standardAppURL: fixture)

        XCTAssertThrowsError(try locator.locateInstalledApp()) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .prerequisite("CLIProxyManager.app is missing the proxy manifest."))
        }
    }

    // MARK: - Helpers

    private func makeAppBundle(
        identifier: String = "com.woosublee.CLIProxyManager",
        version: String,
        build: String,
        includeProxyBinary: Bool = true,
        includeProxyManifest: Bool = true
    ) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("CLIProxyManagerTests")
            .appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("CLIProxyManager.app")
        let contents = appURL.appendingPathComponent("Contents")
        addTeardownBlock { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: contents.appendingPathComponent("Resources/cliproxyapi"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)

        if includeProxyBinary {
            fm.createFile(atPath: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi").path, contents: nil)
        }
        if includeProxyManifest {
            fm.createFile(atPath: contents.appendingPathComponent("Resources/cliproxyapi/cliproxyapi.manifest.json").path, contents: nil)
        }
        // No cpm helper (so cpmHelperURL = nil), but include legacyHelper
        fm.createFile(atPath: contents.appendingPathComponent("Helpers/cliproxy-manager").path, contents: nil)

        let plist: NSDictionary = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let plistURL = contents.appendingPathComponent("Info.plist")
        try plist.write(to: plistURL)

        return appURL
    }
}

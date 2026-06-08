import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class UpdaterConfigurationTests: XCTestCase {
    func testInfoPlistConfiguresSparkleFeedURL() throws {
        let infoPlist = try loadInfoPlist()

        XCTAssertEqual(
            infoPlist["SUFeedURL"] as? String,
            "https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml"
        )
    }

    func testInfoPlistConfiguresNonPlaceholderSparklePublicKey() throws {
        let infoPlist = try loadInfoPlist()
        let publicKey = try XCTUnwrap(infoPlist["SUPublicEDKey"] as? String)

        XCTAssertEqual(publicKey.count, 44, "SUPublicEDKey must be the exact 44-character base64 EdDSA public key Sparkle expects.")
        XCTAssertFalse(publicKey.localizedCaseInsensitiveContains("placeholder"))
        XCTAssertFalse(publicKey.localizedCaseInsensitiveContains("replace"))
    }

    func testInfoPlistEnablesAutomaticSparkleChecks() throws {
        let infoPlist = try loadInfoPlist()

        XCTAssertEqual(infoPlist["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testPackageConfiguresSparkleExactDependencyAndAppProduct() throws {
        let package = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertTrue(
            package.contains(".package(url: \"https://github.com/sparkle-project/Sparkle\", exact: \"2.9.2\")"),
            "Package.swift must pin Sparkle to exact 2.9.2."
        )
        XCTAssertTrue(
            package.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"),
            "CLIProxyManagerApp must depend on the Sparkle product."
        )
    }

    func testMinimumMacOSVersionMatchesBundledCLIProxyAPIRequirement() throws {
        let package = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)
        let infoPlist = try loadInfoPlist()

        XCTAssertTrue(
            package.contains("platforms: [.macOS(\"15.0\")]"),
            "Package.swift must declare macOS 15 because the bundled CLIProxyAPI binary requires macOS 15."
        )
        XCTAssertEqual(
            infoPlist["LSMinimumSystemVersion"] as? String,
            "15.0",
            "Info.plist must prevent launching on macOS versions below the bundled CLIProxyAPI binary requirement."
        )
        XCTAssertTrue(
            readme.contains("macOS 15 or later"),
            "README requirements must match the bundled CLIProxyAPI binary requirement."
        )
    }

    func testEntitlementsAllowBundledSparkleFrameworkToLoadUnderHardenedRuntime() throws {
        let entitlements = try loadPlist(named: "CLIProxyManager.entitlements")
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)

        XCTAssertEqual(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool, true)
        XCTAssertTrue(
            readme.contains("disable-library-validation")
                && readme.contains("non-Developer-ID Sparkle distribution path")
                && readme.contains("cliproxymanager"),
            "README should explain why disable-library-validation remains enabled for the current non-Developer-ID Sparkle distribution path."
        )
    }

    func testUpdaterServiceBridgesSparkleUpdaterKVOChangesToSwiftUI() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Services/UpdaterService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("updaterController.updater.publisher(for: \\.canCheckForUpdates)"),
            "UpdaterService must bridge SPUUpdater canCheckForUpdates KVO changes into objectWillChange."
        )
        XCTAssertTrue(
            source.contains("updaterController.updater.publisher(for: \\.automaticallyChecksForUpdates)"),
            "UpdaterService must bridge SPUUpdater automaticallyChecksForUpdates KVO changes into objectWillChange."
        )
        XCTAssertTrue(
            source.contains(".receive(on: DispatchQueue.main)"),
            "UpdaterService must deliver Sparkle KVO changes on the main queue before notifying SwiftUI."
        )
        XCTAssertTrue(
            source.contains("sink { [weak self] _ in") && source.contains("self?.objectWillChange.send()"),
            "UpdaterService must notify SwiftUI when Sparkle updater KVO publishers emit."
        )
    }

    func testUpdateSettingsCopyMatchesExpectedStrings() {
        XCTAssertEqual(UpdateSettingsCopy.automaticChecksLabel, "Check for updates")
        XCTAssertEqual(UpdateSettingsCopy.automaticChecksDescription, "Automatically check for new versions on launch.")
        XCTAssertEqual(UpdateSettingsCopy.checkNowButtonTitle, "Check now")
    }

    private func loadInfoPlist() throws -> [String: Any] {
        try loadPlist(named: "Info.plist")
    }

    private func loadPlist(named name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent(name))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }
}

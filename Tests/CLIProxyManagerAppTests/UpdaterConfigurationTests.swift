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

        XCTAssertGreaterThanOrEqual(publicKey.count, 40)
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

    func testEntitlementsAllowBundledSparkleFrameworkToLoadUnderHardenedRuntime() throws {
        let entitlements = try loadPlist(named: "CLIProxyManager.entitlements")

        XCTAssertEqual(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool, true)
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

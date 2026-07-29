import Foundation
import Sparkle
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

    func testInfoPlistStartsAsAgentAppSoMenuBarOnlyLaunchDoesNotShowDockIcon() throws {
        let infoPlist = try loadInfoPlist()

        XCTAssertEqual(
            infoPlist["LSUIElement"] as? Bool,
            true,
            "The bundle must start as an agent app so saved menu-bar-only launches never appear in the Dock before runtime preferences are applied."
        )
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

        XCTAssertNotNil(
            package.range(of: #"platforms:\s*\[[^\]]*\.macOS\("15\.0"\)"#, options: .regularExpression),
            "Package.swift must declare macOS 15 because the bundled CLIProxyAPI binary requires macOS 15."
        )
        XCTAssertEqual(
            infoPlist["LSMinimumSystemVersion"] as? String,
            "15.0",
            "Info.plist must prevent launching on macOS versions below the bundled CLIProxyAPI binary requirement."
        )
        XCTAssertTrue(
            readme.contains("macOS 15 이상"),
            "README 요구 사항은 번들 CLIProxyAPI의 macOS 15 요구 사항과 일치해야 합니다."
        )
    }

    func testEntitlementsAllowBundledSparkleFrameworkToLoadUnderHardenedRuntime() throws {
        let entitlements = try loadPlist(named: "CLIProxyManager.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.cs.disable-library-validation"] as? Bool, true)
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

    func testUpdaterServiceTreatsNoUpdateAsSuccessfulCheck() {
        let noUpdate = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue)
        )

        XCTAssertEqual(UpdaterService.updateCheckResult(for: nil), .succeeded)
        XCTAssertEqual(UpdaterService.updateCheckResult(for: noUpdate), .succeeded)
        XCTAssertEqual(
            UpdaterService.updateCheckResult(for: URLError(.notConnectedToInternet)),
            .failed(.network)
        )
    }

    func testUpdaterServiceRecordsDistinctSparkleDownloadLifecycleCallbacks() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Services/UpdaterService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("action: .discover, result: .succeeded"))
        XCTAssertTrue(source.contains("willDownloadUpdate"))
        XCTAssertTrue(source.contains("action: .download, result: .started"))
        XCTAssertTrue(source.contains("didDownloadUpdate"))
        XCTAssertTrue(source.contains("action: .download, result: .succeeded"))
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

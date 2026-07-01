import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class CLIProxyAPIUpdateUITests: XCTestCase {
    func testServerSettingsDescriptionShowsCurrentVersionByDefault() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .idle,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41"
        )
    }

    func testServerSettingsDescriptionShowsCurrentAndAvailableVersion() {
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )

        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .updateAvailable,
                availableUpdate: release,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Available: 7.2.42"
        )
    }

    func testServerSettingsDescriptionShowsCurrentAndPendingVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .pending,
                availableUpdate: nil,
                pendingUpdate: manifest("7.2.42")
            ),
            "Current version: 7.2.41 · Pending: 7.2.42"
        )
    }

    func testServerSettingsDescriptionShowsProgressStatesWithCurrentVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .checking,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Checking for updates…"
        )
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .downloading,
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Downloading and verifying update…"
        )
    }

    func testServerSettingsActionTitleReflectsState() {
        let release = CLIProxyAPIRelease(
            version: CLIProxyAPIVersion("7.2.42")!,
            tagName: "v7.2.42",
            assetName: "CLIProxyAPI_7.2.42_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )

        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .idle, availableUpdate: nil, pendingUpdate: nil), "Check now")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .checking, availableUpdate: nil, pendingUpdate: nil), "Checking…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .downloading, availableUpdate: nil, pendingUpdate: nil), "Updating…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .updateAvailable, availableUpdate: release, pendingUpdate: nil), "Update…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .pending, availableUpdate: nil, pendingUpdate: manifest("7.2.42")), "Apply now")
    }

    func testServerSettingsSourceShowsProgressIndicatorWhileCheckingOrUpdating() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("ProgressView()"))
        XCTAssertTrue(source.contains("cliProxyAPIUpdateService.isChecking || cliProxyAPIUpdateService.isUpdating"))
    }

    func testDashboardViewCopyClarifiesOnlyServerRestarts() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("Apply now and restart server"))
        XCTAssertTrue(source.contains("CLIProxyAPI binary updated. Restarting the app is not required."))
    }

    func testDashboardViewSourceStartsAutomaticCLIProxyAPICheckAndShowsConfirmationDialogs() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("await cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()"))
        XCTAssertTrue(source.contains("showCLIProxyAPIUpdatePrompt"))
        XCTAssertTrue(source.contains("showCLIProxyAPIApplyPrompt"))
        XCTAssertTrue(source.contains("Apply now and restart server"))
        XCTAssertTrue(source.contains("Apply on next server start"))
    }

    private func manifest(_ version: String) -> CLIProxyAPIBinaryManifest {
        CLIProxyAPIBinaryManifest(name: "cliproxyapi", version: version, commit: "commit", builtAt: "2026-07-01T00:00:00Z", sourceKind: .userUpdated, source: "https://example.com/archive.tar.gz", upstreamRepository: "router-for-me/CLIProxyAPI", upstreamTag: "v\(version)", upstreamAsset: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz", upstreamAssetSha256: "archive-sha", vendoredBinaryName: "cliproxyapi", vendoredBinarySha256: "binary-sha", vendoredBinarySizeBytes: 1, vendoredFromArchivePath: "cli-proxy-api")
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }
}

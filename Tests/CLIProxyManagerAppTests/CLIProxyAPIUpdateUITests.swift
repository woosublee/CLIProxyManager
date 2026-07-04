import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class CLIProxyAPIUpdateUITests: XCTestCase {
    func testUpdateDescriptionShowsCurrentVersionByDefault() {
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

    func testUpdateDescriptionShowsCurrentAndAvailableVersion() {
        let release = release("7.2.42")

        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .updateAvailable,
                availableUpdate: release,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Available version: 7.2.42"
        )
    }

    func testUpdateDescriptionShowsCurrentAndPendingVersion() {
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .pending,
                availableUpdate: nil,
                pendingUpdate: manifest("7.2.42")
            ),
            "Current version: 7.2.41 · Pending version: 7.2.42"
        )
    }

    func testUpdateDescriptionShowsProgressStatesWithCurrentVersion() {
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
        XCTAssertEqual(
            cliproxyAPIUpdateDescription(
                currentVersion: "7.2.41",
                state: .failed("Network unavailable"),
                availableUpdate: nil,
                pendingUpdate: nil
            ),
            "Current version: 7.2.41 · Last check failed."
        )
    }

    func testUpdateActionTitleReflectsTargetVersion() {
        let release = release("7.2.42")

        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .idle, availableUpdate: nil, pendingUpdate: nil), "Check now")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .checking, availableUpdate: nil, pendingUpdate: nil), "Checking…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .downloading, availableUpdate: nil, pendingUpdate: nil), "Updating…")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .updateAvailable, availableUpdate: release, pendingUpdate: nil), "Download 7.2.42")
        XCTAssertEqual(cliproxyAPIUpdateActionTitle(state: .pending, availableUpdate: nil, pendingUpdate: manifest("7.2.42")), "Apply 7.2.42 now")
    }

    func testDashboardAvailablePromptTitleShowsCurrentAndTargetVersion() {
        XCTAssertEqual(
            cliProxyAPIAvailableUpdatePromptTitle(currentVersion: "7.2.41", availableUpdate: release("7.2.42")),
            "Update CLIProxyAPI from 7.2.41 to 7.2.42?"
        )
        XCTAssertEqual(
            cliProxyAPIAvailableUpdatePromptTitle(currentVersion: "7.2.41", availableUpdate: nil),
            "CLIProxyAPI update available"
        )
    }

    func testDashboardPendingPromptCopyShowsCurrentAndPendingVersion() {
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: manifest("7.2.42")),
            "Apply CLIProxyAPI 7.2.42?"
        )
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptTitle(pendingUpdate: nil),
            "Apply CLIProxyAPI update?"
        )
        XCTAssertEqual(
            cliProxyAPIPendingUpdatePromptMessage(currentVersion: "7.2.41"),
            "Current version: 7.2.41"
        )
    }

    func testApplyButtonTitleShowsTargetVersionAndRestartWhenServerRuns() {
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: manifest("7.2.42"), isServerRunning: false),
            "Apply 7.2.42 now"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: manifest("7.2.42"), isServerRunning: true),
            "Apply 7.2.42 and restart server"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: nil, isServerRunning: false),
            "Apply now"
        )
        XCTAssertEqual(
            cliProxyAPIApplyButtonTitle(pendingUpdate: nil, isServerRunning: true),
            "Apply now and restart server"
        )
    }

    func testCLIProxyAPIUpdateControlsLiveInAboutSettingsInsteadOfServerSettings() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift"), encoding: .utf8)
        let serverRange = source.range(of: "struct ServerSettingsView: View")!.lowerBound..<source.range(of: "struct AdvancedSettingsView: View")!.lowerBound
        let aboutRange = source.range(of: "struct AboutSettingsView: View")!.lowerBound..<source.endIndex
        let serverSource = String(source[serverRange])
        let aboutSource = String(source[aboutRange])

        XCTAssertFalse(serverSource.contains("CLIProxyAPI binary"))
        XCTAssertFalse(serverSource.contains("cliProxyAPIUpdateService"))
        XCTAssertTrue(aboutSource.contains("CLIProxyAPI binary"))
        XCTAssertTrue(aboutSource.contains("cliProxyAPIUpdateService"))
        XCTAssertTrue(aboutSource.contains("ProgressView()"))
        XCTAssertTrue(aboutSource.contains("cliProxyAPIUpdateService.isChecking || cliProxyAPIUpdateService.isUpdating"))
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

    private func release(_ version: String) -> CLIProxyAPIRelease {
        CLIProxyAPIRelease(
            version: CLIProxyAPIVersion(version)!,
            tagName: "v\(version)",
            assetName: "CLIProxyAPI_\(version)_darwin_aarch64.tar.gz",
            assetURL: URL(string: "https://example.com/archive.tar.gz")!,
            assetSha256: "sha"
        )
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

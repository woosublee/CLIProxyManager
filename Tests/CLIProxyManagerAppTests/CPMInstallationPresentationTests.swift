import XCTest
@testable import CLIProxyManagerApp

final class CPMInstallationPresentationTests: XCTestCase {
    func testCurrentDescriptionReferencesSourceAppVersion() {
        XCTAssertEqual(
            CPMInstallationPresentation.description(
                for: .installedCurrent(version: "0.1.17")
            ),
            "Installed at /usr/local/bin/cpm (from app 0.1.17)."
        )
    }

    func testOutdatedDescriptionExplainsCpmSync() {
        XCTAssertEqual(
            CPMInstallationPresentation.description(
                for: .installedOutdated(
                    installedVersion: "0.1.15",
                    availableVersion: "0.1.17"
                )
            ),
            "Installed from app 0.1.15; cpm update included with app 0.1.17."
        )
    }
}

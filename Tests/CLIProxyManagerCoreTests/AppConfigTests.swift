import XCTest
@testable import CLIProxyManagerCore

final class AppConfigTests: XCTestCase {
    func testDiagnosticStatusStoresMessage() {
        let status = DiagnosticStatus(severity: .ready, title: "Ready", message: "All good")
        XCTAssertEqual(status.severity, .ready)
        XCTAssertEqual(status.title, "Ready")
        XCTAssertEqual(status.message, "All good")
    }
}

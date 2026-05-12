import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

final class ProviderSettingsSheetMetricsTests: XCTestCase {
    func testFooterActionButtonsUseRegularControlSize() {
        XCTAssertEqual(ProviderSettingsSheetMetrics.footerActionButtonControlSize, .regular)
    }
}

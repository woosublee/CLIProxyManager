import XCTest
@testable import CLIProxyManagerCore

final class LicenseNoticeTests: XCTestCase {
    func testCLIProxyAPINoticeMentionsMITAndProviderTerms() {
        let notice = LicenseNotice.cliProxyAPI

        XCTAssertEqual(notice.name, "CLIProxyAPI")
        XCTAssertEqual(notice.licenseName, "MIT License")
        XCTAssertTrue(notice.requiredNotice.contains("MIT License"))
        XCTAssertTrue(notice.providerTermsNotice.contains("각 provider 약관"))
        XCTAssertTrue(notice.providerTermsNotice.contains("공식 보증 제품이 아닙니다"))
        XCTAssertTrue(notice.fullLicenseText.contains("Copyright"))
        XCTAssertTrue(notice.fullLicenseText.contains("Permission is hereby granted"))
        XCTAssertTrue(notice.fullLicenseText.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }
}

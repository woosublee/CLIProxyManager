import CLIProxyManagerCore
import Foundation
import SwiftUI

enum LicenseResource {
    static func cliProxyAPILicenseURL(bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "CLIProxyAPI-LICENSE", withExtension: "txt", subdirectory: "Licenses")
    }

    static func cliProxyAPILicenseText(bundle: Bundle = .module) -> String {
        guard let url = cliProxyAPILicenseURL(bundle: bundle),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return LicenseNotice.cliProxyAPILicenseText
        }

        return text
    }
}

struct LicensesView: View {
    private let notice = LicenseNotice.cliProxyAPI
    private let fullLicenseText: String

    init(fullLicenseText: String = LicenseResource.cliProxyAPILicenseText()) {
        self.fullLicenseText = fullLicenseText
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Licenses & Notices")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 12) {
                    Text(notice.name)
                        .font(.title2.weight(.semibold))
                    Text(notice.licenseName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(notice.requiredNotice)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("CLIProxyAPI License Text")
                        .font(.title2.weight(.semibold))
                    Text(fullLicenseText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Provider Terms")
                        .font(.title2.weight(.semibold))
                    Text(notice.providerTermsNotice)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

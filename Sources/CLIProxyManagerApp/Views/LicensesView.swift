import CLIProxyManagerCore
import Foundation
import SwiftUI

enum LicenseResource {
    static func cliProxyAPILicenseURL(bundle: Bundle = .module, appBundle: Bundle = .main) -> URL? {
        appBundle.url(forResource: "CLIProxyAPI-LICENSE", withExtension: "txt", subdirectory: "Licenses")
            ?? bundle.url(forResource: "CLIProxyAPI-LICENSE", withExtension: "txt", subdirectory: "Licenses")
    }

    static func cliProxyAPILicenseText(bundle: Bundle = .module, appBundle: Bundle = .main) -> String {
        guard let url = cliProxyAPILicenseURL(bundle: bundle, appBundle: appBundle),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return LicenseNotice.cliProxyAPILicenseText
        }
        return text
    }
}

/// Compact attribution sheet — opened from the About tab.
struct LicensesSheet: View {
    let onClose: () -> Void
    private let notice = LicenseNotice.cliProxyAPI
    private let fullLicenseText = LicenseResource.cliProxyAPILicenseText()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open-source attribution")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityHint("Close the open source notices sheet.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(notice.licenseName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Text(notice.requiredNotice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup("Full license text") {
                        Text(fullLicenseText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .font(.system(size: 12, weight: .medium))

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider Terms")
                            .font(.system(size: 12, weight: .semibold))
                        Text(notice.providerTermsNotice)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 480)
    }
}

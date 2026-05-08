import CLIProxyManagerCore
import SwiftUI

struct LicensesView: View {
    private let notice = LicenseNotice.cliProxyAPI

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

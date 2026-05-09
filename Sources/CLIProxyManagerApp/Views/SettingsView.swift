import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selection = tab
                        } label: {
                            Label(tab.title, systemImage: tab.systemImage)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(selection == tab ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    if selection == tab {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.thinMaterial)

            ScrollView {
                switch selection {
                case .general:
                    GeneralSettingsView(viewModel: viewModel)
                case .server:
                    ServerSettingsView(viewModel: viewModel)
                case .advanced:
                    AdvancedSettingsView(viewModel: viewModel)
                case .about:
                    AboutSettingsView()
                }
            }
        }
        .frame(width: AppWindowMetrics.settingsWidth, height: AppWindowMetrics.settingsHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

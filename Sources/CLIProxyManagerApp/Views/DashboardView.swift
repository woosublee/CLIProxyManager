import CLIProxyManagerCore
import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 16)
    ]

    var body: some View {
        NavigationSplitView {
            List {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                Label("Accounts", systemImage: "person.crop.circle")
                Label("Models", systemImage: "cpu")
                Label("Logs", systemImage: "list.bullet.rectangle")
                Label("Settings", systemImage: "gearshape")
            }
            .navigationTitle("CLIProxy")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Profiles")
                        .font(.largeTitle.bold())

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(viewModel.cards) { card in
                            ProfileCardView(card: card)
                        }
                    }

                    StatusPanel(status: viewModel.serverStatus)
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await viewModel.refresh()
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct ProfileCardView: View {
    let card: ProfileCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.command)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(card.title)
                        .font(.title3.weight(.semibold))
                    Text(card.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(severityColor)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(card.status.title)
                    .font(.headline)
                    .foregroundStyle(severityColor)
                Text(card.status.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(severityColor.opacity(0.28), lineWidth: 1)
        }
    }

    private var iconName: String {
        switch card.status.severity {
        case .ready:
            "checkmark.seal.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch card.status.severity {
        case .ready:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

private struct StatusPanel: View {
    let status: DiagnosticStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server Status")
                .font(.title2.weight(.semibold))
            Text(status.title)
                .font(.headline)
                .foregroundStyle(severityColor)
            Text(status.message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(severityColor)
                .frame(width: 5)
                .clipShape(Capsule())
                .padding(.vertical, 18)
        }
    }

    private var severityColor: Color {
        switch status.severity {
        case .ready:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

import CLIProxyManagerCore
import SwiftUI

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var selection = DashboardSection.dashboard

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 16)
    ]

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .navigationTitle("CLIProxy Manager")
        } detail: {
            switch selection {
            case .dashboard:
                dashboardDetail
            case .licenses:
                LicensesView()
            case .accounts, .models, .logs, .settings:
                PlaceholderDetail(section: selection)
            }
        }
        .task {
            await viewModel.refresh()
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var dashboardDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Profiles")
                    .font(.largeTitle.bold())

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(viewModel.cards) { card in
                        ProfileCardView(card: card)
                    }
                }

                StatusPanel(title: "CLIProxyAPI Server", status: viewModel.serverStatus)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case dashboard
    case accounts
    case models
    case logs
    case licenses
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            "Dashboard"
        case .accounts:
            "Accounts"
        case .models:
            "Models"
        case .logs:
            "Logs"
        case .licenses:
            "Licenses"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            "gauge.with.dots.needle.67percent"
        case .accounts:
            "person.crop.circle"
        case .models:
            "cpu"
        case .logs:
            "list.bullet.rectangle"
        case .licenses:
            "doc.text.magnifyingglass"
        case .settings:
            "gearshape"
        }
    }
}

private struct PlaceholderDetail: View {
    let section: DashboardSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(section.title)
                .font(.title2.weight(.semibold))
            Text("이 영역은 다음 단계에서 설정과 진단 화면으로 연결됩니다.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
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
    let title: String
    let status: DiagnosticStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
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

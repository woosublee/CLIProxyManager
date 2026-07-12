import CLIProxyManagerCore
import SwiftUI

struct CompactUsageOverlayView: View {
    let providers: [MenuBarConnectedProvider]
    let maximumAccountHeight: CGFloat
    var onMeasurementChange: () -> Void = {}
    @State private var measurementState = CompactUsageMeasurementState()

    var body: some View {
        Group {
            if providers.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 20))
                    Text("No accounts")
                        .font(.system(size: 9.5, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityElement(children: .combine)
            } else {
                ZStack(alignment: .top) {
                    accountStack
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: CompactAccountHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                        .frame(height: 0)
                        .clipped()

                    ScrollView(.vertical, showsIndicators: needsScrolling) {
                        accountStack
                    }
                    .scrollDisabled(!needsScrolling)
                    .frame(height: viewportHeight)
                }
                .onPreferenceChange(CompactAccountHeightPreferenceKey.self) { height in
                    let measuredHeight = max(1, height)
                    if measurementState.record(height: measuredHeight) {
                        onMeasurementChange()
                    }
                }
            }
        }
        .onChange(of: providerIDs, initial: true) { _, providerIDs in
            if measurementState.updateProviderIDs(providerIDs) {
                onMeasurementChange()
            }
        }
    }

    private var providerIDs: [String] {
        providers.map(\.id.rawValue)
    }

    private var viewportHeight: CGFloat {
        measurementState.viewportHeight(maximumHeight: maximumAccountHeight)
    }

    private var needsScrolling: Bool {
        measurementState.height > maximumAccountHeight
    }

    private var accountStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                if index > 0 {
                    CompactUsageSeparator()
                }
                CompactUsageAccountView(provider: provider)
            }
        }
    }
}

private struct CompactUsageAccountView: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        let presentation = compactUsagePresentation(for: provider.subscriptionUsageState)
        VStack(spacing: 7) {
            VStack(spacing: 4) {
                ProviderAvatar(providerID: provider.id, size: 26)
                Text(provider.usageOverlayDisplayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(provider.usageOverlayDisplayName)
                    .accessibilityLabel(provider.usageOverlayDisplayName)
            }

            if presentation.rows.isEmpty {
                CompactUsagePlaceholderRow(presentation: presentation)
            } else {
                VStack(spacing: 5) {
                    ForEach(presentation.rows) { row in
                        HStack(spacing: 4) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(row.value)
                                .foregroundStyle(.primary)
                        }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let indicator = presentation.indicator {
                    CompactUsageIndicatorView(indicator: indicator)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

private struct CompactUsagePlaceholderRow: View {
    let presentation: CompactUsagePresentation

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.placeholder ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if let indicator = presentation.indicator {
                CompactUsageIndicatorView(indicator: indicator)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CompactUsageIndicatorView: View {
    let indicator: CompactUsageIndicator

    var body: some View {
        Image(systemName: indicator.symbolName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(indicatorColor)
            .help(indicator.message)
            .accessibilityLabel(indicator.message)
    }

    private var indicatorColor: Color {
        switch indicator {
        case .warning:
            BrandPalette.statusWarning
        case .loading, .disabled, .unavailable:
            .secondary
        }
    }
}

private struct CompactUsageSeparator: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .primary.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

private struct CompactAccountHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

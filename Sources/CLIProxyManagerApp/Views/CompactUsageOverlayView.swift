import CLIProxyManagerCore
import SwiftUI

struct CompactUsageOverlayView: View {
    let providers: [MenuBarConnectedProvider]
    let emptyMessage: String
    let maximumAccountHeight: CGFloat
    var onMeasurementChange: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var measurementState = CompactUsageMeasurementState()

    var body: some View {
        Group {
            if providers.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 20))
                    Text(emptyMessage)
                        .font(.system(size: 9.5, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityElement(children: .combine)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CompactAccountHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            } else {
                ZStack(alignment: .top) {
                    measurementAccountStack
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
                        visibleAccountStack
                    }
                    .scrollDisabled(!needsScrolling)
                    .frame(height: viewportHeight)
                }
            }
        }
        .onPreferenceChange(CompactAccountHeightPreferenceKey.self) { height in
            let measuredHeight = max(1, height)
            if measurementState.record(height: measuredHeight, providerIDs: providerIDs) {
                onMeasurementChange(min(measuredHeight, maximumAccountHeight))
            }
        }
        .onChange(of: providerIDs, initial: true) { _, providerIDs in
            if measurementState.updateProviderIDs(providerIDs) {
                onMeasurementChange(measurementState.viewportHeight(maximumHeight: maximumAccountHeight))
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
        measurementState.needsScrolling(maximumHeight: maximumAccountHeight)
    }

    private var measurementAccountStack: some View {
        VStack(spacing: 0) {
            accountRows(transition: .identity)
        }
    }

    private var visibleAccountStack: some View {
        LazyVStack(spacing: 0) {
            accountRows(transition: accountTransition)
        }
    }

    @ViewBuilder
    private func accountRows(transition: AnyTransition) -> some View {
        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
            VStack(spacing: 0) {
                if index > 0 {
                    CompactUsageSeparator()
                }
                CompactUsageAccountView(provider: provider)
            }
            .transition(transition)
        }
    }

    private var accountTransition: AnyTransition {
        accessibilityReduceMotion
            ? .identity
            : .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.12)),
                removal: .identity
            )
    }
}

private struct CompactUsageAccountView: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        let presentation = compactUsagePresentation(for: provider.subscriptionUsageState)
        VStack(spacing: 7) {
            VStack(spacing: 4) {
                ProviderAvatar(providerID: provider.id, size: 26)
                    .overlay(alignment: .trailing) {
                        if let indicator = presentation.headerIndicator {
                            CompactUsageIndicatorView(indicator: indicator)
                                .frame(
                                    width: SubscriptionUsageWarningLayout.iconFrameSize.width,
                                    height: SubscriptionUsageWarningLayout.iconFrameSize.height
                                )
                                .offset(x: SubscriptionUsageWarningLayout.compactAvatarTrailingOffset)
                        }
                    }
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
            if let indicator = presentation.placeholderIndicator {
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

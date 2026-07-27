import CLIProxyManagerCore
import SwiftUI

enum CodexResetCreditBadgeMetrics {
    static func minimumHeight(for avatarSize: CGFloat) -> CGFloat {
        avatarSize >= 26 ? 15 : 14
    }

    static func topTrailingOffset(for avatarSize: CGFloat) -> CGSize {
        avatarSize >= 26
            ? CGSize(width: 5, height: -5)
            : CGSize(width: 4, height: -4)
    }
}

struct CodexResetCreditBadge: View {
    let text: String
    let avatarSize: CGFloat

    var body: some View {
        let height = CodexResetCreditBadgeMetrics.minimumHeight(for: avatarSize)
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, text.count == 1 ? 0 : 3)
            .frame(minWidth: height, minHeight: height)
            .background(.ultraThinMaterial, in: Capsule())
            .background(
                LinearGradient(
                    colors: [
                        BrandPalette.statusError.opacity(0.78),
                        BrandPalette.statusError.opacity(0.62)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)
    }
}

struct CodexResetCreditAvatar: View {
    let providerID: ProviderRowState.ID
    let providerType: AuthProfileType
    let accountName: String
    let size: CGFloat
    let snapshot: CodexResetCreditsSnapshot?
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: CodexResetCreditsPresentation {
        codexResetCreditsPresentation(snapshot: snapshot, now: now)
    }

    var body: some View {
        Group {
            if let tooltip = presentation.tooltip,
               let accessibilityLabel = presentation.accessibilityLabel {
                decoratedAvatar
                    .help(tooltip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(accountName). \(accessibilityLabel)")
            } else {
                decoratedAvatar
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: presentation.badgeText
        )
    }

    private var decoratedAvatar: some View {
        ProviderAvatar(providerID: providerID, providerType: providerType, size: size)
            .overlay(alignment: .topTrailing) {
                if providerType == .codex, let badgeText = presentation.badgeText {
                    CodexResetCreditBadge(text: badgeText, avatarSize: size)
                        .offset(CodexResetCreditBadgeMetrics.topTrailingOffset(for: size))
                        .transition(.opacity)
                }
            }
    }
}

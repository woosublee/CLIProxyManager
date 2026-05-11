import SwiftUI

struct SettingsToastPresentation: Equatable {
    enum VerticalAlignment: Equatable {
        case bottom
    }

    enum HorizontalPlacement: Equatable {
        case center
    }

    enum CloseButtonPlacement: Equatable {
        case topTrailingOverlay
    }

    let alignment: VerticalAlignment
    let horizontalPlacement: HorizontalPlacement
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let closeButtonPlacement: CloseButtonPlacement
    let closeButtonHitSize: CGFloat
    let closeButtonTopPadding: CGFloat
    let closeButtonTrailingPadding: CGFloat
    let messageTrailingPadding: CGFloat

    static let `default` = SettingsToastPresentation(
        alignment: .bottom,
        horizontalPlacement: .center,
        minWidth: 92,
        maxWidth: 228,
        closeButtonPlacement: .topTrailingOverlay,
        closeButtonHitSize: 18,
        closeButtonTopPadding: 5,
        closeButtonTrailingPadding: 5,
        messageTrailingPadding: 24
    )

    func width(for message: String) -> CGFloat {
        min(maxWidth, max(minWidth, CGFloat(message.count * 6 + 44)))
    }
}

struct SettingsToastView: View {
    let message: String
    let onDismiss: () -> Void
    var presentation: SettingsToastPresentation = .default

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(BrandPalette.accent)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, presentation.messageTrailingPadding)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 7)
        .frame(width: presentation.width(for: message), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: presentation.closeButtonHitSize, height: presentation.closeButtonHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, presentation.closeButtonTopPadding)
            .padding(.trailing, presentation.closeButtonTrailingPadding)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    func settingsToast(message: String?, dismiss: @escaping () -> Void) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                SettingsToastView(message: message, onDismiss: dismiss)
                    .padding(.bottom, 14)
            }
        }
        .animation(.easeOut(duration: 0.18), value: message)
    }
}

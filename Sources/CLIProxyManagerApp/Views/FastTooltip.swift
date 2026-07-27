import SwiftUI

enum FastTooltipConfiguration {
    static let defaultDelayMilliseconds = 120
    static let defaultDelay: Duration = .milliseconds(defaultDelayMilliseconds)
    static let maximumWidth: CGFloat = 280
}

func normalizedFastTooltipText(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

private struct FastTooltipModifier: ViewModifier {
    let text: String?
    let edge: Edge
    let delay: Duration

    @State private var displayTask: Task<Void, Never>?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onHover(perform: updateHover)
            .popover(
                isPresented: Binding(
                    get: { normalizedFastTooltipText(text) != nil && isPresented },
                    set: { isPresented = $0 }
                ),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: edge
            ) {
                if let text = normalizedFastTooltipText(text) {
                    FastTooltipBubble(text: text)
                }
            }
            .onDisappear(perform: cancelPresentation)
    }

    private func updateHover(_ isHovering: Bool) {
        displayTask?.cancel()
        displayTask = nil

        guard isHovering, normalizedFastTooltipText(text) != nil else {
            isPresented = false
            return
        }

        displayTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isPresented = true
        }
    }

    private func cancelPresentation() {
        displayTask?.cancel()
        displayTask = nil
        isPresented = false
    }
}

private struct FastTooltipBubble: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: FastTooltipConfiguration.maximumWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(accessibilityContrast == .increased ? 0.42 : 0.18),
                        lineWidth: accessibilityContrast == .increased ? 1 : 0.5
                    )
            }
            .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.98, anchor: .center))
            )
    }
}

extension View {
    func fastTooltip(
        _ text: String?,
        edge: Edge = .top,
        delay: Duration = FastTooltipConfiguration.defaultDelay
    ) -> some View {
        modifier(FastTooltipModifier(text: text, edge: edge, delay: delay))
    }
}

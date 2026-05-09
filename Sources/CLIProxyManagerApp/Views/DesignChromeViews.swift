import SwiftUI

// MARK: - Brand & status palette (matches design tokens)

enum BrandPalette {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let codex = Color(red: 0.10, green: 0.10, blue: 0.10)       // #1A1A1A
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)        // #007AFF
    static let statusRunning = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let statusError = Color(red: 1.0, green: 0.271, blue: 0.227)     // #FF453A
}

// MARK: - Traffic lights

struct TrafficLightsView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
        }
        .frame(width: 52, height: 12)
        .frame(width: 64, height: 20, alignment: .leading)
    }
}

// MARK: - Status LED with optional pulse glow

struct StatusLED: View {
    enum State { case running, stopped, error }

    let state: State
    var size: CGFloat = 8
    var pulse: Bool = true
    @SwiftUI.State private var pulsePhase: Bool = false

    var body: some View {
        ZStack {
            if state == .running, pulse {
                Circle()
                    .fill(BrandPalette.statusRunning.opacity(pulsePhase ? 0.18 : 0.45))
                    .frame(width: size + (pulsePhase ? 12 : 6), height: size + (pulsePhase ? 12 : 6))
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsePhase)
            } else if state == .error, pulse {
                Circle()
                    .fill(BrandPalette.statusError.opacity(0.35))
                    .frame(width: size + 6, height: size + 6)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear { updatePulsePhase(for: state) }
        .onChange(of: state) { updatePulsePhase(for: $0) }
    }

    private func updatePulsePhase(for state: State) {
        guard pulse, state == .running else {
            pulsePhase = false
            return
        }
        pulsePhase.toggle()
    }

    private var color: Color {
        switch state {
        case .running: BrandPalette.statusRunning
        case .stopped: Color.secondary.opacity(0.65)
        case .error: BrandPalette.statusError
        }
    }
}

// MARK: - Slug pill — `$ command 📋`

struct SlugPill: View {
    let slug: String
    var onCopy: (() -> Void)? = nil
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var copied = false

    var body: some View {
        Button {
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(slug, forType: .string)
            #endif
            withAnimation(.easeInOut(duration: 0.18)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.18)) { copied = false }
            }
            onCopy?()
        } label: {
            HStack(spacing: 5) {
                Text("$")
                    .foregroundStyle(BrandPalette.accent)
                    .fontWeight(.bold)
                Text(slug)
                    .foregroundStyle(.primary.opacity(hovering ? 1.0 : 0.78))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 10, height: 10, alignment: .center)
                    .foregroundStyle(copied ? BrandPalette.statusRunning : .secondary)
                    .opacity(copied ? 1.0 : (hovering ? 0.9 : 0.45))
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(hovering ? BrandPalette.accent.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Provider avatar mark (32x32 rounded square with brand color)

struct ProviderAvatar: View {
    let providerID: ProviderRowState.ID
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Group {
                    switch providerID {
                    case .claude:
                        Text("A")
                            .font(.system(size: size * 0.46, weight: .heavy, design: .rounded))
                    case .codex:
                        Text("<>")
                            .font(.system(size: size * 0.30, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(.white)
            }
    }

    private var background: AnyShapeStyle {
        switch providerID {
        case .claude:
            AnyShapeStyle(BrandPalette.claude)
        case .codex:
            AnyShapeStyle(BrandPalette.codex)
        }
    }
}

// MARK: - Glass card modifier

struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(Color.white.opacity(opacity), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12, opacity: Double = 0.08) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}

// MARK: - Section header — small uppercase label + optional trailing count

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

import SwiftUI

struct AddProviderModal: View {
    @Environment(\.dismiss) private var dismiss
    let activeOAuthLoginProvider: ProviderRowState.ID?
    let onPick: (ProviderRowState.ID) -> Void
    let onCancelLogin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let activeOAuthLoginProvider {
                OAuthLoginProgressView(provider: activeOAuthLoginProvider)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            } else {
                providerPicker
            }

            Divider()

            HStack {
                if activeOAuthLoginProvider == nil {
                    Button("Cancel") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .controlSize(.regular)
                } else {
                    Button("Cancel Login") {
                        onCancelLogin()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: activeOAuthLoginProvider == nil ? 380 : 320)
    }

    private var providerPicker: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a provider")
                    .font(.system(size: 15, weight: .semibold))
                Text("Connect a CLI provider to route through the proxy.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ProviderTile(kind: .claude) {
                    onPick(.claude)
                }
                ProviderTile(kind: .codex) {
                    onPick(.codex)
                }
                ProviderTile(kind: .gemini)
                ProviderTile(kind: .qwen)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
    }
}

private struct OAuthLoginProgressView: View {
    let provider: ProviderRowState.ID

    var body: some View {
        HStack(spacing: 10) {
            ProviderAvatar(providerID: provider, size: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(providerName) OAuth")
                        .font(.system(size: 14, weight: .semibold))
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                }

                Text("Complete login in your browser.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerName: String {
        switch provider {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }
}

private struct ProviderTile: View {
    enum Kind {
        case claude, codex, gemini, qwen

        var name: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            case .qwen: return "Qwen"
            }
        }

        var isEnabled: Bool {
            switch self {
            case .claude, .codex: return true
            case .gemini, .qwen: return false
            }
        }
    }

    let kind: Kind
    var action: (() -> Void)? = nil
    @State private var hovering: Bool = false

    var body: some View {
        Button {
            action?()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    logo
                        .frame(width: 40, height: 40)
                    Text(kind.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("OAuth")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 12)

                if !kind.isEnabled {
                    Text("Soon")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                        .padding(6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering && kind.isEnabled ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hovering && kind.isEnabled ? BrandPalette.accent.opacity(0.6) : Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(kind.isEnabled ? 1.0 : 0.55)
        .disabled(!kind.isEnabled)
        .onHover { hovering = $0 && kind.isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var logo: some View {
        switch kind {
        case .claude:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandPalette.claude)
                .overlay {
                    Text("C")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
        case .codex:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandPalette.codex)
                .overlay {
                    Text(verbatim: "<>")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
        case .gemini:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.259, green: 0.522, blue: 0.957),  // #4285F4
                            Color(red: 0.608, green: 0.447, blue: 0.796),  // #9b72cb
                            Color(red: 0.851, green: 0.396, blue: 0.439)   // #d96570
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
        case .qwen:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.380, green: 0.361, blue: 0.929),  // #615ced
                            Color(red: 0.753, green: 0.322, blue: 0.725)   // #c052b9
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Text("Q")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }
}

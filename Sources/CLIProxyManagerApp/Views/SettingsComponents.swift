import CLIProxyManagerCore
import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            VStack(spacing: 0) {
                content
            }
            .glassCard(cornerRadius: 10, opacity: 0.05)
        }
        .padding(.bottom, 18)
    }
}

struct SettingsRow<Control: View>: View {
    let label: String
    var description: String?
    var isEnabled = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                if let description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .opacity(isEnabled ? 1 : 0.48)
        .disabled(!isEnabled)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 14)
        }
    }
}

struct SettingsSegmentedControl: View {
    let options: [String]
    let selected: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Text(option)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(option == selected ? Color.white.opacity(0.65) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SettingsStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var commit: ((Int) -> Void)? = nil
    @State private var text: String = ""

    var body: some View {
        HStack(spacing: 0) {
            TextField("", text: Binding(
                get: { text.isEmpty ? String(value) : text },
                set: { text = $0.filter { $0.isNumber } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 60, height: 26)
            .onSubmit { commitText() }
            .onChange(of: value) { _ in text = "" }

            VStack(spacing: 0) {
                Button {
                    let next = min(range.upperBound, value + 1)
                    if next != value { commit?(next); value = next; text = "" }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                Button {
                    let next = max(range.lowerBound, value - 1)
                    if next != value { commit?(next); value = next; text = "" }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 26)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.5),
                alignment: .leading
            )
        }
        .frame(height: 26)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear { text = "" }
    }

    private func commitText() {
        if let n = Int(text), range.contains(n), n != value {
            commit?(n)
            value = n
        }
        text = ""
    }
}

struct SettingsSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    if option.value != selection { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(option.value == selection
                                      ? AnyShapeStyle(.regularMaterial)
                                      : AnyShapeStyle(Color.clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(option.value == selection ? Color.primary.opacity(0.10) : Color.clear, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct AppearancePicker: View {
    let selection: AppearanceMode
    let onChange: (AppearanceMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button {
                    if mode != selection { onChange(mode) }
                } label: {
                    Text(label(for: mode))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(mode == selection
                                      ? AnyShapeStyle(.regularMaterial)
                                      : AnyShapeStyle(Color.clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(mode == selection ? Color.primary.opacity(0.10) : Color.clear, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func label(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.22))
                .frame(width: 36, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

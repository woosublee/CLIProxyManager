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

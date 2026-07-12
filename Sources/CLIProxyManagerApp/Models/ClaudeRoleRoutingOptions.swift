import CLIProxyManagerCore

struct ClaudeModelPickerRow: Equatable, Identifiable {
    let selection: ClaudeModelSelection
    let label: String

    var id: String {
        switch selection {
        case .automatic: "automatic"
        case .model(let model): "model:\(model)"
        }
    }
}

enum ClaudeRoleRoutingOptions {
    static func showsModels(connectionMode: AppConfig.ConnectionMode) -> Bool {
        connectionMode == .proxy
    }

    static func displayName(for model: String) -> String {
        let unprefixed = model.split(separator: "/").last.map(String.init) ?? model
        let normalized = unprefixed.replacingOccurrences(
            of: #"^claude-"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let components = normalized.split(separator: "-").map(String.init)
        guard let familyIndex = components.firstIndex(where: {
            ["opus", "sonnet", "haiku"].contains($0.lowercased())
        }) else {
            return unprefixed
        }

        let family = components[familyIndex].prefix(1).uppercased() + components[familyIndex].dropFirst()
        let version = components.dropFirst(familyIndex + 1).joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    static func rows(
        role: ClaudeModelFamily,
        selection: ClaudeModelSelection,
        options: [ClaudeModelOption]
    ) -> [ClaudeModelPickerRow] {
        let automaticLabel: String
        if let model = try? ClaudeModelResolver.resolveBaseModel(
            selection: .automatic,
            role: role,
            options: options
        ) {
            automaticLabel = "Automatic — \(displayName(for: model))"
        } else {
            automaticLabel = "Automatic"
        }

        var rows = [ClaudeModelPickerRow(selection: .automatic, label: automaticLabel)]
        rows += ClaudeModelResolver.orderedOptions(for: role, options: options).map {
            ClaudeModelPickerRow(selection: .model($0.id), label: displayName(for: $0.id))
        }
        if case .model(let current) = selection,
           !rows.contains(where: { $0.selection == .model(current) }) {
            rows.append(.init(
                selection: .model(current),
                label: "Unavailable — \(displayName(for: current))"
            ))
        }
        return rows
    }
}

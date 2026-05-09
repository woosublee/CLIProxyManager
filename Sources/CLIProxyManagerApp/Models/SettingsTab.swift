enum SettingsTab: CaseIterable, Hashable, Identifiable {
    case general
    case server
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .server:
            "Server"
        case .advanced:
            "Advanced"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "slider.horizontal.3"
        case .server:
            "server.rack"
        case .advanced:
            "wrench.and.screwdriver"
        case .about:
            "info.circle"
        }
    }
}

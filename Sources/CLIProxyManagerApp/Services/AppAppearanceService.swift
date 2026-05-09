import AppKit
import CLIProxyManagerCore

protocol AppAppearanceApplying: Sendable {
    @MainActor func apply(showDockIcon: Bool)
    @MainActor func apply(appearance: AppearanceMode)
}

struct AppAppearanceService: AppAppearanceApplying {
    @MainActor func apply(showDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon, let icon = AppMarkRenderer.dockIcon() {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    @MainActor func apply(appearance: AppearanceMode) {
        let nsAppearance: NSAppearance? = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApplication.shared.appearance = nsAppearance
    }
}

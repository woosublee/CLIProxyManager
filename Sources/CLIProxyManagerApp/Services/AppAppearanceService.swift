import AppKit
import CLIProxyManagerCore

protocol AppAppearanceApplying: Sendable {
    @MainActor func apply(showDockIcon: Bool)
    @MainActor func apply(appearance: AppearanceMode)
}

struct AppAppearanceService: AppAppearanceApplying {
    private let buildFlavor: AppBuildFlavor

    init(buildFlavor: AppBuildFlavor = .current) {
        self.buildFlavor = buildFlavor
    }

    @MainActor func renderedDockIcon() -> NSImage? {
        AppMarkRenderer.dockIcon(buildFlavor: buildFlavor)
    }

    @MainActor func apply(showDockIcon: Bool) {
        if showDockIcon, let icon = renderedDockIcon() {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
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

import AppKit

protocol AppAppearanceApplying: Sendable {
    @MainActor func apply(showDockIcon: Bool)
}

struct AppAppearanceService: AppAppearanceApplying {
    @MainActor func apply(showDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }
}

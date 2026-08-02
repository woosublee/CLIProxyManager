#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

private let appMarkPoints: [(CGFloat, CGFloat)] = [
    (28, 44), (38, 44), (46, 66), (56, 22), (64, 44), (74, 44)
]

private let appMarkViewportBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
private let appMarkMenuBarBounds = CGRect(x: 22, y: 15, width: 58, height: 58)
private let officialGradientColors = [
    Color(red: 0.0, green: 0.478, blue: 1.0),
    Color(red: 0.345, green: 0.337, blue: 0.839)
]

private func appMarkPath(in rect: CGRect, fitting sourceBounds: CGRect) -> Path {
    guard sourceBounds.width > 0, sourceBounds.height > 0 else { return Path() }
    let scale = min(rect.width / sourceBounds.width, rect.height / sourceBounds.height)
    let dx = rect.midX - sourceBounds.midX * scale
    let dy = rect.midY - sourceBounds.midY * scale
    var path = Path()
    for (index, point) in appMarkPoints.enumerated() {
        let cgPoint = CGPoint(x: dx + point.0 * scale, y: dy + point.1 * scale)
        if index == 0 {
            path.move(to: cgPoint)
        } else {
            path.addLine(to: cgPoint)
        }
    }
    return path
}

/// The waveform path from the design's AppMark icon, drawn on a 100×100 viewport.
struct AppMarkPath: Shape {
    func path(in rect: CGRect) -> Path {
        appMarkPath(in: rect, fitting: appMarkViewportBounds)
    }
}

struct AppMarkMenuBarPath: Shape {
    func path(in rect: CGRect) -> Path {
        appMarkPath(in: rect, fitting: appMarkMenuBarBounds)
    }
}

/// The full gradient AppIcon — used in the About tab and as the macOS Dock icon.
struct AppIconView: View {
    var size: CGFloat = 72
    var dropsShadow: Bool = true
    var buildFlavor: AppBuildFlavor = .official

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: officialGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: dropsShadow ? officialGradientColors[0].opacity(0.36) : .clear,
                    radius: dropsShadow ? size * 0.16 : 0,
                    y: dropsShadow ? size * 0.08 : 0
                )

            AppMarkPath()
                .stroke(
                    buildFlavor == .development ? Color.black.opacity(0.34) : .white,
                    style: StrokeStyle(
                        lineWidth: size * 0.06,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size, height: size)
        }
        .overlay {
            if buildFlavor == .development {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.82), lineWidth: size * 0.035)
                    .padding(size * 0.025)
            }
        }
        .frame(width: size, height: size)
    }
}

#if canImport(AppKit)
@MainActor
enum AppMarkRenderer {
    /// Renders the gradient app icon at high resolution for the macOS Dock.
    /// Apple's icon grid leaves ~10% padding around the rounded square inside the
    /// 1024×1024 canvas. Without that margin the icon visually appears larger
    /// than other Dock apps. Active artwork sits in 824×824, with corner radius
    /// scaled accordingly (185pt at the active size).
    static func dockIcon(buildFlavor: AppBuildFlavor) -> NSImage? {
        let canvasPoints: CGFloat = 1024
        let activePoints: CGFloat = 824

        let view = ZStack {
            Color.clear
            AppIconView(
                size: activePoints,
                dropsShadow: false,
                buildFlavor: buildFlavor
            )
        }
        .frame(width: canvasPoints, height: canvasPoints)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    static func menuBarIcon(
        presentation: MenuBarIconPresentation,
        buildFlavor: AppBuildFlavor,
        size: CGFloat = MenuBarIconMetrics.size
    ) -> NSImage? {
        let view = MenuBarIconArtwork(
            presentation: presentation,
            buildFlavor: buildFlavor
        )
        .environment(\.colorScheme, .light)
        .frame(width: size, height: size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
#endif

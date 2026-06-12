#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

private let appMarkPoints: [(CGFloat, CGFloat)] = [
    (28, 44), (38, 44), (46, 66), (56, 22), (64, 44), (74, 44)
]

private let appMarkViewportBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
private let appMarkMenuBarBounds = CGRect(x: 22, y: 15, width: 58, height: 58)

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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.0, green: 0.478, blue: 1.0),    // #007AFF
                            Color(red: 0.345, green: 0.337, blue: 0.839) // #5856D6
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: dropsShadow ? Color(red: 0.0, green: 0.478, blue: 1.0).opacity(0.36) : .clear,
                    radius: dropsShadow ? size * 0.16 : 0,
                    y: dropsShadow ? size * 0.08 : 0
                )
            AppMarkPath()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
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
    static func dockIcon() -> NSImage? {
        let canvasPoints: CGFloat = 1024
        let activePoints: CGFloat = 824

        let view = ZStack {
            Color.clear
            AppIconView(size: activePoints, dropsShadow: false)
        }
        .frame(width: canvasPoints, height: canvasPoints)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Renders a monochrome template version of the waveform for the menu bar.
    static func menuBarTemplate(size: CGFloat = 18) -> NSImage? {
        let inset: CGFloat = 2
        let view = AppMarkMenuBarPath()
            .stroke(Color.black, style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
            .frame(width: max(0, size - inset * 2), height: max(0, size - inset * 2))
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

#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// The waveform path from the design's AppMark icon, drawn on a 100×100 viewport.
struct AppMarkPath: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        let dx = (rect.width - 100 * s) / 2
        let dy = (rect.height - 100 * s) / 2
        var p = Path()
        let pts: [(CGFloat, CGFloat)] = [
            (28, 44), (38, 44), (46, 66), (56, 22), (64, 44), (74, 44)
        ]
        for (i, pt) in pts.enumerated() {
            let cgPoint = CGPoint(x: dx + pt.0 * s, y: dy + pt.1 * s)
            if i == 0 {
                p.move(to: cgPoint)
            } else {
                p.addLine(to: cgPoint)
            }
        }
        return p
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
        let view = AppMarkPath()
            .stroke(Color.black, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .padding(1)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
#endif

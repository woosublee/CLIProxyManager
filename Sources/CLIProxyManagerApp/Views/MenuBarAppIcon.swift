import SwiftUI

struct MenuBarIconPresentation: Equatable {
    let trim: CGFloat
    let opacity: Double
    let showsSlash: Bool

    static let connected = MenuBarIconPresentation(trim: 1, opacity: 1, showsSlash: false)
    static let stopped = MenuBarIconPresentation(trim: 1, opacity: 1, showsSlash: true)
    static let reducedMotionConnecting = MenuBarIconPresentation(
        trim: 0.65,
        opacity: 1,
        showsSlash: false
    )
}

enum MenuBarIconAnimation {
    static let drawDuration: TimeInterval = 0.9
    static let holdDuration: TimeInterval = 0.2
    static let fadeDuration: TimeInterval = 0.15
    static let blankDuration: TimeInterval = 0.15
    static let cycleDuration = drawDuration + holdDuration + fadeDuration + blankDuration
    static let framesPerSecond: TimeInterval = 15

    static func presentation(elapsed: TimeInterval) -> MenuBarIconPresentation {
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: cycleDuration)
        if phase < drawDuration {
            return MenuBarIconPresentation(
                trim: CGFloat(phase / drawDuration),
                opacity: 1,
                showsSlash: false
            )
        }
        if phase < drawDuration + holdDuration {
            return .connected
        }
        if phase < drawDuration + holdDuration + fadeDuration {
            let fadeElapsed = phase - drawDuration - holdDuration
            return MenuBarIconPresentation(
                trim: 1,
                opacity: 1 - fadeElapsed / fadeDuration,
                showsSlash: false
            )
        }
        return MenuBarIconPresentation(trim: 0, opacity: 0, showsSlash: false)
    }
}

enum MenuBarIconMetrics {
    static let size: CGFloat = 18
    static let officialMarkInset: CGFloat = 2
    static let developmentMarkInset: CGFloat = 3
    static let markLineWidth: CGFloat = 1.55
    static let slashLineWidth: CGFloat = 1.45
    static let developmentCornerRadius: CGFloat = 4
    static let developmentBorderWidth: CGFloat = 1
    static let officialSlashInset: CGFloat = 3.5
    static let developmentSlashInset: CGFloat = 4.25
}

struct MenuBarIconArtwork: View {
    let presentation: MenuBarIconPresentation
    let buildFlavor: AppBuildFlavor

    private var markInset: CGFloat {
        buildFlavor == .development
            ? MenuBarIconMetrics.developmentMarkInset
            : MenuBarIconMetrics.officialMarkInset
    }

    private var slashInset: CGFloat {
        buildFlavor == .development
            ? MenuBarIconMetrics.developmentSlashInset
            : MenuBarIconMetrics.officialSlashInset
    }

    var body: some View {
        ZStack {
            if buildFlavor == .development {
                RoundedRectangle(
                    cornerRadius: MenuBarIconMetrics.developmentCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    Color.primary,
                    lineWidth: MenuBarIconMetrics.developmentBorderWidth
                )
            }

            AppMarkMenuBarPath()
                .trim(from: 0, to: min(max(presentation.trim, 0), 1))
                .stroke(
                    Color.primary,
                    style: StrokeStyle(
                        lineWidth: MenuBarIconMetrics.markLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .opacity(presentation.opacity)
                .frame(
                    width: MenuBarIconMetrics.size - markInset * 2,
                    height: MenuBarIconMetrics.size - markInset * 2
                )

            if presentation.showsSlash {
                Path { path in
                    path.move(
                        to: CGPoint(
                            x: slashInset,
                            y: MenuBarIconMetrics.size - slashInset
                        )
                    )
                    path.addLine(
                        to: CGPoint(
                            x: MenuBarIconMetrics.size - slashInset,
                            y: slashInset
                        )
                    )
                }
                .stroke(
                    Color.primary,
                    style: StrokeStyle(
                        lineWidth: MenuBarIconMetrics.slashLineWidth,
                        lineCap: .round
                    )
                )
            }
        }
        .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)
    }
}

struct MenuBarAppIcon: View {
    let state: MenuBarIconState
    let buildFlavor: AppBuildFlavor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartedAt = Date()

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / MenuBarIconAnimation.framesPerSecond,
                paused: state != .connecting || reduceMotion
            )
        ) { context in
            MenuBarIconArtwork(
                presentation: presentation(at: context.date),
                buildFlavor: buildFlavor
            )
        }
        .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(state: state, buildFlavor: buildFlavor))
        .onAppear {
            if state == .connecting {
                animationStartedAt = Date()
            }
        }
        .onChange(of: state) { _, updatedState in
            if updatedState == .connecting {
                animationStartedAt = Date()
            }
        }
    }

    static func accessibilityLabel(
        state: MenuBarIconState,
        buildFlavor: AppBuildFlavor
    ) -> String {
        let buildSuffix = buildFlavor == .development ? ", development build" : ""
        return "CLIProxyManager \(state.accessibilityStatus)\(buildSuffix)"
    }

    private func presentation(at date: Date) -> MenuBarIconPresentation {
        switch state {
        case .connected:
            return .connected
        case .stopped:
            return .stopped
        case .connecting where reduceMotion:
            return .reducedMotionConnecting
        case .connecting:
            return MenuBarIconAnimation.presentation(
                elapsed: date.timeIntervalSince(animationStartedAt)
            )
        }
    }
}

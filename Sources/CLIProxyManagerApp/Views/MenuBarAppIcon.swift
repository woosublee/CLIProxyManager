#if canImport(AppKit)
import AppKit
#endif
import Foundation
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

    private var isDevelopment: Bool {
        buildFlavor == .development
    }

    private var markInset: CGFloat {
        isDevelopment
            ? MenuBarIconMetrics.developmentMarkInset
            : MenuBarIconMetrics.officialMarkInset
    }

    private var slashInset: CGFloat {
        isDevelopment
            ? MenuBarIconMetrics.developmentSlashInset
            : MenuBarIconMetrics.officialSlashInset
    }

    var body: some View {
        ZStack {
            if isDevelopment {
                RoundedRectangle(
                    cornerRadius: MenuBarIconMetrics.developmentCornerRadius,
                    style: .continuous
                )
                .fill(Color.primary)
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
                .blendMode(isDevelopment ? .destinationOut : .normal)
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
                .blendMode(isDevelopment ? .destinationOut : .normal)
            }
        }
        .compositingGroup()
        .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)
    }
}

@MainActor
final class MenuBarIconAnimator: ObservableObject {
    @Published private(set) var presentation = MenuBarIconPresentation.connected
    @Published private(set) var image: NSImage?

    private let buildFlavor: AppBuildFlavor
    private var timer: Timer?
    private var animationStartedAt = Date()
    private var currentState: MenuBarIconState?
    private var currentReduceMotion = false

    init(buildFlavor: AppBuildFlavor) {
        self.buildFlavor = buildFlavor
        image = AppMarkRenderer.menuBarIcon(
            presentation: presentation,
            buildFlavor: buildFlavor
        )
    }

    var isAnimating: Bool {
        timer != nil
    }

    func update(
        state: MenuBarIconState,
        reduceMotion: Bool,
        now: Date = Date()
    ) {
        defer {
            currentState = state
            currentReduceMotion = reduceMotion
        }

        switch state {
        case .connected:
            stopAnimation()
            setPresentation(.connected)
        case .stopped:
            stopAnimation()
            setPresentation(.stopped)
        case .connecting where reduceMotion:
            stopAnimation()
            setPresentation(.reducedMotionConnecting)
        case .connecting:
            let shouldRestart = currentState != .connecting || currentReduceMotion || timer == nil
            if shouldRestart {
                animationStartedAt = now
                setPresentation(MenuBarIconAnimation.presentation(elapsed: 0))
                startAnimation()
            }
        }
    }

    private func setPresentation(_ presentation: MenuBarIconPresentation) {
        self.presentation = presentation
        image = AppMarkRenderer.menuBarIcon(
            presentation: presentation,
            buildFlavor: buildFlavor
        )
    }

    private func startAnimation() {
        timer?.invalidate()
        let interval = 1 / MenuBarIconAnimation.framesPerSecond
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setPresentation(
                    MenuBarIconAnimation.presentation(
                        elapsed: Date().timeIntervalSince(self.animationStartedAt)
                    )
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

struct MenuBarAppIcon: View {
    let state: MenuBarIconState
    let buildFlavor: AppBuildFlavor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var animator: MenuBarIconAnimator

    init(state: MenuBarIconState, buildFlavor: AppBuildFlavor) {
        self.state = state
        self.buildFlavor = buildFlavor
        _animator = StateObject(
            wrappedValue: MenuBarIconAnimator(buildFlavor: buildFlavor)
        )
    }

    var body: some View {
        Image(nsImage: animator.image ?? Self.fallbackImage)
            .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(state: state, buildFlavor: buildFlavor))
            .onAppear(perform: updateAnimator)
            .onChange(of: state) { _, _ in
                updateAnimator()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateAnimator()
            }
    }

    private static let fallbackImage = NSImage(
        systemSymbolName: "waveform.path",
        accessibilityDescription: nil
    ) ?? NSImage(size: NSSize(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size))

    static func accessibilityLabel(
        state: MenuBarIconState,
        buildFlavor: AppBuildFlavor
    ) -> String {
        let buildSuffix = buildFlavor == .development ? ", development build" : ""
        return "CLIProxyManager \(state.accessibilityStatus)\(buildSuffix)"
    }

    private func updateAnimator() {
        animator.update(state: state, reduceMotion: reduceMotion)
    }
}

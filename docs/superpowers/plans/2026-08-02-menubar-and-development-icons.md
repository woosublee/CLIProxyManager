# 메뉴바 상태 및 Development 빌드 아이콘 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 아이콘만으로 CLIProxyAPI의 Connected, Connecting, Stopped 상태를 구분하고, development 앱을 메뉴바와 Dock/App Switcher에서 official build와 즉시 구분할 수 있게 한다.

**Architecture:** 기존 `DashboardViewModel`의 `serverControlState`와 `serverStatus`를 순수 상태 타입으로 변환하고, SwiftUI `MenuBarAppIcon`이 정적 파형·line-draw motion·사선을 렌더링한다. 기존 `CLIProxyManagerReleaseChannel` bundle marker를 `AppBuildFlavor`의 단일 기준으로 사용하며, 같은 build flavor를 메뉴바 view와 `AppAppearanceService`의 runtime Dock renderer에 주입한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- Official Connected 메뉴바 아이콘은 현재 18×18pt 파형과 동일한 인상을 유지한다.
- `.starting`만 Connecting으로 표현하고, `.stopping`, `.stopped`, `.error`, non-ready `.running`은 Stopped로 표현한다.
- Connecting motion은 총 1.4초다: draw 0.9초, hold 0.2초, fade 0.15초, blank/reset 0.15초.
- Connecting motion은 약 15fps로 갱신하고, Connecting이 아닐 때 animation schedule을 pause한다.
- Reduce Motion에서는 Connecting을 trim 0.65의 정적 partial waveform으로 표시한다.
- Development 메뉴바 variant는 corner radius 4pt, line width 1pt의 continuous rounded-square 외곽선을 사용한다.
- Development Dock variant는 `#FF9500`→`#FF2D55` gradient와 우측 하단 `D` badge를 사용한다.
- Build flavor는 `CLIProxyManagerReleaseChannel == "development"`일 때만 Development이며, 누락 또는 예상하지 않은 값은 Official이다.
- `AppConfig`, 사용자 설정, proxy polling/lifecycle, 앱 이름, bundle identifier, Finder용 정적 `.icns`, Makefile의 channel 생성 방식은 변경하지 않는다.
- 새 외부 dependency를 추가하지 않는다.
- 자동 검증은 전체 `swift test`와 `make development-bundle BUILD_DIR=build-development`까지 수행하고, 앱 실행 및 최종 시각 확인은 사용자가 담당한다.

## File Structure

- Create `Sources/CLIProxyManagerApp/Models/AppBuildFlavor.swift`: bundle marker를 Official/Development로 해석하는 순수 모델.
- Create `Sources/CLIProxyManagerApp/Models/MenuBarIconState.swift`: runtime server 상태를 Connected/Connecting/Stopped로 축약하고 accessibility 상태 문구를 제공하는 순수 모델.
- Create `Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift`: menu bar geometry, animation phase, Reduce Motion fallback, build 외곽선, accessibility label을 소유하는 SwiftUI view.
- Modify `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift`: 기존 Dock icon view/renderer에 build flavor별 gradient와 `D` badge를 추가한다.
- Modify `Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift`: 주입된 build flavor로 runtime Dock icon을 렌더링한다.
- Modify `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`: 하나의 current build flavor와 appearance service를 생성하고 menu bar 및 Dock 흐름에 공유한다.
- Create `Tests/CLIProxyManagerAppTests/MenuBarIconStateTests.swift`: 상태 매핑과 build marker 해석을 검증한다.
- Create `Tests/CLIProxyManagerAppTests/MenuBarAppIconTests.swift`: animation phase, Reduce Motion presentation, accessibility 문구, 정적 bitmap 차이를 검증한다.
- Modify `Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift`: Official/Development Dock render 차이와 1024×1024 canvas를 검증한다.
- Modify `Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift`: appearance service가 주입된 build flavor로 서로 다른 Dock icon을 만드는지 검증한다.
- Create `Tests/CLIProxyManagerAppTests/MenuBarIconWiringTests.swift`: app entry point가 published server 상태와 동일한 build flavor를 menu bar 및 Dock에 연결하는지 검증한다.

---

### Task 1: Build flavor 및 메뉴바 상태 모델

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/AppBuildFlavor.swift`
- Create: `Sources/CLIProxyManagerApp/Models/MenuBarIconState.swift`
- Create: `Tests/CLIProxyManagerAppTests/MenuBarIconStateTests.swift`

**Interfaces:**
- Produces: `enum AppBuildFlavor: Equatable, Sendable { case official, development }`
- Produces: `AppBuildFlavor.init(infoDictionary: [String: Any]?)`
- Produces: `AppBuildFlavor.current`
- Produces: `enum MenuBarIconState: Equatable, Sendable { case connected, connecting, stopped }`
- Produces: `MenuBarIconState.init(serverControlState: ServerControlState, severity: DiagnosticSeverity)`
- Produces: `MenuBarIconState.accessibilityStatus: String`
- Tasks 2–4 consume these exact types and signatures.

- [ ] **Step 1: Write failing state and build-flavor tests**

Create `Tests/CLIProxyManagerAppTests/MenuBarIconStateTests.swift`:

```swift
import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class MenuBarIconStateTests: XCTestCase {
    func testRunningReadyMapsToConnected() {
        XCTAssertEqual(
            MenuBarIconState(serverControlState: .running, severity: .ready),
            .connected
        )
    }

    func testStartingMapsToConnectingForEverySeverity() {
        for severity in [DiagnosticSeverity.ready, .warning, .error] {
            XCTAssertEqual(
                MenuBarIconState(serverControlState: .starting, severity: severity),
                .connecting
            )
        }
    }

    func testNonReadyAndInactiveStatesMapToStopped() {
        let cases: [(ServerControlState, DiagnosticSeverity)] = [
            (.running, .warning),
            (.running, .error),
            (.stopping, .ready),
            (.stopped, .warning),
            (.error("failed"), .error)
        ]

        for (controlState, severity) in cases {
            XCTAssertEqual(
                MenuBarIconState(serverControlState: controlState, severity: severity),
                .stopped
            )
        }
    }

    func testAccessibilityStatusMatchesState() {
        XCTAssertEqual(MenuBarIconState.connected.accessibilityStatus, "connected")
        XCTAssertEqual(MenuBarIconState.connecting.accessibilityStatus, "connecting")
        XCTAssertEqual(MenuBarIconState.stopped.accessibilityStatus, "stopped")
    }

    func testBuildFlavorUsesOnlyExactDevelopmentMarker() {
        XCTAssertEqual(AppBuildFlavor(infoDictionary: nil), .official)
        XCTAssertEqual(AppBuildFlavor(infoDictionary: [:]), .official)
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "official"]),
            .official
        )
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "Development"]),
            .official
        )
        XCTAssertEqual(
            AppBuildFlavor(infoDictionary: ["CLIProxyManagerReleaseChannel": "development"]),
            .development
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter MenuBarIconStateTests
```

Expected: compile failure because `MenuBarIconState` and `AppBuildFlavor` do not exist.

- [ ] **Step 3: Implement `AppBuildFlavor`**

Create `Sources/CLIProxyManagerApp/Models/AppBuildFlavor.swift`:

```swift
import Foundation

enum AppBuildFlavor: Equatable, Sendable {
    static let releaseChannelKey = "CLIProxyManagerReleaseChannel"

    case official
    case development

    init(infoDictionary: [String: Any]?) {
        let releaseChannel = infoDictionary?[Self.releaseChannelKey] as? String
        self = releaseChannel == "development" ? .development : .official
    }

    static var current: AppBuildFlavor {
        AppBuildFlavor(infoDictionary: Bundle.main.infoDictionary)
    }
}
```

- [ ] **Step 4: Implement `MenuBarIconState`**

Create `Sources/CLIProxyManagerApp/Models/MenuBarIconState.swift`:

```swift
import CLIProxyManagerCore

enum MenuBarIconState: Equatable, Sendable {
    case connected
    case connecting
    case stopped

    init(serverControlState: ServerControlState, severity: DiagnosticSeverity) {
        switch serverControlState {
        case .starting:
            self = .connecting
        case .running where severity == .ready:
            self = .connected
        case .running, .stopping, .stopped, .error:
            self = .stopped
        }
    }

    var accessibilityStatus: String {
        switch self {
        case .connected: "connected"
        case .connecting: "connecting"
        case .stopped: "stopped"
        }
    }
}
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter MenuBarIconStateTests
```

Expected: 5 tests, 0 failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/CLIProxyManagerApp/Models/AppBuildFlavor.swift \
  Sources/CLIProxyManagerApp/Models/MenuBarIconState.swift \
  Tests/CLIProxyManagerAppTests/MenuBarIconStateTests.swift
git commit -m "feat: model menu bar icon states" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 상태 기반 메뉴바 아이콘과 line-draw motion

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift`
- Create: `Tests/CLIProxyManagerAppTests/MenuBarAppIconTests.swift`
- Uses unchanged shape: `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift:37-41`

**Interfaces:**
- Consumes: `MenuBarIconState`
- Consumes: `AppBuildFlavor`
- Produces: `struct MenuBarIconPresentation: Equatable`
- Produces: `MenuBarIconPresentation.connected`, `.stopped`, `.reducedMotionConnecting`
- Produces: `MenuBarIconAnimation.presentation(elapsed:) -> MenuBarIconPresentation`
- Produces: `struct MenuBarIconArtwork: View`
- Produces: `struct MenuBarAppIcon: View` with `init(state:buildFlavor:)`
- Task 4 consumes `MenuBarAppIcon` directly from `CLIProxyManagerApp`.

- [ ] **Step 1: Write failing animation and accessibility tests**

Create the first part of `Tests/CLIProxyManagerAppTests/MenuBarAppIconTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import CLIProxyManagerApp

@MainActor
final class MenuBarAppIconTests: XCTestCase {
    func testAnimationTimingUsesApprovedCycle() {
        XCTAssertEqual(MenuBarIconAnimation.drawDuration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.holdDuration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.fadeDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.blankDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.cycleDuration, 1.4, accuracy: 0.0001)
        XCTAssertEqual(MenuBarIconAnimation.framesPerSecond, 15, accuracy: 0.0001)
    }

    func testAnimationDrawHoldFadeBlankAndWrap() {
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 0),
            trim: 0,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 0.45),
            trim: 0.5,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.0),
            trim: 1,
            opacity: 1
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.175),
            trim: 1,
            opacity: 0.5
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.325),
            trim: 0,
            opacity: 0
        )
        assertPresentation(
            MenuBarIconAnimation.presentation(elapsed: 1.4),
            trim: 0,
            opacity: 1
        )
    }

    func testReducedMotionUsesStaticPartialWaveform() {
        assertPresentation(
            MenuBarIconPresentation.reducedMotionConnecting,
            trim: 0.65,
            opacity: 1
        )
        XCTAssertFalse(MenuBarIconPresentation.reducedMotionConnecting.showsSlash)
    }

    func testAccessibilityLabelsIncludeStateAndDevelopmentBuild() {
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .connected, buildFlavor: .official),
            "CLIProxyManager connected"
        )
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .connecting, buildFlavor: .development),
            "CLIProxyManager connecting, development build"
        )
        XCTAssertEqual(
            MenuBarAppIcon.accessibilityLabel(state: .stopped, buildFlavor: .development),
            "CLIProxyManager stopped, development build"
        )
    }

    private func assertPresentation(
        _ presentation: MenuBarIconPresentation,
        trim: CGFloat,
        opacity: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(presentation.trim, trim, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(presentation.opacity, opacity, accuracy: 0.0001, file: file, line: line)
        XCTAssertFalse(presentation.showsSlash, file: file, line: line)
    }
}
```

- [ ] **Step 2: Write failing bitmap and source-contract tests**

Append these methods inside the same test class:

```swift
func testConnectedStoppedConnectingAndDevelopmentRenderDifferently() throws {
    let connected = try renderedData(
        presentation: .connected,
        buildFlavor: .official
    )
    let connecting = try renderedData(
        presentation: .reducedMotionConnecting,
        buildFlavor: .official
    )
    let stopped = try renderedData(
        presentation: .stopped,
        buildFlavor: .official
    )
    let development = try renderedData(
        presentation: .connected,
        buildFlavor: .development
    )

    XCTAssertNotEqual(connected, connecting)
    XCTAssertNotEqual(connected, stopped)
    XCTAssertNotEqual(connected, development)
}

func testIconMetricsPreserveApprovedGeometry() {
    XCTAssertEqual(MenuBarIconMetrics.size, 18)
    XCTAssertEqual(MenuBarIconMetrics.officialMarkInset, 2)
    XCTAssertEqual(MenuBarIconMetrics.developmentMarkInset, 3)
    XCTAssertEqual(MenuBarIconMetrics.developmentCornerRadius, 4)
    XCTAssertEqual(MenuBarIconMetrics.developmentBorderWidth, 1)
}

func testAnimatedViewUsesPausedTimelineAndReduceMotion() throws {
    let source = try String(
        contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(source.contains("TimelineView"))
    XCTAssertTrue(source.contains("accessibilityReduceMotion"))
    XCTAssertTrue(source.contains("paused: state != .connecting || reduceMotion"))
    XCTAssertTrue(source.contains(".onChange(of: state)"))
}

private func renderedData(
    presentation: MenuBarIconPresentation,
    buildFlavor: AppBuildFlavor
) throws -> Data {
    let view = MenuBarIconArtwork(
        presentation: presentation,
        buildFlavor: buildFlavor
    )
    .environment(\.colorScheme, .light)
    .frame(width: MenuBarIconMetrics.size, height: MenuBarIconMetrics.size)

    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(
        x: 0,
        y: 0,
        width: MenuBarIconMetrics.size,
        height: MenuBarIconMetrics.size
    )
    hostingView.layoutSubtreeIfNeeded()

    let bitmap = try XCTUnwrap(
        hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let bitmapData = try XCTUnwrap(bitmap.bitmapData)
    return Data(bytes: bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
swift test --filter MenuBarAppIconTests
```

Expected: compile failure because the menu bar presentation, animation, metrics, artwork, and app icon view do not exist.

- [ ] **Step 4: Implement deterministic presentation and animation timing**

Create the top half of `Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift`:

```swift
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
```

- [ ] **Step 5: Implement static menu bar artwork**

Append `MenuBarIconArtwork` to the same file:

```swift
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
```

- [ ] **Step 6: Implement animated `MenuBarAppIcon` with Reduce Motion**

Append the public app view to the same file:

```swift
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
```

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter MenuBarAppIconTests
```

Expected: 7 tests, 0 failures. If floating-point boundary behavior differs at exactly `1.4`, preserve the modulo-based wrap semantics and adjust only the test tolerance, not the approved timing constants.

- [ ] **Step 8: Commit Task 2**

```bash
git add Sources/CLIProxyManagerApp/Views/MenuBarAppIcon.swift \
  Tests/CLIProxyManagerAppTests/MenuBarAppIconTests.swift
git commit -m "feat: render menu bar connection states" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Official 및 Development Dock icon renderer

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift:43-111`
- Modify: `Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift:4-25`
- Modify: `Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift`

**Interfaces:**
- Consumes: `AppBuildFlavor`
- Produces: `AppIconView.init(size:dropsShadow:buildFlavor:)`, with `buildFlavor` defaulting to `.official`
- Produces: `AppMarkRenderer.dockIcon(buildFlavor:) -> NSImage?`
- Produces: `AppAppearanceService.init(buildFlavor:)`, defaulting to `.current`
- Produces: `AppAppearanceService.renderedDockIcon() -> NSImage?`
- Keeps `AppAppearanceApplying` unchanged, so all existing test doubles remain source-compatible.
- Task 4 injects one `AppAppearanceService(buildFlavor:)` into launch bootstrap and `DashboardViewModel`.

- [ ] **Step 1: Write failing Dock renderer tests**

Extend `Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift` with:

```swift
func testDockIconsRenderAtCanvasSizeAndDifferByBuildFlavor() throws {
    let official = try XCTUnwrap(AppMarkRenderer.dockIcon(buildFlavor: .official))
    let development = try XCTUnwrap(AppMarkRenderer.dockIcon(buildFlavor: .development))

    XCTAssertEqual(official.size.width, 1024, accuracy: 0.01)
    XCTAssertEqual(official.size.height, 1024, accuracy: 0.01)
    XCTAssertEqual(development.size.width, 1024, accuracy: 0.01)
    XCTAssertEqual(development.size.height, 1024, accuracy: 0.01)
    XCTAssertNotEqual(official.tiffRepresentation, development.tiffRepresentation)
}

func testDefaultAppIconViewRemainsOfficial() {
    XCTAssertEqual(AppIconView().buildFlavor, .official)
}
```

Change `AppIconView.buildFlavor` to internal visibility when implementing so `@testable` can assert the default without exposing a public API.

- [ ] **Step 2: Write failing appearance-service flavor test**

Add this test to `Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift`:

```swift
func testAppearanceServiceRendersInjectedBuildFlavor() throws {
    let official = try XCTUnwrap(
        AppAppearanceService(buildFlavor: .official).renderedDockIcon()
    )
    let development = try XCTUnwrap(
        AppAppearanceService(buildFlavor: .development).renderedDockIcon()
    )

    XCTAssertNotEqual(official.tiffRepresentation, development.tiffRepresentation)
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
swift test --filter AppMarkRendererTests
swift test --filter AppAppearanceServiceTests
```

Expected: compile failures because the build-flavor initializers and renderer methods do not exist.

- [ ] **Step 4: Add build-flavor styling to `AppIconView`**

Modify `AppIconView` in `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift` to add the property and use build-specific gradient values:

```swift
struct AppIconView: View {
    var size: CGFloat = 72
    var dropsShadow: Bool = true
    var buildFlavor: AppBuildFlavor = .official

    private var gradientColors: [Color] {
        switch buildFlavor {
        case .official:
            [
                Color(red: 0.0, green: 0.478, blue: 1.0),
                Color(red: 0.345, green: 0.337, blue: 0.839)
            ]
        case .development:
            [
                Color(red: 1.0, green: 149.0 / 255.0, blue: 0.0),
                Color(red: 1.0, green: 45.0 / 255.0, blue: 85.0 / 255.0)
            ]
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: dropsShadow ? gradientColors[0].opacity(0.36) : .clear,
                    radius: dropsShadow ? size * 0.16 : 0,
                    y: dropsShadow ? size * 0.08 : 0
                )

            AppMarkPath()
                .stroke(
                    .white,
                    style: StrokeStyle(
                        lineWidth: size * 0.06,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size, height: size)
        }
        .overlay(alignment: .bottomTrailing) {
            if buildFlavor == .development {
                Text("D")
                    .font(.system(size: size * 0.16, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.25, height: size * 0.25)
                    .background(Circle().fill(Color.black.opacity(0.72)))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.92), lineWidth: size * 0.018)
                    }
                    .padding(size * 0.075)
            }
        }
        .frame(width: size, height: size)
    }
}
```

Preserve the existing comment and 1024×1024 / 824×824 Dock grid constants.

- [ ] **Step 5: Make `AppMarkRenderer` accept build flavor**

Replace the Dock renderer signature and the inner `AppIconView` construction:

```swift
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
```

이 작업에서는 `menuBarTemplate(size:)`와 기존 두 template renderer 테스트를 그대로 유지한다. Task 4에서 SwiftUI 메뉴바 view를 연결한 직후 runtime call site, renderer method, 두 테스트를 함께 제거한다.

- [ ] **Step 6: Inject build flavor into `AppAppearanceService`**

Modify `Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift` without changing the protocol:

```swift
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
```

- [ ] **Step 7: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter AppMarkRendererTests
swift test --filter AppAppearanceServiceTests
```

Expected: all tests in both suites pass. Existing menu-bar template tests remain green until Task 4 removes the obsolete API and updates those tests.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift \
  Sources/CLIProxyManagerApp/Services/AppAppearanceService.swift \
  Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift \
  Tests/CLIProxyManagerAppTests/AppAppearanceServiceTests.swift
git commit -m "feat: distinguish development dock icon" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: App entry point에 상태 및 build flavor 연결

**Files:**
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift:5-124`
- Modify: `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift:97-110`
- Modify: `Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift`
- Create: `Tests/CLIProxyManagerAppTests/MenuBarIconWiringTests.swift`

**Interfaces:**
- Consumes: `AppBuildFlavor.current`
- Consumes: `AppAppearanceService.init(buildFlavor:)`
- Consumes: `MenuBarIconState.init(serverControlState:severity:)`
- Consumes: `MenuBarAppIcon.init(state:buildFlavor:)`
- Removes: `AppMarkRenderer.menuBarTemplate(size:)`, because menu bar rendering is now a non-optional SwiftUI view.
- Keeps the full-gradient `AppIconView` used by the About screen defaulting to Official.

- [ ] **Step 1: Write failing app-wiring contract test**

Create `Tests/CLIProxyManagerAppTests/MenuBarIconWiringTests.swift`:

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class MenuBarIconWiringTests: XCTestCase {
    func testAppSharesBuildFlavorAcrossMenuBarAndDock() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private let buildFlavor: AppBuildFlavor"))
        XCTAssertTrue(source.contains("let buildFlavor = AppBuildFlavor.current"))
        XCTAssertTrue(source.contains("AppAppearanceService(buildFlavor: buildFlavor)"))
        XCTAssertTrue(source.contains("appAppearanceService: appAppearanceService"))
        XCTAssertTrue(source.contains("MenuBarAppIcon("))
        XCTAssertTrue(source.contains("serverControlState: viewModel.serverControlState"))
        XCTAssertTrue(source.contains("severity: viewModel.serverStatus.severity"))
        XCTAssertTrue(source.contains("buildFlavor: buildFlavor"))
        XCTAssertFalse(source.contains("AppMarkRenderer.menuBarTemplate"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 2: Run the wiring test and verify RED**

Run:

```bash
swift test --filter MenuBarIconWiringTests
```

Expected: failure because `CLIProxyManagerApp.swift` still creates the default appearance service and uses `AppMarkRenderer.menuBarTemplate()`.

- [ ] **Step 3: Share one build flavor and appearance service during app initialization**

Add this stored property near the existing `@StateObject` properties in `CLIProxyManagerApp`:

```swift
private let buildFlavor: AppBuildFlavor
```

Replace the complete `init()` with this implementation:

```swift
init() {
    let buildFlavor = AppBuildFlavor.current
    let appAppearanceService = AppAppearanceService(buildFlavor: buildFlavor)
    self.buildFlavor = buildFlavor

    let config = LaunchAppearanceBootstrapper(
        appAppearanceService: appAppearanceService
    ).applySavedDockVisibility()
    let appLogger = AppLogger(minimumLevel: config.runtimeLogConfiguration.appMinimumLevel)
    let viewModel = DashboardViewModel(
        config: config,
        appAppearanceService: appAppearanceService,
        appLogger: appLogger
    )
    let cliProxyAPIUpdateService = CLIProxyAPIUpdateService(appLogger: appLogger)
    _viewModel = StateObject(wrappedValue: viewModel)
    _cliProxyAPIUpdateService = StateObject(wrappedValue: cliProxyAPIUpdateService)
    _usageOverlayWindowController = StateObject(
        wrappedValue: UsageOverlayWindowController(
            viewModel: viewModel,
            placementPersistence: .userDefaults()
        )
    )
    viewModel.beginApplicationLaunch {
        cliProxyAPIUpdateService.reloadStoredStatus()
    }
    let quitCoordinator = QuitCoordinator(
        shouldStopServerBeforeQuit: {
            viewModel.serverControlState.shouldStopServerBeforeQuit
        },
        beginTermination: {
            viewModel.beginTermination()
        },
        beforeTerminate: {
            try await viewModel.prepareForTermination()
        },
        cancelTerminationPreparation: {
            viewModel.cancelTerminationPreparation()
        }
    )
    _quitCoordinator = StateObject(wrappedValue: quitCoordinator)
    _updaterService = StateObject(wrappedValue: UpdaterService(appLogger: appLogger))
    applicationDelegate.quitCoordinator = quitCoordinator
}
```

- [ ] **Step 4: Replace the static menu bar image with the state-aware SwiftUI view**

Replace the `MenuBarExtra` label body in `CLIProxyManagerApp.swift`:

```swift
} label: {
    MenuBarAppIcon(
        state: MenuBarIconState(
            serverControlState: viewModel.serverControlState,
            severity: viewModel.serverStatus.severity
        ),
        buildFlavor: buildFlavor
    )
}
```

Do not add an independent polling task. The label must consume the existing `@Published` server properties directly.

- [ ] **Step 5: Remove the obsolete menu bar NSImage renderer and tests**

Delete `AppMarkRenderer.menuBarTemplate(size:)` from `Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift`.

Delete these two obsolete tests from `AppMarkRendererTests.swift`:

```swift
func testMenuBarTemplateRendersSquareTemplateImage()
func testMenuBarTemplateHandlesVerySmallSizes()
```

Retain the Dock flavor tests added in Task 3. Menu bar geometry and render differences are now covered by `MenuBarAppIconTests`.

- [ ] **Step 6: Run wiring and related focused tests**

Run:

```bash
swift test --filter MenuBarIconWiringTests
swift test --filter MenuBarIconStateTests
swift test --filter MenuBarAppIconTests
swift test --filter AppMarkRendererTests
swift test --filter AppAppearanceServiceTests
```

Expected: all focused suites pass. The app target must compile without `menuBarTemplate` references.

- [ ] **Step 7: Commit Task 4**

```bash
git add Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift \
  Sources/CLIProxyManagerApp/Views/AppMarkIcon.swift \
  Tests/CLIProxyManagerAppTests/AppMarkRendererTests.swift \
  Tests/CLIProxyManagerAppTests/MenuBarIconWiringTests.swift
git commit -m "feat: wire runtime menu bar icon states" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: 전체 회귀 및 Development bundle 검증

**Files:**
- Verify only; no tracked source file should change.
- Generated and intentionally untracked: `build-development/CLIProxyManager.app`

**Interfaces:**
- Consumes the complete implementation from Tasks 1–4.
- Produces a verified development app bundle for the user’s manual Light/Dark, motion, menu bar, Dock, and App Switcher inspection.

- [ ] **Step 1: Run formatting and whitespace validation**

Run:

```bash
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 2: Run the complete Swift test suite**

Run:

```bash
swift test
```

Expected: all `CLIProxyManagerCoreTests` and `CLIProxyManagerAppTests` pass with 0 failures.

- [ ] **Step 3: Build and structurally verify the development app bundle**

Run:

```bash
make development-bundle BUILD_DIR=build-development
```

Expected: debug products compile, `scripts/verify-app-structure.sh` prints `App structure verification passed`, and `build-development/CLIProxyManager.app` exists.

- [ ] **Step 4: Verify the development release-channel marker**

Run:

```bash
plutil -extract CLIProxyManagerReleaseChannel raw \
  build-development/CLIProxyManager.app/Contents/Info.plist
```

Expected:

```text
development
```

- [ ] **Step 5: Verify official packaging metadata was not changed**

Run:

```bash
git diff c076519 -- Makefile Info.plist CLIProxyManager.icns
```

Expected: no diff. The runtime development icon must not require a second static `.icns`, app name, bundle identifier, or Makefile channel branch.

- [ ] **Step 6: Review final tracked diff and generated artifact status**

Run:

```bash
git status --short
git log -5 --oneline
```

Expected: implementation commits are present. The only untracked generated output may be `build-development/`; do not add it to git.

- [ ] **Step 7: Hand off manual visual verification to the user**

Provide the app path:

```text
build-development/CLIProxyManager.app
```

Ask the user to verify these exact cases by running the app themselves:

1. Connected: current full waveform, no slash.
2. Starting: waveform draws left-to-right over the approved 1.4-second cycle.
3. Stopped and Error: full waveform with `/` slash.
4. Reduce Motion: Connecting shows a static 65% partial waveform.
5. Development menu bar: 1pt rounded-square frame remains visible in Light and Dark mode.
6. Development Dock/App Switcher: orange-to-pink gradient and bottom-right `D` badge are immediately distinguishable.
7. State transitions update the menu bar icon without opening the menu or triggering a separate refresh.

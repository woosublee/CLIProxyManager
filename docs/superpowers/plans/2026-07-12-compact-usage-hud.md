# Compact Usage HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 사용량 HUD에 저장 가능한 compact mode를 추가해, 하나의 `NSPanel`이 오른쪽 위 anchor를 유지하며 300pt expanded HUD와 108pt 세로형 HUD 사이를 전환하게 한다.

**Architecture:** `AppConfig.UsageOverlay`가 persisted display mode를 저장하고, `UsageOverlayPresentationState`가 현재 세션의 mode와 compact viewport 제약을 소유한다. SwiftUI는 expanded/compact 콘텐츠를 분리해 같은 shell에서 렌더링하며, `UsageOverlayWindowController`는 순수 frame layout helper를 사용해 하나의 panel을 resize·retarget하고 설정 저장 실패 시에도 session mode를 유지한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit `NSPanel`/`NSAnimationContext`, Combine, XCTest, Swift Package Manager, macOS 15+

## Global Constraints

- 최소 지원 버전은 `macOS 15.0`이다.
- compact HUD 기본 폭은 정확히 `108pt`, expanded HUD 폭은 기존 `300pt`를 유지한다.
- expanded minimum height는 기존 `260pt`, expanded maximum height는 `720pt`를 유지한다.
- 전환 duration은 `0.25초`, overshoot 없는 resize와 짧은 content cross-fade를 사용한다.
- 전환 전후 panel의 오른쪽 위 anchor(`maxX`, `maxY`)를 유지하고, 화면 경계를 벗어날 때만 보정한다.
- Reduce Motion이 켜지면 frame animation 없이 즉시 resize하고 정적 교체 또는 짧은 opacity 전환만 사용한다.
- compact HUD는 avatar, 한 줄 계정명, 기간 label, 정수 퍼센트와 작은 상태 indicator만 표시한다.
- compact HUD에서 제목, 갱신 시각, 수동 refresh, 명령어, progress bar와 reset 시각을 표시하지 않는다.
- 마지막 성공 usage cache와 background refresh 정책은 변경하지 않는다.
- 별도 compact `NSPanel`, 별도 위치 저장, 새 외부 dependency를 추가하지 않는다.
- 사용자-facing copy와 accessibility label은 현재 앱 UI와 일치하도록 영어를 사용한다.
- 앱 실행 검증은 release bundle이 아니라 개발 configuration 앱 번들을 기준으로 한다.

---

## File Structure

### Create

- `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
  - 현재 session display mode, compact account viewport 최대 높이, mode별 UI symbol/label을 소유한다.
- `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`
  - `AccountSubscriptionUsageState`를 compact row, placeholder와 indicator로 바꾸는 순수 presentation 계층이다.
- `Sources/CLIProxyManagerApp/Models/UsageOverlayFrameLayout.swift`
  - 오른쪽 위 anchor 유지, mode별 width/height clamp와 visible frame 보정을 담당하는 순수 geometry helper다.
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
  - 108pt compact 계정 목록과 상태 indicator를 렌더링한다.
- `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
  - compact 상태 변환과 접근성 문구를 검증한다.
- `Tests/CLIProxyManagerAppTests/UsageOverlayFrameLayoutTests.swift`
  - anchor, clamp와 screen 보정을 검증한다.
- `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`
  - mode별 symbol/label/opposite mode와 viewport 제약을 검증한다.

### Modify

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - `UsageOverlay.DisplayMode`와 backward-compatible persisted field를 추가한다.
- `Sources/CLIProxyManagerApp/Models/AppWindowMetrics.swift`
  - expanded/compact 폭, 최대 높이, screen margin을 명시한다.
- `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
  - 공통 chrome/shell과 expanded 콘텐츠를 구성하고 compact view를 전환한다.
- `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
  - presentation state, 저장 callback, screen-aware resize와 animation을 통합한다.
- `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift`
  - display mode default, decode fallback와 round trip을 검증한다.
- `Tests/CLIProxyManagerAppTests/AppWindowMetricsTests.swift`
  - 새 mode별 window metric을 검증한다.
- `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`
  - session mode, persistence failure, anchor-preserving resize, Reduce Motion와 hide/show를 검증한다.
- `README.md`, `README.en.md`
  - Usage HUD의 compact mode와 상태 유지 동작을 안내한다.

---

### Task 1: Persist the Usage Overlay Display Mode

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:311-331`
- Modify: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:5-73`

**Interfaces:**
- Produces: `AppConfig.UsageOverlay.DisplayMode` with `.expanded` and `.compact`
- Produces: `AppConfig.UsageOverlay.displayMode: DisplayMode`
- Consumes: existing `AppConfig.UsageOverlay` Codable initialization and opacity clamp

- [ ] **Step 1: Write failing default and round-trip tests**

Add these tests to `AppConfigTests`:

```swift
func testUsageOverlayDefaultsToExpandedDisplayMode() {
    XCTAssertEqual(AppConfig.UsageOverlay().displayMode, .expanded)
    XCTAssertEqual(AppConfig.default.usageOverlay.displayMode, .expanded)
}

func testUsageOverlayDisplayModeRoundTrips() throws {
    let overlay = AppConfig.UsageOverlay(
        isVisible: true,
        alwaysOnTop: true,
        backgroundOpacity: 0.45,
        displayMode: .compact
    )

    let data = try JSONEncoder().encode(overlay)
    let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

    XCTAssertEqual(decoded, overlay)
    XCTAssertEqual(decoded.displayMode, .compact)
}
```

Also add this assertion to `testDefaultConfigMatchesMVPDecisions()`:

```swift
XCTAssertEqual(config.usageOverlay.displayMode, .expanded)
```

- [ ] **Step 2: Write the backward-compatibility test**

Add:

```swift
func testUsageOverlayMissingDisplayModeDecodesAsExpanded() throws {
    let data = Data(#"{"isVisible":true,"alwaysOnTop":false,"backgroundOpacity":0.7}"#.utf8)

    let decoded = try JSONDecoder().decode(AppConfig.UsageOverlay.self, from: data)

    XCTAssertEqual(decoded.displayMode, .expanded)
    XCTAssertTrue(decoded.isVisible)
    XCTAssertEqual(decoded.backgroundOpacity, 0.7)
}
```

- [ ] **Step 3: Run the focused tests and confirm failure**

Run:

```bash
swift test --filter AppConfigTests/testUsageOverlay
```

Expected: compilation fails because `displayMode` and the four-argument initializer do not exist.

- [ ] **Step 4: Implement the persisted enum and field**

Replace the current `UsageOverlay` declaration with:

```swift
public struct UsageOverlay: Codable, Equatable, Sendable {
    public enum DisplayMode: String, Codable, Equatable, Sendable {
        case expanded
        case compact
    }

    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var backgroundOpacity: Double
    public var displayMode: DisplayMode

    public init(
        isVisible: Bool = false,
        alwaysOnTop: Bool = false,
        backgroundOpacity: Double = 0.9,
        displayMode: DisplayMode = .expanded
    ) {
        self.isVisible = isVisible
        self.alwaysOnTop = alwaysOnTop
        self.backgroundOpacity = min(max(backgroundOpacity, 0.2), 1)
        self.displayMode = displayMode
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible, alwaysOnTop, backgroundOpacity, displayMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        self.alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
        self.backgroundOpacity = min(
            max(try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.9, 0.2),
            1
        )
        self.displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .expanded
    }
}
```

- [ ] **Step 5: Run config tests**

Run:

```bash
swift test --filter AppConfigTests
```

Expected: all `AppConfigTests` pass, including existing opacity clamp tests.

- [ ] **Step 6: Commit the persisted mode**

```bash
git add Sources/CLIProxyManagerCore/Config/AppConfig.swift Tests/CLIProxyManagerCoreTests/AppConfigTests.swift
git commit -m "feat: persist usage HUD display mode

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Add Compact Usage Presentation Models

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`
- Create: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Reuse: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift`
- Reuse: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift`

**Interfaces:**
- Consumes: `AccountSubscriptionUsageState`, `SubscriptionUsageSnapshot`, `SubscriptionUsageIssue`
- Consumes: `subscriptionUsageDisplayLabel(for:)`
- Consumes: `SubscriptionUsageWarningPresentation.message(issue:lastUpdatedAt:now:)`
- Produces: `CompactUsagePresentation`
- Produces: `compactUsagePresentation(for:now:) -> CompactUsagePresentation`

- [ ] **Step 1: Write failing snapshot normalization tests**

Create `CompactUsagePresentationTests.swift`:

```swift
import CLIProxyManagerCore
import XCTest
@testable import CLIProxyManagerApp

final class CompactUsagePresentationTests: XCTestCase {
    func testAvailableSnapshotProducesClampedRoundedRows() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "codex.json",
            provider: .codex,
            windows: [
                UsageWindow(id: "primary", label: "Primary", usedPercent: -2, resetAt: nil),
                UsageWindow(id: "secondary", label: "Secondary", usedPercent: 15.6, resetAt: nil),
                UsageWindow(
                    id: "monthly",
                    label: "Monthly",
                    usedPercent: 104,
                    resetAt: nil,
                    limitWindowSeconds: 2_419_200
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertEqual(
            presentation.rows,
            [
                .init(label: "5h", value: "0%", accessibilityLabel: "5h, 0 percent used"),
                .init(label: "7d", value: "16%", accessibilityLabel: "7d, 16 percent used"),
                .init(label: "1mo", value: "100%", accessibilityLabel: "1mo, 100 percent used")
            ]
        )
        XCTAssertNil(presentation.placeholder)
        XCTAssertNil(presentation.indicator)
    }

    func testEmptySnapshotUsesUnavailablePlaceholder() {
        let snapshot = SubscriptionUsageSnapshot(
            profileID: "claude.json",
            provider: .claude,
            windows: [],
            fetchedAt: Date(timeIntervalSince1970: 60)
        )

        let presentation = compactUsagePresentation(for: .available(snapshot))

        XCTAssertEqual(presentation.rows, [])
        XCTAssertEqual(presentation.placeholder, "—")
        XCTAssertEqual(presentation.indicator, .unavailable(message: "Usage details unavailable."))
    }
}
```

- [ ] **Step 2: Write failing non-snapshot state tests**

Append:

```swift
func testLoadingDisabledAndUnavailableUseStablePlaceholder() {
    XCTAssertEqual(
        compactUsagePresentation(for: .loading),
        .placeholder("—", indicator: .loading(message: "Checking subscription usage…"))
    )
    XCTAssertEqual(
        compactUsagePresentation(for: .disabled),
        .placeholder("—", indicator: .disabled(message: "Subscription usage is disabled."))
    )
    XCTAssertEqual(
        compactUsagePresentation(for: .managementKeyNotConfigured),
        .placeholder("—", indicator: .disabled(message: "Subscription usage is not configured."))
    )
    XCTAssertEqual(
        compactUsagePresentation(for: .unavailable(.proxyUnavailable)),
        .placeholder("—", indicator: .unavailable(message: "Local proxy is unavailable."))
    )
}

func testStaleSnapshotKeepsRowsAndAddsDeterministicWarning() {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 15, resetAt: nil)],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let presentation = compactUsagePresentation(
        for: .stale(snapshot, .credentialExpired),
        now: Date(timeIntervalSince1970: 780)
    )

    XCTAssertEqual(presentation.rows.first?.value, "15%")
    XCTAssertEqual(
        presentation.indicator,
        .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
    )
}
```

- [ ] **Step 3: Run focused tests and confirm failure**

Run:

```bash
swift test --filter CompactUsagePresentationTests
```

Expected: compilation fails because `CompactUsagePresentation`, indicator cases and `compactUsagePresentation` do not exist.

- [ ] **Step 4: Implement the compact presentation layer**

Create `CompactUsagePresentation.swift`:

```swift
import CLIProxyManagerCore
import Foundation

struct CompactUsageRowPresentation: Equatable, Identifiable {
    let label: String
    let value: String
    let accessibilityLabel: String

    var id: String { label }
}

enum CompactUsageIndicator: Equatable {
    case loading(message: String)
    case disabled(message: String)
    case unavailable(message: String)
    case warning(message: String)

    var symbolName: String {
        switch self {
        case .loading:
            "clock.arrow.circlepath"
        case .disabled:
            "slash.circle"
        case .unavailable:
            "exclamationmark.circle"
        case .warning:
            "exclamationmark.triangle.fill"
        }
    }

    var message: String {
        switch self {
        case .loading(let message),
             .disabled(let message),
             .unavailable(let message),
             .warning(let message):
            message
        }
    }
}

struct CompactUsagePresentation: Equatable {
    let rows: [CompactUsageRowPresentation]
    let placeholder: String?
    let indicator: CompactUsageIndicator?

    static func placeholder(
        _ value: String,
        indicator: CompactUsageIndicator
    ) -> CompactUsagePresentation {
        CompactUsagePresentation(rows: [], placeholder: value, indicator: indicator)
    }
}

func compactUsagePresentation(
    for state: AccountSubscriptionUsageState,
    now: Date = .now
) -> CompactUsagePresentation {
    switch state {
    case .disabled:
        return .placeholder(
            "—",
            indicator: .disabled(message: "Subscription usage is disabled.")
        )
    case .managementKeyNotConfigured:
        return .placeholder(
            "—",
            indicator: .disabled(message: "Subscription usage is not configured.")
        )
    case .loading:
        return .placeholder(
            "—",
            indicator: .loading(message: "Checking subscription usage…")
        )
    case .available(let snapshot):
        return compactSnapshotPresentation(snapshot, warning: nil, now: now)
    case .stale(let snapshot, let issue):
        return compactSnapshotPresentation(snapshot, warning: issue, now: now)
    case .unavailable(let issue):
        return .placeholder(
            "—",
            indicator: .unavailable(message: issue.message)
        )
    }
}

private func compactSnapshotPresentation(
    _ snapshot: SubscriptionUsageSnapshot,
    warning: SubscriptionUsageIssue?,
    now: Date
) -> CompactUsagePresentation {
    guard !snapshot.windows.isEmpty else {
        return .placeholder(
            "—",
            indicator: .unavailable(message: "Usage details unavailable.")
        )
    }

    let rows = snapshot.windows.map { window in
        let percent = min(max(window.usedPercent, 0), 100)
        let rounded = Int(percent.rounded())
        let label = subscriptionUsageDisplayLabel(for: window)
        return CompactUsageRowPresentation(
            label: label,
            value: "\(rounded)%",
            accessibilityLabel: "\(label), \(rounded) percent used"
        )
    }
    let indicator = warning.map { issue in
        CompactUsageIndicator.warning(
            message: SubscriptionUsageWarningPresentation.message(
                issue: issue,
                lastUpdatedAt: snapshot.fetchedAt,
                now: now
            )
        )
    }
    return CompactUsagePresentation(rows: rows, placeholder: nil, indicator: indicator)
}
```

- [ ] **Step 5: Run compact presentation and existing warning tests**

Run:

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: both suites pass; stale snapshot behavior remains unchanged.

- [ ] **Step 6: Commit the presentation layer**

```bash
git add Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift
git commit -m "feat: model compact usage presentation

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Add Mode Metrics, Session State, and Frame Geometry

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayFrameLayout.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/AppWindowMetrics.swift`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayFrameLayoutTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/AppWindowMetricsTests.swift`

**Interfaces:**
- Consumes: `AppConfig.UsageOverlay.DisplayMode`
- Produces: `UsageOverlayPresentationState`
- Produces: `UsageOverlayFrameLayout.targetFrame(currentFrame:targetContentHeight:mode:visibleFrame:)`
- Produces: `AppWindowMetrics.usageOverlayExpandedWidth`, `.usageOverlayCompactWidth`, `.usageOverlayExpandedMinimumHeight`, `.usageOverlayMaximumHeight`, `.usageOverlayScreenMargin`

- [ ] **Step 1: Write failing metric and mode presentation tests**

Update `AppWindowMetricsTests` to assert:

```swift
XCTAssertEqual(AppWindowMetrics.usageOverlayExpandedWidth, 300)
XCTAssertEqual(AppWindowMetrics.usageOverlayCompactWidth, 108)
XCTAssertEqual(AppWindowMetrics.usageOverlayExpandedMinimumHeight, 260)
XCTAssertEqual(AppWindowMetrics.usageOverlayMaximumHeight, 720)
XCTAssertEqual(AppWindowMetrics.usageOverlayScreenMargin, 16)
XCTAssertEqual(AppWindowMetrics.usageOverlayWidth, 300)
XCTAssertEqual(AppWindowMetrics.usageOverlayHeight, 260)
```

The final Task 5 cleanup removes the two alias assertions together with the aliases.

Create `UsageOverlayPresentationStateTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

@MainActor
final class UsageOverlayPresentationStateTests: XCTestCase {
    func testModePresentationUsesAvailableMacOS15SymbolsAndLabels() {
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.toggleSymbolName, "arrow.down.right.and.arrow.up.left")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.toggleAccessibilityLabel, "Show compact usage window")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.expanded.opposite, .compact)

        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.toggleSymbolName, "arrow.up.left.and.arrow.down.right")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.toggleAccessibilityLabel, "Show expanded usage window")
        XCTAssertEqual(AppConfig.UsageOverlay.DisplayMode.compact.opposite, .expanded)
    }

    func testPresentationStatePublishesModeAndCompactViewportHeight() {
        let state = UsageOverlayPresentationState(displayMode: .expanded)

        state.displayMode = .compact
        state.compactAccountMaximumHeight = 420

        XCTAssertEqual(state.displayMode, .compact)
        XCTAssertEqual(state.compactAccountMaximumHeight, 420)
    }
}
```

- [ ] **Step 2: Write failing frame layout tests**

Create `UsageOverlayFrameLayoutTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp
@testable import CLIProxyManagerCore

final class UsageOverlayFrameLayoutTests: XCTestCase {
    func testCompactFrameKeepsRightTopAnchor() {
        let current = CGRect(x: 500, y: 400, width: 300, height: 260)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 360,
            mode: .compact,
            visibleFrame: screen
        )

        XCTAssertEqual(target.width, 108)
        XCTAssertEqual(target.height, 360)
        XCTAssertEqual(target.maxX, current.maxX)
        XCTAssertEqual(target.maxY, current.maxY)
    }

    func testExpandedFrameClampsToMinimumAndMaximumHeight() {
        let current = CGRect(x: 500, y: 100, width: 108, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let minimum = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 100,
            mode: .expanded,
            visibleFrame: screen
        )
        let maximum = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 1_200,
            mode: .expanded,
            visibleFrame: screen
        )

        XCTAssertEqual(minimum.height, 260)
        XCTAssertEqual(maximum.height, 720)
    }

    func testTargetFrameStaysInsideVisibleFrameMargin() {
        let current = CGRect(x: -40, y: 760, width: 300, height: 260)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let target = UsageOverlayFrameLayout.targetFrame(
            currentFrame: current,
            targetContentHeight: 700,
            mode: .compact,
            visibleFrame: screen
        )

        XCTAssertGreaterThanOrEqual(target.minX, screen.minX + 16)
        XCTAssertGreaterThanOrEqual(target.minY, screen.minY + 16)
        XCTAssertLessThanOrEqual(target.maxX, screen.maxX - 16)
        XCTAssertLessThanOrEqual(target.maxY, screen.maxY - 16)
    }
}
```

- [ ] **Step 3: Run focused tests and confirm failure**

Run:

```bash
swift test --filter AppWindowMetricsTests
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayFrameLayoutTests
```

Expected: compilation fails because the new constants, state and geometry helper do not exist.

- [ ] **Step 4: Implement mode metrics**

Replace the overlay metrics in `AppWindowMetrics` with:

```swift
static let usageOverlayExpandedWidth: CGFloat = 300
static let usageOverlayCompactWidth: CGFloat = 108
static let usageOverlayExpandedMinimumHeight: CGFloat = 260
static let usageOverlayMaximumHeight: CGFloat = 720
static let usageOverlayScreenMargin: CGFloat = 16

// Temporary compatibility aliases while the existing view/controller migrate in Tasks 4–5.
static let usageOverlayWidth = usageOverlayExpandedWidth
static let usageOverlayHeight = usageOverlayExpandedMinimumHeight
```

Keep the two compatibility aliases only through Tasks 3–4 so every intermediate commit builds. Task 5 removes them after all production call sites use the explicit mode-specific names.

- [ ] **Step 5: Implement presentation state and display mode UI metadata**

Create `UsageOverlayPresentationState.swift`:

```swift
import CLIProxyManagerCore
import Combine
import CoreGraphics

@MainActor
final class UsageOverlayPresentationState: ObservableObject {
    @Published var displayMode: AppConfig.UsageOverlay.DisplayMode
    @Published var compactAccountMaximumHeight: CGFloat

    init(
        displayMode: AppConfig.UsageOverlay.DisplayMode,
        compactAccountMaximumHeight: CGFloat = 640
    ) {
        self.displayMode = displayMode
        self.compactAccountMaximumHeight = compactAccountMaximumHeight
    }
}

extension AppConfig.UsageOverlay.DisplayMode {
    var opposite: Self {
        self == .expanded ? .compact : .expanded
    }

    var toggleSymbolName: String {
        switch self {
        case .expanded:
            "arrow.down.right.and.arrow.up.left"
        case .compact:
            "arrow.up.left.and.arrow.down.right"
        }
    }

    var toggleAccessibilityLabel: String {
        switch self {
        case .expanded:
            "Show compact usage window"
        case .compact:
            "Show expanded usage window"
        }
    }
}
```

- [ ] **Step 6: Implement pure frame geometry**

Create `UsageOverlayFrameLayout.swift`:

```swift
import CLIProxyManagerCore
import CoreGraphics

struct UsageOverlayFrameLayout {
    static func targetFrame(
        currentFrame: CGRect,
        targetContentHeight: CGFloat,
        mode: AppConfig.UsageOverlay.DisplayMode,
        visibleFrame: CGRect
    ) -> CGRect {
        let margin = AppWindowMetrics.usageOverlayScreenMargin
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        let maximumHeight = min(AppWindowMetrics.usageOverlayMaximumHeight, availableHeight)
        let minimumHeight = mode == .expanded
            ? min(AppWindowMetrics.usageOverlayExpandedMinimumHeight, maximumHeight)
            : min(72, maximumHeight)
        let width = mode == .expanded
            ? AppWindowMetrics.usageOverlayExpandedWidth
            : AppWindowMetrics.usageOverlayCompactWidth
        let height = min(max(targetContentHeight, minimumHeight), maximumHeight)

        var frame = CGRect(
            x: currentFrame.maxX - width,
            y: currentFrame.maxY - height,
            width: width,
            height: height
        )
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)

        if frame.minX < safeFrame.minX { frame.origin.x = safeFrame.minX }
        if frame.maxX > safeFrame.maxX { frame.origin.x = safeFrame.maxX - frame.width }
        if frame.minY < safeFrame.minY { frame.origin.y = safeFrame.minY }
        if frame.maxY > safeFrame.maxY { frame.origin.y = safeFrame.maxY - frame.height }

        return frame
    }
}
```

- [ ] **Step 7: Run geometry and metric tests**

Run:

```bash
swift test --filter AppWindowMetricsTests
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayFrameLayoutTests
```

Expected: all three suites pass.

- [ ] **Step 8: Commit geometry and state**

```bash
git add Sources/CLIProxyManagerApp/Models/AppWindowMetrics.swift Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift Sources/CLIProxyManagerApp/Models/UsageOverlayFrameLayout.swift Tests/CLIProxyManagerAppTests/AppWindowMetricsTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayFrameLayoutTests.swift
git commit -m "feat: define compact HUD window geometry

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Build the Shared Chrome and Compact SwiftUI Content

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:4-199`
- Test: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`

SwiftPM App tests do not use a SwiftUI hierarchy inspection dependency. Keep deterministic copy, symbol and accessibility text in the pure presentation/state types tested here; compile the actual view and verify visual hierarchy in Task 7.

**Interfaces:**
- Consumes: `UsageOverlayPresentationState`
- Consumes: `CompactUsagePresentation` and `compactUsagePresentation(for:now:)`
- Consumes: `MenuBarConnectedProvider`
- Produces: `UsageOverlayView(viewModel:presentationState:onToggleDisplayMode:onClose:)`
- Produces: `CompactUsageOverlayView(providers:maximumAccountHeight:)`

- [ ] **Step 1: Add failing indicator metadata tests**

Append to `CompactUsagePresentationTests`:

```swift
func testIndicatorsExposeStableSymbolsAndMessages() {
    let warning = CompactUsageIndicator.warning(message: "Needs attention")
    let loading = CompactUsageIndicator.loading(message: "Loading")

    XCTAssertEqual(warning.symbolName, "exclamationmark.triangle.fill")
    XCTAssertEqual(warning.message, "Needs attention")
    XCTAssertEqual(loading.symbolName, "clock.arrow.circlepath")
    XCTAssertEqual(loading.message, "Loading")
}
```

Run:

```bash
swift test --filter CompactUsagePresentationTests/testIndicatorsExposeStableSymbolsAndMessages
```

Expected: PASS if Task 2 implemented the agreed metadata; keep this test as the view contract.

- [ ] **Step 2: Create the compact account list**

Create `CompactUsageOverlayView.swift` with these components:

```swift
import CLIProxyManagerCore
import SwiftUI

struct CompactUsageOverlayView: View {
    let providers: [MenuBarConnectedProvider]
    let maximumAccountHeight: CGFloat
    @State private var naturalAccountHeight: CGFloat = 1

    var body: some View {
        Group {
            if providers.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 20))
                    Text("No accounts")
                        .font(.system(size: 9.5, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityElement(children: .combine)
            } else {
                ZStack(alignment: .top) {
                    accountStack
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: CompactAccountHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                        .frame(height: 0)
                        .clipped()

                    ScrollView(.vertical, showsIndicators: needsScrolling) {
                        accountStack
                    }
                    .scrollDisabled(!needsScrolling)
                    .frame(height: viewportHeight)
                }
                .onPreferenceChange(CompactAccountHeightPreferenceKey.self) {
                    naturalAccountHeight = max(1, $0)
                }
            }
        }
    }

    private var viewportHeight: CGFloat {
        min(naturalAccountHeight, maximumAccountHeight)
    }

    private var needsScrolling: Bool {
        naturalAccountHeight > maximumAccountHeight
    }

    private var accountStack: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                if index > 0 {
                    CompactUsageSeparator()
                }
                CompactUsageAccountView(provider: provider)
            }
        }
    }
}

private struct CompactUsageAccountView: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        let presentation = compactUsagePresentation(for: provider.subscriptionUsageState)
        VStack(spacing: 7) {
            VStack(spacing: 4) {
                ProviderAvatar(providerID: provider.id, size: 26)
                Text(provider.usageOverlayDisplayName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(provider.usageOverlayDisplayName)
                    .accessibilityLabel(provider.usageOverlayDisplayName)
            }

            if presentation.rows.isEmpty {
                CompactUsagePlaceholderRow(presentation: presentation)
            } else {
                VStack(spacing: 5) {
                    ForEach(presentation.rows) { row in
                        HStack(spacing: 4) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(row.value)
                                .foregroundStyle(.primary)
                        }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let indicator = presentation.indicator {
                    CompactUsageIndicatorView(indicator: indicator)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

private struct CompactUsagePlaceholderRow: View {
    let presentation: CompactUsagePresentation

    var body: some View {
        HStack(spacing: 5) {
            Text(presentation.placeholder ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if let indicator = presentation.indicator {
                CompactUsageIndicatorView(indicator: indicator)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CompactUsageIndicatorView: View {
    let indicator: CompactUsageIndicator

    var body: some View {
        Image(systemName: indicator.symbolName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(indicatorColor)
            .help(indicator.message)
            .accessibilityLabel(indicator.message)
    }

    private var indicatorColor: Color {
        switch indicator {
        case .warning:
            BrandPalette.statusWarning
        case .loading, .disabled, .unavailable:
            .secondary
        }
    }
}

private struct CompactUsageSeparator: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .primary.opacity(0.12), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

private struct CompactAccountHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
```

- [ ] **Step 3: Refactor `UsageOverlayView` into shared shell and mode content**

Change its public properties to:

```swift
@ObservedObject var viewModel: DashboardViewModel
@ObservedObject var presentationState: UsageOverlayPresentationState
var onToggleDisplayMode: () -> Void = {}
var onClose: () -> Void = {}
```

Build the body with a shared chrome and selected content:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: presentationState.displayMode == .expanded ? 12 : 4) {
        UsageOverlayChrome(
            displayMode: presentationState.displayMode,
            onToggleDisplayMode: onToggleDisplayMode,
            onClose: onClose
        )

        switch presentationState.displayMode {
        case .expanded:
            ExpandedUsageOverlayContent(
                viewModel: viewModel,
                providers: providers,
                refreshStatus: refreshStatus
            )
            .transition(.opacity)
        case .compact:
            CompactUsageOverlayView(
                providers: providers,
                maximumAccountHeight: presentationState.compactAccountMaximumHeight
            )
            .transition(.opacity)
        }
    }
    .padding(presentationState.displayMode == .expanded ? 16 : 10)
    .frame(width: overlayWidth, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .animation(.easeOut(duration: 0.12), value: presentationState.displayMode)
    .background(.regularMaterial.opacity(viewModel.config.usageOverlay.backgroundOpacity))
    .clipShape(RoundedRectangle(cornerRadius: presentationState.displayMode == .expanded ? 14 : 18, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: presentationState.displayMode == .expanded ? 14 : 18, style: .continuous))
    .gesture(WindowDragGesture())
    .allowsWindowActivationEvents(true)
    .task { await viewModel.refresh() }
    .task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            refreshStatusReferenceDate = Date()
        }
    }
}

private var overlayWidth: CGFloat {
    presentationState.displayMode == .expanded
        ? AppWindowMetrics.usageOverlayExpandedWidth
        : AppWindowMetrics.usageOverlayCompactWidth
}
```

Move the existing title, refresh button, empty state, account rows and progress rows into a private `ExpandedUsageOverlayContent` without changing their copy or behavior.

- [ ] **Step 4: Add the shared chrome**

Add this private view in `UsageOverlayView.swift`:

```swift
private struct UsageOverlayChrome: View {
    let displayMode: AppConfig.UsageOverlay.DisplayMode
    let onToggleDisplayMode: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Spacer()
            chromeButton(
                symbol: displayMode.toggleSymbolName,
                accessibilityLabel: displayMode.toggleAccessibilityLabel,
                action: onToggleDisplayMode
            )
            chromeButton(
                symbol: "xmark",
                accessibilityLabel: "Hide usage window",
                action: onClose
            )
        }
        .frame(height: 24)
    }

    private func chromeButton(
        symbol: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
```

Remove the old close-only `HStack` from the expanded header. Add these exact private expanded-content structs so the current 300pt behavior is preserved without duplicating chrome:

```swift
private struct ExpandedUsageOverlayContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let providers: [MenuBarConnectedProvider]
    let refreshStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscription Usage")
                        .font(.system(size: 15, weight: .semibold))
                    Text(refreshStatus)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await viewModel.refreshSubscriptionUsage(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRefreshSubscriptionUsage || viewModel.isSubscriptionUsageRefreshInProgress)
                .opacity(viewModel.canRefreshSubscriptionUsage ? 1 : 0.45)
                .accessibilityLabel("Reload subscription usage")
            }

            if providers.isEmpty {
                Text("No connected accounts")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(providers) { provider in
                        ExpandedUsageOverlayAccountView(provider: provider)
                    }
                }
            }
        }
    }
}

private struct ExpandedUsageOverlayAccountView: View {
    let provider: MenuBarConnectedProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ProviderAvatar(providerID: provider.id, size: 20)
                Text(provider.usageOverlayDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(verbatim: "$ \(provider.functionName)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            usageContent
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        if case .unavailable(.proxyUnavailable) = provider.subscriptionUsageState {
            Text("Start the server to check usage")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            switch subscriptionUsageDisplayState(for: provider.subscriptionUsageState) {
            case .hidden:
                Text("Subscription usage is disabled")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case .loading(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case .unavailable(let message):
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .snapshot(let snapshot, let warning):
                HStack(alignment: .top, spacing: 6) {
                    snapshotUsage(snapshot)
                    if let warning {
                        SubscriptionUsageWarningIcon(
                            issue: warning,
                            lastUpdatedAt: snapshot.fetchedAt
                        )
                        .padding(.top, 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func snapshotUsage(_ snapshot: SubscriptionUsageSnapshot) -> some View {
        if snapshot.windows.isEmpty {
            Text("Usage details unavailable")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.windows) { window in
                    ExpandedUsageOverlayProgressRow(window: window)
                }
            }
        }
    }
}

private struct ExpandedUsageOverlayProgressRow: View {
    let window: UsageWindow

    var body: some View {
        let percent = min(max(window.usedPercent, 0), 100)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(subscriptionUsageDisplayLabel(for: window))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                ProgressView(value: percent, total: 100)
                    .tint(subscriptionUsageProgressTone(for: percent).color)
                    .accessibilityLabel(subscriptionUsageAccessibilityLabel(for: window))
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }
            if let resetAt = window.resetAt {
                Text("Next reset: \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 36)
            }
        }
    }
}
```

Delete the old `UsageOverlayAccountView` and `UsageOverlayProgressRow` after moving their behavior into these renamed expanded-only structs.

- [ ] **Step 5: Compile and run focused presentation tests**

Run:

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter UsageOverlayPresentationStateTests
swift build -c debug --product CLIProxyManager
```

Expected: tests pass and the app target compiles with both SwiftUI modes.

- [ ] **Step 6: Commit the SwiftUI modes**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift
git commit -m "feat: add compact usage HUD content

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Integrate Session Mode, Persistence, and Animated Panel Resizing

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift:7-129`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift:7-110`

**Interfaces:**
- Consumes: `UsageOverlayPresentationState`
- Consumes: `UsageOverlayFrameLayout.targetFrame(...)`
- Consumes: `DashboardViewModel.saveSetting(_:)` and `saveUsageOverlay(_:)`
- Produces: `UsageOverlayWindowController.displayMode`
- Produces: `toggleDisplayMode()`
- Produces: `updateContentSize(_:animated:)`

- [ ] **Step 1: Add failing controller initialization and hide/show tests**

Update test panel helpers to use mode-specific metrics, then add:

```swift
func testControllerStartsWithConfiguredDisplayMode() {
    let panel = NSPanel(
        contentRect: NSRect(x: 400, y: 400, width: 108, height: 240),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .compact
    )

    XCTAssertEqual(controller.displayMode, .compact)
}

func testHideAndShowKeepSessionDisplayMode() {
    let panel = NSPanel(
        contentRect: NSRect(x: 400, y: 400, width: 108, height: 240),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .compact
    )
    let preferences = AppConfig.UsageOverlay(isVisible: true, displayMode: .compact)

    controller.showForCurrentSession(using: preferences)
    controller.hideForCurrentSession()
    controller.showForCurrentSession(using: preferences)

    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(controller.displayMode, .compact)
}
```

- [ ] **Step 2: Add failing resize and Reduce Motion tests**

Add:

```swift
func testCompactResizeKeepsRightTopAnchor() {
    let panel = NSPanel(
        contentRect: NSRect(x: 500, y: 400, width: 300, height: 260),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    let original = panel.frame
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .compact,
        shouldReduceMotion: { true },
        visibleFrameProvider: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    )

    controller.updateContentSize(CGSize(width: 108, height: 360), animated: true)

    XCTAssertEqual(panel.frame.width, 108)
    XCTAssertEqual(panel.frame.height, 360)
    XCTAssertEqual(panel.frame.maxX, original.maxX)
    XCTAssertEqual(panel.frame.maxY, original.maxY)
}

func testReduceMotionUsesImmediateFrameUpdate() {
    let panel = NSPanel(
        contentRect: NSRect(x: 500, y: 400, width: 300, height: 260),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .compact,
        shouldReduceMotion: { true },
        visibleFrameProvider: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    )

    controller.updateContentSize(CGSize(width: 108, height: 320), animated: true)

    XCTAssertEqual(panel.frame.size, CGSize(width: 108, height: 320))
}
```

- [ ] **Step 3: Add failing persistence failure test**

Add a persistence callback seam to the test and assert session override behavior:

```swift
func testFailedModePersistenceKeepsSessionMode() {
    let panel = NSPanel(
        contentRect: NSRect(x: 500, y: 400, width: 300, height: 260),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    var attemptedModes: [AppConfig.UsageOverlay.DisplayMode] = []
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .expanded,
        persistDisplayMode: {
            attemptedModes.append($0)
            return false
        },
        shouldReduceMotion: { true },
        visibleFrameProvider: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    )

    controller.toggleDisplayMode()
    controller.update(.init(isVisible: true, displayMode: .expanded))

    XCTAssertEqual(attemptedModes, [.compact])
    XCTAssertEqual(controller.displayMode, .compact)
}
```

- [ ] **Step 4: Run controller tests and confirm failure**

Run:

```bash
swift test --filter UsageOverlayWindowControllerTests
```

Expected: compilation fails because the new initializer seams, `displayMode`, `toggleDisplayMode()` and animated sizing API do not exist.

- [ ] **Step 5: Add controller state and test seams**

Add these stored properties and initializer parameters:

```swift
private let panel: NSPanel
private let presentationState: UsageOverlayPresentationState
private let persistDisplayMode: (AppConfig.UsageOverlay.DisplayMode) -> Bool
private let shouldReduceMotion: () -> Bool
private let visibleFrameProvider: () -> CGRect?
private var failedPersistenceOverride: AppConfig.UsageOverlay.DisplayMode?
private var isApplyingLocalModePersistence = false

@Published private(set) var isVisible = false
var displayMode: AppConfig.UsageOverlay.DisplayMode { presentationState.displayMode }
var window: NSWindow { panel }

init(
    panel: NSPanel? = nil,
    viewModel: DashboardViewModel? = nil,
    initialDisplayMode: AppConfig.UsageOverlay.DisplayMode? = nil,
    persistDisplayMode: ((AppConfig.UsageOverlay.DisplayMode) -> Bool)? = nil,
    shouldReduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    },
    visibleFrameProvider: (() -> CGRect?)? = nil
) {
    let mode = initialDisplayMode ?? viewModel?.config.usageOverlay.displayMode ?? .expanded
    self.presentationState = UsageOverlayPresentationState(displayMode: mode)
    self.shouldReduceMotion = shouldReduceMotion
    self.visibleFrameProvider = visibleFrameProvider ?? { nil }
    self.persistDisplayMode = persistDisplayMode ?? { [weak viewModel] mode in
        guard let viewModel else { return true }
        var usageOverlay = viewModel.config.usageOverlay
        usageOverlay.displayMode = mode
        return viewModel.saveSetting {
            try viewModel.saveUsageOverlay(usageOverlay)
        }
    }
    self.panel = panel ?? NSPanel(
        contentRect: NSRect(
            x: 0,
            y: 0,
            width: mode == .expanded
                ? AppWindowMetrics.usageOverlayExpandedWidth
                : AppWindowMetrics.usageOverlayCompactWidth,
            height: AppWindowMetrics.usageOverlayExpandedMinimumHeight
        ),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    super.init()
    configurePanelAndContent(viewModel: viewModel)
}
```

Implement `configurePanelAndContent(viewModel:)` with the existing panel setup and explicit mode-aware observation:

```swift
private func configurePanelAndContent(viewModel: DashboardViewModel?) {
    panel.delegate = self
    panel.title = "Usage"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.setFrameAutosaveName("usage-overlay")
    updatePanelConstraints(for: displayMode)

    guard let viewModel else { return }
    panel.contentView = NSHostingView(
        rootView: UsageOverlayView(
            viewModel: viewModel,
            presentationState: presentationState,
            onToggleDisplayMode: { [weak self] in self?.toggleDisplayMode() },
            onClose: { [weak self] in self?.hideForCurrentSession() }
        )
    )
    configObservation = viewModel.$config
        .map(\.usageOverlay)
        .removeDuplicates()
        .sink { [weak self] preferences in
            DispatchQueue.main.async {
                self?.update(preferences)
            }
        }
    contentObservation = viewModel.objectWillChange
        .sink { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible else { return }
                self.resizeToFittingContent(animated: false)
            }
        }
}
```

Retain the existing `restoreSavedFrameIfUsable`, visibility methods and `windowShouldClose`, but make every fitting-size update call the new mode-aware resize helper.

- [ ] **Step 6: Implement mode toggling and failed-save override**

Add:

```swift
func toggleDisplayMode() {
    let target = displayMode.opposite
    failedPersistenceOverride = target
    presentationState.displayMode = target
    updatePanelConstraints(for: target)

    isApplyingLocalModePersistence = true
    let didPersist = persistDisplayMode(target)
    isApplyingLocalModePersistence = false
    if didPersist {
        failedPersistenceOverride = nil
    }

    resizeToFittingContent(animated: true)
}
```

In `update(_ preferences:)`, synchronize persisted mode only when there is no failed override:

```swift
if !isApplyingLocalModePersistence {
    if preferences.displayMode == failedPersistenceOverride {
        failedPersistenceOverride = nil
    }
    if failedPersistenceOverride == nil, presentationState.displayMode != preferences.displayMode {
        presentationState.displayMode = preferences.displayMode
        updatePanelConstraints(for: preferences.displayMode)
    }
}
```

The `isApplyingLocalModePersistence` guard prevents synchronous `viewModel.$config` emissions during `saveUsageOverlay` from clearing the override before the persistence result is known. A matching later external config emission clears the override. Do not change `presentationState.displayMode` in `hideForCurrentSession()` or `showForCurrentSession(using:)`.

- [ ] **Step 7: Implement mode-aware screen constraints**

Add:

```swift
private func updatePanelConstraints(for mode: AppConfig.UsageOverlay.DisplayMode) {
    let width = mode == .expanded
        ? AppWindowMetrics.usageOverlayExpandedWidth
        : AppWindowMetrics.usageOverlayCompactWidth
    let visibleHeight = currentVisibleFrame()?.height ?? AppWindowMetrics.usageOverlayMaximumHeight
    let maximumHeight = min(
        AppWindowMetrics.usageOverlayMaximumHeight,
        max(72, visibleHeight - AppWindowMetrics.usageOverlayScreenMargin * 2)
    )

    panel.contentMinSize = CGSize(
        width: width,
        height: mode == .expanded ? AppWindowMetrics.usageOverlayExpandedMinimumHeight : 72
    )
    panel.contentMaxSize = CGSize(width: width, height: maximumHeight)
    presentationState.compactAccountMaximumHeight = max(72, maximumHeight - 52)
}

private func currentVisibleFrame() -> CGRect? {
    visibleFrameProvider()
        ?? panel.screen?.visibleFrame
        ?? NSScreen.main?.visibleFrame
}
```

- [ ] **Step 8: Implement anchor-preserving animated resize**

Replace `updateContentSize(_:)` with:

```swift
func updateContentSize(_ size: CGSize, animated: Bool = false) {
    guard let visibleFrame = currentVisibleFrame() else {
        panel.setContentSize(size)
        return
    }
    let target = UsageOverlayFrameLayout.targetFrame(
        currentFrame: panel.frame,
        targetContentHeight: size.height,
        mode: displayMode,
        visibleFrame: visibleFrame
    )
    let shouldAnimate = animated && !shouldReduceMotion()

    guard shouldAnimate else {
        panel.setFrame(target, display: true)
        return
    }

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        context.allowsImplicitAnimation = true
        panel.animator().setFrame(target, display: true)
    }
}

private func resizeToFittingContent(animated: Bool) {
    DispatchQueue.main.async { [weak self] in
        guard let self, let contentView = self.panel.contentView else { return }
        self.updateContentSize(contentView.fittingSize, animated: animated)
    }
}
```

Import `QuartzCore` for `CAMediaTimingFunction`. Replace existing duplicated async fitting-size blocks with `resizeToFittingContent(animated: false)`.

After migrating every source reference, remove the temporary aliases from `AppWindowMetrics.swift`:

```swift
static let usageOverlayWidth = usageOverlayExpandedWidth
static let usageOverlayHeight = usageOverlayExpandedMinimumHeight
```

At the same time delete these temporary assertions from `AppWindowMetricsTests.swift`:

```swift
XCTAssertEqual(AppWindowMetrics.usageOverlayWidth, 300)
XCTAssertEqual(AppWindowMetrics.usageOverlayHeight, 260)
```

Confirm no source or test call site uses the aliases:

```bash
rg -n 'usageOverlayWidth|usageOverlayHeight' Sources Tests
```

Expected: no matches.

- [ ] **Step 9: Preserve current-frame retargeting**

Keep every resize calculation based on `panel.frame` at call time. Do not cache the prior target frame. Add this test:

```swift
func testSecondResizeRetargetsFromCurrentFrame() {
    let panel = NSPanel(
        contentRect: NSRect(x: 500, y: 400, width: 300, height: 260),
        styleMask: [.borderless, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    let controller = UsageOverlayWindowController(
        panel: panel,
        initialDisplayMode: .compact,
        shouldReduceMotion: { true },
        visibleFrameProvider: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    )

    controller.updateContentSize(CGSize(width: 108, height: 360), animated: true)
    let firstAnchor = CGPoint(x: panel.frame.maxX, y: panel.frame.maxY)
    controller.updateContentSize(CGSize(width: 108, height: 420), animated: true)

    XCTAssertEqual(panel.frame.maxX, firstAnchor.x)
    XCTAssertEqual(panel.frame.maxY, firstAnchor.y)
    XCTAssertEqual(panel.frame.height, 420)
}
```

- [ ] **Step 10: Run controller and integration tests**

Run:

```bash
swift test --filter UsageOverlayWindowControllerTests
swift test --filter AppAppearanceServiceTests
swift build -c debug --product CLIProxyManager
```

Expected: all tests pass; the app target compiles with the production persistence closure.

- [ ] **Step 11: Commit controller integration**

```bash
git add Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift
git commit -m "feat: animate compact HUD window transitions

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Document the Feature and Run Full Automated Verification

**Files:**
- Modify: `README.md:57-65`
- Modify: `README.en.md` corresponding Usage HUD section
- Verify: all changed source and test files

**Interfaces:**
- Consumes: completed compact HUD behavior
- Produces: user-facing documentation and a green full test/build baseline

- [ ] **Step 1: Update Korean README copy**

Add these bullets under `## 사용량 HUD`:

```markdown
- HUD 우측 상단의 축소·확장 버튼으로 300pt 전체 보기와 108pt compact 보기를 전환할 수 있습니다.
- compact 보기는 계정 avatar·이름과 기간별 사용률만 세로로 표시하며, 선택한 보기 상태는 앱 재실행 후에도 유지됩니다.
```

Keep the existing opacity, always-on-top, provider usage and period-label bullets.

- [ ] **Step 2: Update English README copy**

Add the equivalent bullets under the English Usage HUD section:

```markdown
- Use the compact/expand control in the HUD header to switch between the 300pt full view and the 108pt compact view.
- Compact view keeps only the account avatar, name, and period usage percentages in a vertical layout, and the selected view is restored after relaunch.
```

- [ ] **Step 3: Run focused suites**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter CompactUsagePresentationTests
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayFrameLayoutTests
swift test --filter UsageOverlayWindowControllerTests
swift test --filter AppAppearanceServiceTests
swift test --filter SubscriptionUsageWarningIconTests
```

Expected: every command exits 0 with no failed tests.

- [ ] **Step 4: Run the complete test suite**

Run:

```bash
swift test
```

Expected: all Core and App test targets pass.

- [ ] **Step 5: Build the development app bundle**

Run:

```bash
make bundle CONFIGURATION=debug BUILD_DIR=build/debug
```

Expected:

```text
Bundled build/debug/CLIProxyManager.app
```

Confirm the executable exists:

```bash
test -x build/debug/CLIProxyManager.app/Contents/MacOS/CLIProxyManager
```

Expected: exit 0.

- [ ] **Step 6: Inspect the final diff**

Run:

```bash
git diff --check
git status --short
BASE=$(git merge-base HEAD main)
git diff --stat "$BASE"..HEAD
```

Expected: no whitespace errors, only the compact HUD implementation, tests and README changes are present. Because the design commit predates implementation, if the exact commit count differs, use `git merge-base HEAD main` and inspect `git diff --stat $(git merge-base HEAD main)..HEAD` instead of relying on `HEAD~5`.

- [ ] **Step 7: Commit documentation**

```bash
git add README.md README.en.md
git commit -m "docs: describe compact usage HUD

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Verify the Built App Interactively

**Files:**
- No source changes expected
- Runtime target: `build/debug/CLIProxyManager.app`
- Reference: `docs/superpowers/specs/2026-07-12-compact-usage-hud-design.md`

**Interfaces:**
- Consumes: built development app bundle and real `DashboardViewModel` state
- Produces: runtime evidence that the compact HUD meets the approved visual and interaction design

- [ ] **Step 1: Launch the development app**

Run:

```bash
pkill -x CLIProxyManager 2>/dev/null || true
open build/debug/CLIProxyManager.app
```

Expected: the development build launches and the menu bar item appears.

- [ ] **Step 2: Verify expanded-to-compact transition**

In the app:

1. Enable **General → Usage Overlay → Show usage window** if needed.
2. Position the expanded HUD so its right edge is easy to compare against a nearby screen landmark.
3. Confirm the inward-arrow button is immediately left of X.
4. Click it once.
5. Confirm the HUD becomes approximately 108pt wide, the right and top edges stay fixed, and the left/bottom edges move inward.
6. Click the outward-arrow button and confirm the same path reverses without a jump.

Expected: one panel remains visible throughout; no second window flash or anchor drift occurs.

- [ ] **Step 3: Verify compact information hierarchy**

With multiple connected Claude/Codex accounts:

1. Confirm every account shows a 26pt provider avatar and one-line account name.
2. Confirm same-provider accounts such as `personal` and `work` remain distinguishable.
3. Confirm usage rows show only labels such as `5h`, `7d`, `1mo` and integer percentages.
4. Confirm title, refresh status, refresh button, command name, progress bars and reset times are absent.
5. Confirm changing percentage digit counts does not shift the numeric column.
6. Confirm long names truncate visually and reveal the full value on hover/VoiceOver.

Expected: the compact window remains calm and readable at 108pt.

- [ ] **Step 4: Verify unavailable and stale states**

Exercise or simulate these states through normal app/server controls:

1. Stop the proxy and confirm unavailable accounts remain present with `—` and a status icon.
2. Hover the icon and confirm the specific reason appears.
3. Restart the proxy and confirm values recover without reopening the HUD.
4. Confirm a stale cached snapshot keeps its percentages and adds a warning indicator rather than replacing values.
5. Disable subscription usage and confirm `—` plus the disabled indicator is shown.

Expected: account identity and layout do not disappear or reflow unexpectedly.

- [ ] **Step 5: Verify scroll and screen constraints**

Using enough accounts to exceed available height, or a reduced-resolution display:

1. Confirm the top chrome remains fixed.
2. Confirm only the account area scrolls.
3. Confirm no scroll indicator/bounce appears when all accounts fit.
4. Drag the panel to another display and toggle modes.
5. Change display arrangement or resolution and show the HUD again.

Expected: the panel remains within the active screen visible frame with approximately 16pt safety margin.

- [ ] **Step 6: Verify persistence and existing behaviors**

1. Leave the HUD in compact mode and quit/relaunch the development app.
2. Confirm it returns in compact mode.
3. Click X, then use the menu bar item to show the HUD again.
4. Confirm compact mode remains selected.
5. Verify background opacity, Always on top, window dragging and background refresh work in both modes.

Expected: X remains session-only visibility control and does not reset saved mode.

- [ ] **Step 7: Verify accessibility appearance settings**

In **System Settings → Accessibility → Display**:

1. Test light and dark system appearance.
2. Enable Increase Contrast and confirm text/icons remain legible.
3. Enable Reduce Transparency and confirm the material becomes sufficiently solid through system behavior.
4. Enable Reduce Motion and toggle expanded/compact.

Expected: Reduce Motion removes the 0.25-second panel resize animation; controls retain clear labels and 24×24pt hit targets.

- [ ] **Step 8: Record verification result**

Run after closing the app:

```bash
git status --short --branch
```

Expected: clean worktree. If runtime verification reveals a defect, do not mark this task complete; add a focused failing test, implement the smallest fix, rerun Tasks 6–7, and commit the fix separately.

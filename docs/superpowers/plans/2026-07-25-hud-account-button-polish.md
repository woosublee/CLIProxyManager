# Usage HUD Account Button Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 계정 카드의 Usage HUD 버튼을 조용한 `macwindow` 표현으로 다듬고, Expanded HUD에 계정을 다시 표시할 때 새 행만 짧게 fade-in한다.

**Architecture:** 기존 `UsageOverlayAccountButtonPresentation`과 카드 action 구조를 유지하면서 symbol·foreground presentation만 교체한다. Expanded account stack에만 asymmetric opacity transition과 Reduce Motion-aware animation을 적용하여 저장, filtering, panel resize, Compact 동작을 변경하지 않는다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- 새 외부 dependency를 추가하지 않는다.
- 버튼 symbol은 정확히 `macwindow`를 사용한다.
- 26×26 click target과 `Hide from Usage HUD` / `Show in Usage HUD` copy를 유지한다.
- 버튼의 선택 background를 제거한다.
- HUD 표시 중에는 `BrandPalette.accent`, 숨김 상태에는 낮은 primary/secondary 계열 opacity를 사용한다.
- Connected, Disabled, Disconnected action 순서를 유지한다.
- Expanded에서 추가되는 계정 행만 `0.12`초 `easeOut` opacity insertion을 사용한다.
- removal은 identity로 즉시 처리한다.
- 기존 계정과 header에 crossfade, blur, scale, move animation을 추가하지 않는다.
- Compact mode에는 insertion animation을 추가하지 않는다.
- `accessibilityReduceMotion == true`이면 Expanded insertion animation은 `nil`이다.
- 저장, rollback, HUD filtering, menu bar, usage polling/cache, panel resize 정책을 변경하지 않는다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, `CONFIGURATION=debug` development app bundle build와 codesign verification까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift` — HUD 버튼의 symbol과 상태별 semantic presentation을 제공한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift` — 선택 background 없이 active/inactive foreground를 렌더링한다.
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — Expanded account stack에만 insertion-only opacity animation을 적용한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift` — `macwindow`와 기존 action copy/highlight 상태를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift` — 버튼 click target, accessibility, background 제거, 상태 색상 계약을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/ExpandedUsageOverlayAnimationTests.swift` — Expanded insertion, removal identity, Reduce Motion, Compact 비변경 계약을 검증한다.
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md` — 구현 및 자동 검증 완료 상태를 기록한다.

---

### Task 1: 계정 카드 HUD 버튼 시각 표현 개선

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift:3-14`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:770-791`
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift:185-211`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift:37-47`

**Interfaces:**
- Consumes: `UsageOverlayAccountButtonPresentation`, `DashboardAccountSnapshot.showsInUsageOverlay`, 카드의 `hovering` 상태
- Produces: `macwindow` symbol, background 없는 active/inactive button presentation, 기존 accessibility/action contract

- [ ] **Step 1: 버튼 symbol 실패 테스트 갱신**

`DashboardAccountSnapshotTests`의 두 기존 assertion을 다음처럼 변경한다.

```swift
XCTAssertEqual(snapshot.usageOverlayButtonPresentation.symbolName, "macwindow")
```

```swift
XCTAssertEqual(presentation.symbolName, "macwindow")
```

기존 label 및 highlight assertion은 유지한다.

```swift
XCTAssertEqual(snapshot.usageOverlayButtonPresentation.accessibilityLabel, "Show in Usage HUD")
XCTAssertFalse(snapshot.usageOverlayButtonPresentation.isHighlighted)
XCTAssertEqual(presentation.accessibilityLabel, "Hide from Usage HUD")
XCTAssertTrue(presentation.isHighlighted)
```

- [ ] **Step 2: symbol 테스트가 현재 `chart.bar.xaxis` 구현에서 실패하는지 확인**

Run: `swift test --filter DashboardAccountSnapshotTests/testAccountSnapshotPreservesUsageOverlayVisibility`

Expected: FAIL — actual `chart.bar.xaxis`, expected `macwindow`

- [ ] **Step 3: 버튼 UI 계약 실패 테스트 보강**

`UsageOverlayAccountVisibilityUITests.testUsageHUDButtonKeepsClickTargetTooltipAndAccessibilityLabel`을 다음 이름과 assertion으로 확장한다.

```swift
func testUsageHUDButtonUsesQuietWindowPresentationAndKeepsInteractionContract() throws {
    let button = try sourceSection(
        in: dashboardSource(),
        after: "private var usageOverlayButton: some View {",
        before: "\n    }\n\n    @ViewBuilder"
    )

    XCTAssertTrue(button.contains(".frame(width: 26, height: 26)"))
    XCTAssertTrue(button.contains("BrandPalette.accent"))
    XCTAssertTrue(button.contains("Color.primary.opacity(hovering ? 0.65 : 0.38)"))
    XCTAssertTrue(button.contains(".help(presentation.accessibilityLabel)"))
    XCTAssertTrue(button.contains(".accessibilityLabel(presentation.accessibilityLabel)"))
    XCTAssertFalse(button.contains(".background"))
    XCTAssertFalse(button.contains("RoundedRectangle"))
}
```

이 테스트는 현재 selected background와 기존 foreground 구현 때문에 실패해야 한다.

- [ ] **Step 4: UI 계약 테스트의 RED 확인**

Run: `swift test --filter UsageOverlayAccountVisibilityUITests/testUsageHUDButtonUsesQuietWindowPresentationAndKeepsInteractionContract`

Expected: FAIL — inactive hover opacity 표현이 없고 `.background`/`RoundedRectangle`이 존재

- [ ] **Step 5: button presentation symbol 변경**

`UsageOverlayAccountButtonPresentation`의 symbol을 변경한다.

```swift
struct UsageOverlayAccountButtonPresentation: Equatable {
    let symbolName = "macwindow"
    let accessibilityLabel: String
    let isHighlighted: Bool

    init(showsInUsageOverlay: Bool) {
        accessibilityLabel = showsInUsageOverlay
            ? "Hide from Usage HUD"
            : "Show in Usage HUD"
        isHighlighted = showsInUsageOverlay
    }
}
```

- [ ] **Step 6: 선택 background를 제거하고 foreground만 상태화**

`DashboardView.usageOverlayButton`을 다음 구현으로 교체한다.

```swift
private var usageOverlayButton: some View {
    let presentation = account.usageOverlayButtonPresentation
    return Button(action: toggleUsageOverlayVisibility) {
        Image(systemName: presentation.symbolName)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .foregroundStyle(
                presentation.isHighlighted
                    ? BrandPalette.accent
                    : Color.primary.opacity(hovering ? 0.65 : 0.38)
            )
    }
    .buttonStyle(.plain)
    .help(presentation.accessibilityLabel)
    .accessibilityLabel(presentation.accessibilityLabel)
}
```

별도 `.background`, rounded shape, scale 또는 animation modifier를 추가하지 않는다.

- [ ] **Step 7: 버튼 focused tests 실행**

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Expected: snapshot 12개와 HUD button UI source tests 모두 PASS

- [ ] **Step 8: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift
git commit -m "style: refine Usage HUD account button"
```

---

### Task 2: Expanded 새 계정 행 insertion fade-in

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:217-251`
- Create: `Tests/CLIProxyManagerAppTests/ExpandedUsageOverlayAnimationTests.swift`

**Interfaces:**
- Consumes: `ExpandedUsageOverlayContent.providers: [MenuBarConnectedProvider]`, SwiftUI `accessibilityReduceMotion`
- Produces: Expanded account stack의 `.asymmetric(insertion: .opacity, removal: .identity)` transition과 `0.12`초 Reduce Motion-aware animation

- [ ] **Step 1: Expanded animation source 계약 실패 테스트 작성**

`Tests/CLIProxyManagerAppTests/ExpandedUsageOverlayAnimationTests.swift`를 생성한다.

```swift
import Foundation
import XCTest

final class ExpandedUsageOverlayAnimationTests: XCTestCase {
    func testExpandedAccountStackUsesInsertionOnlyFadeAndReduceMotion() throws {
        let source = try usageOverlaySource()
        let content = try sourceSection(
            in: source,
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )
        let accountStack = try sourceSection(
            in: content,
            after: "VStack(alignment: .leading, spacing: 14) {",
            before: "\n                }"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(accountStack.contains(".transition(.asymmetric(insertion: .opacity, removal: .identity))"))
        XCTAssertTrue(content.contains("accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)"))
        XCTAssertTrue(content.contains("value: providers.map(\\.id)"))
    }

    func testCompactContentDoesNotOwnExpandedInsertionAnimation() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains(".asymmetric(insertion: .opacity, removal: .identity)"))
        XCTAssertFalse(source.contains(".easeOut(duration: 0.12)"))
    }

    private func usageOverlaySource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift"),
            encoding: .utf8
        )
    }

    private func sourceSection(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 2: animation 테스트가 현재 구현에서 실패하는지 확인**

Run: `swift test --filter ExpandedUsageOverlayAnimationTests`

Expected: FAIL — Expanded content에 Reduce Motion environment, asymmetric transition, 0.12초 animation이 없음

- [ ] **Step 3: Expanded content에 Reduce Motion environment 추가**

`ExpandedUsageOverlayContent`의 stored properties 앞에 추가한다.

```swift
@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
```

- [ ] **Step 4: 계정 행 insertion transition과 stack animation 구현**

Expanded provider stack만 다음처럼 변경한다.

```swift
VStack(alignment: .leading, spacing: 14) {
    ForEach(providers) { provider in
        ExpandedUsageOverlayAccountView(provider: provider)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }
}
.animation(
    accessibilityReduceMotion ? nil : .easeOut(duration: 0.12),
    value: providers.map(\.id)
)
```

modifier는 header를 포함하는 바깥 `VStack`이나 `UsageOverlayView`의 전체 `Group`에 적용하지 않는다. 기존 display-mode blur/opacity animation은 변경하지 않는다.

- [ ] **Step 5: Expanded animation focused tests 실행**

Run: `swift test --filter ExpandedUsageOverlayAnimationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayWindowControllerTests`

Expected: 새 animation contract tests, 기존 18개 presentation state tests, 53개 window controller tests 모두 PASS

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Tests/CLIProxyManagerAppTests/ExpandedUsageOverlayAnimationTests.swift
git commit -m "fix: smooth expanded HUD account insertion"
```

---

### Task 3: 전체 검증과 development build

**Files:**
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md:3-4`

**Interfaces:**
- Consumes: Task 1~2의 버튼 및 Expanded insertion 변경
- Produces: 전체 테스트 통과, debug development app bundle 및 codesign 검증, 완료 상태 문서

- [ ] **Step 1: 관련 focused tests 실행**

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Run: `swift test --filter ExpandedUsageOverlayAnimationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayWindowControllerTests`

Expected: 모든 focused tests PASS, `No matching test cases` 경고 없음

- [ ] **Step 2: 전체 test suite 실행**

Run: `swift test`

Expected: 전체 XCTest suite 0 failures, 0 unexpected failures

실패 시 완료를 주장하지 않고 `superpowers:systematic-debugging`으로 원인을 찾은 뒤 해당 Task의 RED/GREEN cycle로 돌아간다.

- [ ] **Step 3: debug development bundle과 local codesign 검증**

기존 사용자의 실행 중 development bundle과 충돌하지 않도록 `/tmp`의 별도 build directory를 사용한다.

Run:

```bash
rm -rf /tmp/cliproxymanager-hud-button-polish-debug
make verify \
  CONFIGURATION=debug \
  BUILD_DIR=/tmp/cliproxymanager-hud-button-polish-debug \
  BUNDLE_ID=com.woosublee.CLIProxyManager.dev
```

Expected:

```text
Bundled /tmp/cliproxymanager-hud-button-polish-debug/CLIProxyManager.app
codesign verification passed
```

앱은 자동으로 실행하지 않는다.

- [ ] **Step 4: 설계 문서 상태 갱신**

`docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md`의 상태를 다음으로 변경한다.

```markdown
**상태:** 구현 및 자동 검증 완료 — 수동 UI 확인 대기
```

- [ ] **Step 5: diff와 worktree 검사**

Run: `git diff --check`

Run: `git status --short --branch`

Expected: 설계 상태 문서만 tracked modification으로 남고 whitespace error 없음. 기존 `build-development/`는 실행 중인 사용자의 development bundle artifact이므로 commit 대상에 포함하지 않는다.

- [ ] **Step 6: 상태 문서 커밋**

```bash
git add docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md
git commit -m "docs: mark HUD button polish verified"
```

- [ ] **Step 7: 사용자 수동 확인 목록 안내**

다음 항목을 development build에서 사용자가 확인하도록 안내한다.

1. 버튼 symbol이 `macwindow`로 표시되는지 확인한다.
2. 표시 중/숨김 상태가 선택 background 없이 accent와 opacity만으로 구분되는지 확인한다.
3. gear 및 ellipsis와 시각적 위계가 자연스러운지 확인한다.
4. 계정을 숨길 때 현재처럼 즉시 제거되는지 확인한다.
5. Expanded에서 계정을 다시 켤 때 새 계정 행만 짧게 fade-in하고 기존 계정은 깜빡이지 않는지 확인한다.
6. Compact 계정 표시/숨김 동작이 이전과 같은지 확인한다.
7. Reduce Motion 활성화 시 새 계정이 즉시 나타나는지 확인한다.

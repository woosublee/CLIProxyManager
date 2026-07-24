# Usage HUD Account Button Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 계정 카드의 Usage HUD 버튼을 조용한 `macwindow` 표현으로 다듬고, Expanded와 Compact HUD에 계정을 다시 표시할 때 새 행만 동일하게 짧은 fade-in을 적용한다.

**Architecture:** 기존 `UsageOverlayAccountButtonPresentation`과 카드 action 구조를 유지하면서 symbol·foreground presentation만 교체한다. Expanded와 Compact의 새 account row가 transition-local opacity animation을 직접 소유하게 하여 기존 행과 removal reflow에 implicit animation이 전파되지 않도록 하고, Compact measurement stack에는 identity transition만 사용한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- 새 외부 dependency를 추가하지 않는다.
- 버튼 symbol은 정확히 `macwindow`를 사용한다.
- 26×26 click target과 `Hide from Usage HUD` / `Show in Usage HUD` copy를 유지한다.
- 버튼의 선택 background를 제거한다.
- HUD 표시 중에는 `BrandPalette.accent`, 숨김 상태에는 낮은 primary/secondary 계열 opacity를 사용한다.
- Connected, Disabled, Disconnected action 순서를 유지한다.
- Expanded와 Compact에서 추가되는 계정 행만 동일한 `0.12`초 `easeOut` opacity insertion을 사용한다.
- animation은 stack-level implicit animation이 아니라 insertion transition 자체에 결합한다.
- removal은 두 모드 모두 identity로 즉시 처리하고 기존 행의 reflow도 animate하지 않는다.
- 기존 계정과 header에 crossfade, blur, scale, move animation을 추가하지 않는다.
- Compact의 숨겨진 measurement stack에는 identity transition만 사용한다.
- `accessibilityReduceMotion == true`이면 두 모드의 account transition은 identity다.
- 저장, rollback, HUD filtering, menu bar, usage polling/cache, panel resize 정책을 변경하지 않는다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, `CONFIGURATION=debug` development app bundle build와 codesign verification까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift` — HUD 버튼의 symbol과 상태별 semantic presentation을 제공한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift` — 선택 background 없이 active/inactive foreground를 렌더링한다.
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — Expanded 새 account row의 insertion transition 자체에 opacity animation을 적용한다.
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift` — Compact 새 account row에 같은 transition을 적용하고 measurement stack에는 identity transition을 전달한다.
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift` — `macwindow`와 기존 action copy/highlight 상태를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift` — 버튼 click target, accessibility, background 제거, 상태 색상 계약을 검증한다.
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift` — 두 모드의 동일한 insertion, removal identity, Reduce Motion, Compact measurement 비동작 계약을 검증한다.
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

### Task 2: Expanded와 Compact 새 계정 행 insertion fade-in

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:217-260`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:4-120`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`

**Interfaces:**
- Consumes: `ExpandedUsageOverlayContent.providers: [MenuBarConnectedProvider]`, `CompactUsageOverlayView.providers: [MenuBarConnectedProvider]`, SwiftUI `accessibilityReduceMotion`
- Produces: 두 모드의 새 행에 동일한 transition-local `.opacity.animation(.easeOut(duration: 0.12))`, removal 및 Reduce Motion용 identity transition

- [ ] **Step 1: transition scope source 계약 실패 테스트 작성**

`Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`를 생성한다.

```swift
import Foundation
import XCTest

final class UsageOverlayAccountAnimationTests: XCTestCase {
    func testExpandedAccountUsesTransitionLocalInsertionFade() throws {
        let content = try sourceSection(
            in: try source(named: "UsageOverlayView.swift"),
            after: "private struct ExpandedUsageOverlayContent: View {",
            before: "\nenum ExpandedUsageContentPresentation"
        )
        let accountStack = try sourceSection(
            in: content,
            after: "VStack(alignment: .leading, spacing: 14) {",
            before: "\n                }"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(accountStack.contains(".transition(accountTransition)"))
        XCTAssertFalse(accountStack.contains(".animation("))
        XCTAssertTrue(content.contains("private var accountTransition: AnyTransition"))
        XCTAssertTrue(content.contains("insertion: .opacity.animation(.easeOut(duration: 0.12))"))
        XCTAssertTrue(content.contains("removal: .identity"))
        XCTAssertFalse(content.contains("value: providers.map(\\.id)"))
    }

    func testCompactVisibleRowsUseTransitionLocalFadeWhileMeasurementUsesIdentity() throws {
        let content = try sourceSection(
            in: try source(named: "CompactUsageOverlayView.swift"),
            after: "struct CompactUsageOverlayView: View {",
            before: "\nprivate struct CompactUsageAccountView"
        )
        let visibleStack = try sourceSection(
            in: content,
            after: "private var visibleAccountStack: some View {",
            before: "\n    }\n\n    @ViewBuilder"
        )
        let measurementStack = try sourceSection(
            in: content,
            after: "private var measurementAccountStack: some View {",
            before: "\n    }\n\n    private var visibleAccountStack"
        )

        XCTAssertTrue(content.contains("@Environment(\\.accessibilityReduceMotion) private var accessibilityReduceMotion"))
        XCTAssertTrue(visibleStack.contains("accountRows(transition: accountTransition)"))
        XCTAssertTrue(measurementStack.contains("accountRows(transition: .identity)"))
        XCTAssertFalse(visibleStack.contains(".animation("))
        XCTAssertFalse(measurementStack.contains(".animation("))
        XCTAssertTrue(content.contains(".transition(transition)"))
        XCTAssertTrue(content.contains("insertion: .opacity.animation(.easeOut(duration: 0.12))"))
        XCTAssertTrue(content.contains("removal: .identity"))
        XCTAssertFalse(content.contains("value: providerIDs"))
    }

    private func source(named filename: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views")
                .appendingPathComponent(filename),
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

- [ ] **Step 2: 강화한 테스트가 stack-level animation 구현에서 실패하는지 확인**

Run: `swift test --filter UsageOverlayAccountAnimationTests`

Expected: FAIL — 현재 stack-level `.animation(..., value:)` 구현과 shared Compact rows가 transition-local scope 계약을 위반

- [ ] **Step 3: Expanded row가 transition-local animation을 소유하도록 변경**

Expanded provider stack에는 implicit animation을 두지 않고 row transition만 적용한다.

```swift
VStack(alignment: .leading, spacing: 14) {
    ForEach(providers) { provider in
        ExpandedUsageOverlayAccountView(provider: provider)
            .transition(accountTransition)
    }
}
```

같은 view에 Reduce Motion-aware transition을 추가한다.

```swift
private var accountTransition: AnyTransition {
    accessibilityReduceMotion
        ? .identity
        : .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12)),
            removal: .identity
        )
}
```

이 방식은 새 row opacity만 animate하고 기존 행의 위치·값과 removal reflow는 즉시 반영한다. empty state에서 첫 provider가 추가될 때도 row가 자체 transition animation을 소유한다.

- [ ] **Step 4: Compact visible rows와 measurement rows의 transition을 분리**

separator와 account가 함께 새 행으로 fade-in하도록 각 provider를 zero-spacing `VStack`으로 묶되, transition을 parameter로 전달한다.

```swift
private var measurementAccountStack: some View {
    VStack(spacing: 0) {
        accountRows(transition: .identity)
    }
}

private var visibleAccountStack: some View {
    LazyVStack(spacing: 0) {
        accountRows(transition: accountTransition)
    }
}

@ViewBuilder
private func accountRows(transition: AnyTransition) -> some View {
    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
        VStack(spacing: 0) {
            if index > 0 {
                CompactUsageSeparator()
            }
            CompactUsageAccountView(provider: provider)
        }
        .transition(transition)
    }
}

private var accountTransition: AnyTransition {
    accessibilityReduceMotion
        ? .identity
        : .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.12)),
            removal: .identity
        )
}
```

보이는 stack과 measurement stack 모두에 `.animation(..., value:)`를 추가하지 않는다. 기존 measurement, viewport resize 및 display-mode blur/opacity animation은 변경하지 않는다.

- [ ] **Step 5: animation focused tests 실행**

Run: `swift test --filter UsageOverlayAccountAnimationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayWindowControllerTests`

Expected: transition scope tests, 기존 presentation state tests, window controller tests 모두 PASS

- [ ] **Step 6: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift
git commit -m "fix: scope HUD animation to inserted rows"
```

---

### Task 3: 전체 검증과 development build

**Files:**
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md:3-4`

**Interfaces:**
- Consumes: Task 1~2의 버튼 및 Expanded/Compact insertion 변경
- Produces: 전체 테스트 통과, debug development app bundle 및 codesign 검증, 완료 상태 문서

- [ ] **Step 1: 관련 focused tests 실행**

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Run: `swift test --filter UsageOverlayAccountAnimationTests`

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
4. Expanded와 Compact에서 계정을 숨길 때 현재처럼 즉시 제거되는지 확인한다.
5. Expanded에서 계정을 다시 켤 때 새 계정 행만 짧게 fade-in하고 기존 계정은 깜빡이지 않는지 확인한다.
6. Compact에서도 계정을 다시 켤 때 새 계정 행이 Expanded와 같은 속도로 fade-in하는지 확인한다.
7. Reduce Motion 활성화 시 두 모드 모두 새 계정이 즉시 나타나는지 확인한다.

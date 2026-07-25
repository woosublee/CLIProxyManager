# Usage HUD Account Button Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 계정 카드의 Usage HUD 버튼을 조용한 `macwindow` 표현으로 유지하고, Expanded HUD에서만 새 행의 layout을 투명하게 먼저 준비한다. controller가 hidden row를 포함한 fitting resize를 동기 적용한 뒤에 reveal을 다음 main-queue tick에 예약하여 panel resize 전 깜빡임을 제거한다. Compact의 현재 transition-local fade는 변경하지 않는다.

**Architecture:** 기존 `UsageOverlayAccountButtonPresentation`과 카드 action 구조를 유지한다. Expanded는 내부 순수 state model이 revealed provider ID를 관리하고, provider ID 변경 시 removed ID를 prune한 뒤 pending ID의 reveal closure를 injected scheduler로 전달한다. controller scheduler는 `resizeToFittingContentImmediately(animated: false)`로 pending scheduled request까지 consume/apply하고 stale schedule generation을 무효화한 후 reveal을 예약한다. row는 opacity `0/1`과 `.transition(.identity)`를 사용하므로 layout/panel fitting은 먼저 반영되고 reveal만 120ms `easeOut` animation으로 제한된다. Compact measurement/viewport 및 source는 수정하지 않는다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- 새 외부 dependency를 추가하지 않는다.
- 버튼 symbol은 정확히 `macwindow`를 사용한다.
- 26×26 click target과 `Hide from Usage HUD` / `Show in Usage HUD` copy를 유지한다.
- 버튼의 선택 background를 제거한다.
- HUD 표시 중에는 `BrandPalette.accent`, 숨김 상태에는 낮은 primary/secondary 계열 opacity를 사용한다.
- Connected, Disabled, Disconnected action 순서를 유지한다.
- Expanded 새 ID는 첫 render에서 opacity `0`으로 layout에 참여한다. controller scheduler는 hidden row를 포함한 fitting resize를 동기 apply한 뒤에만 `0.12`초 `easeOut` reveal을 다음 main-queue tick에 예약한다.
- Expanded initial provider ID는 즉시 revealed 상태이며, 기존 행·header·removal reflow에는 animation이 없다.
- Expanded row는 `.transition(.identity)`를 사용하고 stack-level implicit animation, movement, scale, blur, panel-size animation을 추가하지 않는다.
- immediate resize는 pending scheduled request에서도 early return하지 않고 request를 consume/apply한 뒤 schedule generation을 증가시켜 stale callback을 무효화한다. mode-transition animation intent는 유지한다.
- pending reveal은 generation과 현재 present ID를 확인하여 stale ID를 reveal하거나 state에 유지하지 않는다.
- `accessibilityReduceMotion == true`이면 Expanded reveal은 resize 후 다음 tick에서 animation 없이 실행한다.
- Compact의 existing transition-local fade, identity measurement transition, source와 동작은 변경하지 않는다.
- 저장, rollback, HUD filtering, menu bar, usage polling/cache, panel resize 정책을 변경하지 않는다.
- 자동 검증은 관련 단위 테스트, 전체 `swift test`, `CONFIGURATION=debug` development app bundle build와 codesign verification까지 수행한다. 앱 실행과 수동 UI 확인은 사용자가 수행한다.

## File Structure

- Modify: `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift` — HUD 버튼의 symbol과 상태별 semantic presentation을 제공한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift` — 선택 background 없이 active/inactive foreground를 렌더링한다.
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — internal insertion state와 controller-injected reveal scheduler를 제공한다.
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift` — fitting resize를 즉시 consume/apply한 뒤 reveal을 예약한다.
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift` — pure state, controller→view ordering source contract, Compact non-regression contract를 검증한다.
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift` — pending scheduled request의 immediate consume/clear behavior를 검증한다.
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md` — controller-resize-before-reveal 및 Compact 유지 정책, 자동 검증 완료 상태를 기록한다.
- Modify: `docs/superpowers/plans/2026-07-25-hud-account-button-polish.md` — staged reveal review fix 구현 및 검증 계획을 기록한다.

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

- [x] **Step 1: 버튼 symbol 실패 테스트 갱신**

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

- [x] **Step 2: symbol 테스트가 현재 `chart.bar.xaxis` 구현에서 실패하는지 확인**

Run: `swift test --filter DashboardAccountSnapshotTests/testAccountSnapshotPreservesUsageOverlayVisibility`

Expected: FAIL — actual `chart.bar.xaxis`, expected `macwindow`

- [x] **Step 3: 버튼 UI 계약 실패 테스트 보강**

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

- [x] **Step 4: UI 계약 테스트의 RED 확인**

Run: `swift test --filter UsageOverlayAccountVisibilityUITests/testUsageHUDButtonUsesQuietWindowPresentationAndKeepsInteractionContract`

Expected: FAIL — inactive hover opacity 표현이 없고 `.background`/`RoundedRectangle`이 존재

- [x] **Step 5: button presentation symbol 변경**

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

- [x] **Step 6: 선택 background를 제거하고 foreground만 상태화**

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

- [x] **Step 7: 버튼 focused tests 실행**

Run: `swift test --filter DashboardAccountSnapshotTests`

Run: `swift test --filter UsageOverlayAccountVisibilityUITests`

Expected: snapshot 12개와 HUD button UI source tests 모두 PASS

- [x] **Step 8: 커밋**

```bash
git add Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift Sources/CLIProxyManagerApp/Views/DashboardView.swift Tests/CLIProxyManagerAppTests/DashboardAccountSnapshotTests.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountVisibilityUITests.swift
git commit -m "style: refine Usage HUD account button"
```

---

### Task 2: Expanded 투명 layout 준비와 controller-ordered reveal

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`

**Interfaces:**
- Consumes: `ExpandedUsageOverlayContent.providers: [MenuBarConnectedProvider]`, SwiftUI `accessibilityReduceMotion`, controller-provided scheduler
- Produces: `ExpandedUsageOverlayInsertionState`, transparent-first layout, fitting-resize-before-reveal ordering, generation-guarded next-main-queue reveal
- Preserves: `CompactUsageOverlayView` source, measurement/viewport, transition-local fade

- [x] **Step 1: state model과 staged source 계약 RED 테스트 작성**

`@testable import CLIProxyManagerApp`을 추가하고 다음 순수 state 동작을 테스트한다.

- 초기 provider ID는 즉시 revealed다.
- `prepare(providerIDs:)`는 removed ID를 prune하고 새 ID만 pending으로 반환한다.
- `reveal(_:presentProviderIDs:)`는 present인 pending ID만 reveal한다.
- remove 후 re-add한 ID는 다시 pending이다.

Expanded source 계약은 opacity `0/1`과 `.transition(.identity)`, provider ID 변경의 prepare, injected scheduler, generation guard, regular-motion 전용 `withAnimation(.easeOut(duration: 0.12))`, Reduce Motion의 non-animated reveal, mounted `accountSurface`/`ForEach`, stack-level `.animation(..., value:)` 부재를 검증한다. Controller contract는 immediate fitting resize가 reveal scheduling보다 앞서고 pending scheduled resize도 consume/clear하는지 검증한다. Compact는 기존 source contract로 non-regression만 검증한다.

- [x] **Step 2: RED 확인**

Run: `swift test --filter UsageOverlayAccountAnimationTests`

Expected: FAIL — `ExpandedUsageOverlayInsertionState`가 아직 없어 test target이 compile하지 않는다. 이는 state model/staged contract 부재를 확인하는 expected RED다.

- [x] **Step 3: Expanded two-phase staged reveal 구현**

`UsageOverlayView.swift`의 private Expanded view 외부에 internal `ExpandedUsageOverlayInsertionState`를 추가한다. custom `init`은 incoming provider ID로 `@State`를 초기화하여 initial presentation의 existing ID가 즉시 보이도록 한다. provider ID 변경은 generation을 먼저 증가시키고 `prepare`를 동기 호출한다. pending ID가 있으면 injected scheduler closure가 generation을 재검증한 뒤 current present ID와 교차해 reveal한다. controller scheduler는 reveal을 예약하기 전에 fitting resize를 즉시 consume/apply한다.

Expanded account row는 다음 계약을 사용한다.

```swift
.opacity(insertionState.isRevealed(provider.id) ? 1 : 0)
.transition(.identity)
```

regular motion만 `withAnimation(.easeOut(duration: 0.12))`으로 reveal mutation을 감싼다. Reduce Motion은 fitting resize 후 동일한 next tick에서 animation 없이 mutation을 수행한다. Compact source를 변경하지 않는다.

- [x] **Step 4: focused regression tests 실행**

Run: `swift test --filter UsageOverlayAccountAnimationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayWindowControllerTests`

Expected: staged state/source contract과 existing presentation/window-controller tests 모두 PASS

- [x] **Step 5: 지정된 단일 커밋 생성**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md docs/superpowers/plans/2026-07-25-hud-account-button-polish.md
git commit -m "fix: stage expanded HUD account reveal"
```

---

### Task 3: 전체 검증과 development build

**Files:**
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md:3-4`

**Interfaces:**
- Consumes: 기존 버튼 polish와 Expanded staged reveal, 변경하지 않은 Compact behavior
- Produces: 전체 테스트 통과, debug development app bundle 및 codesign 검증, 완료 상태 문서

- [x] **Step 1: 관련 focused tests 실행**

Run: `swift test --filter UsageOverlayAccountAnimationTests`

Run: `swift test --filter UsageOverlayPresentationStateTests`

Run: `swift test --filter UsageOverlayWindowControllerTests`

Expected: staged reveal 및 기존 presentation/window controller tests 모두 PASS

- [x] **Step 2: 전체 test suite 실행**

Run: `swift test`

Expected: 전체 XCTest suite 0 failures, 0 unexpected failures

실패 시 완료를 주장하지 않고 `superpowers:systematic-debugging`으로 원인을 찾은 뒤 해당 Task의 RED/GREEN cycle로 돌아간다.

- [x] **Step 3: debug development bundle과 local codesign 검증**

기존 사용자의 실행 중 development bundle과 충돌하지 않도록 `/tmp`의 별도 build directory를 사용한다.

Run:

```bash
rm -rf /tmp/cliproxymanager-expanded-staged-reveal-debug
make verify \
  CONFIGURATION=debug \
  BUILD_DIR=/tmp/cliproxymanager-expanded-staged-reveal-debug \
  BUNDLE_ID=com.woosublee.CLIProxyManager.dev
```

Expected:

```text
Bundled /tmp/cliproxymanager-expanded-staged-reveal-debug/CLIProxyManager.app
codesign verification passed
```

앱은 자동으로 실행하지 않는다.

- [x] **Step 4: 설계 문서 상태 갱신**

`docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md`의 상태를 다음으로 변경한다.

```markdown
**상태:** 구현 및 자동 검증 완료 — 수동 UI 확인 대기
```

- [x] **Step 5: diff와 worktree 검사**

Run: `git diff --check`

Run: `git status --short --branch`

Expected: source, test, design spec, implementation plan만 tracked modification으로 남고 whitespace error 없음. 기존 `build-development/`는 사용자의 development bundle artifact이므로 commit 대상에 포함하지 않는다.

- [x] **Step 6: 지정된 단일 커밋 생성**

```bash
git add Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md docs/superpowers/plans/2026-07-25-hud-account-button-polish.md
git commit -m "fix: stage expanded HUD account reveal"
```

- [x] **Step 7: 사용자 수동 확인 목록 안내**

다음 항목을 development build에서 사용자가 확인하도록 안내한다.

1. 버튼 symbol이 `macwindow`로 표시되는지 확인한다.
2. 표시 중/숨김 상태가 선택 background 없이 accent와 opacity만으로 구분되는지 확인한다.
3. gear 및 ellipsis와 시각적 위계가 자연스러운지 확인한다.
4. Expanded와 Compact에서 계정을 숨길 때 현재처럼 즉시 제거되는지 확인한다.
5. Expanded에서 계정을 다시 켤 때 controller가 hidden row를 포함해 fitting resize를 먼저 적용하고, 새 계정 행만 다음 tick에 120ms reveal되며 기존 계정은 깜빡이지 않는지 확인한다.
6. Compact의 기존 transition-local fade 동작이 유지되는지 확인한다.
7. Reduce Motion 활성화 시 Expanded 새 계정이 resize 후 다음 tick에 animation 없이 나타나는지 확인한다.

---

### Task 4: review fix — controller fitting resize를 reveal보다 먼저 적용

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`
- Modify: design spec 및 이 implementation plan

- [x] **Step 1: ordering 계약 RED 테스트 작성 및 확인**

`UsageOverlayAccountAnimationTests`는 view의 injected scheduler, controller의 `resizeToFittingContentImmediately(animated: false)` 후 reveal scheduling 순서, immediate path의 unguarded request/consume contract를 검사한다. `UsageOverlayWindowControllerTests`는 pending scheduled request가 immediate consume으로 scheduled flag를 clear하고 pending animation intent를 유지하는지 검사한다.

Run: `swift test --filter UsageOverlayAccountAnimationTests && swift test --filter UsageOverlayWindowControllerTests`

Expected RED: `UsageOverlayResizeCoordinator.isResizeScheduled`와 controller/view ordering wiring이 아직 없어 focused target이 실패한다.

- [x] **Step 2: controller-ordered scheduler 구현**

`UsageOverlayView`는 `UsageOverlayExpandedInsertionRevealScheduler` dependency를 통해 reveal closure를 전달한다. 기본 initializer scheduler는 controller가 없을 때 next-main-queue fallback을 제공한다. `UsageOverlayWindowController.configurePanelAndContent`은 hidden row fitting resize를 즉시 apply한 다음 main queue에서 reveal closure를 실행하는 scheduler를 주입한다.

`resizeToFittingContentImmediately(animated:)`는 `requestResize`가 이미 scheduled라 해도 guard로 반환하지 않는다. request를 consume/apply하기 위해 generation을 증가시키고 `performScheduledResize()`를 즉시 호출한다.

- [x] **Step 3: fresh regression 검증**

- `swift test --filter UsageOverlayAccountAnimationTests` — 7 tests, 0 failures
- `swift test --filter UsageOverlayWindowControllerTests` — 54 tests, 0 failures
- `swift test --filter UsageOverlayPresentationStateTests` — 18 tests, 0 failures
- `swift test` — 1,016 tests, 0 failures
- `make verify CONFIGURATION=debug BUILD_DIR=/tmp/cliproxymanager-expanded-staged-reveal-review-debug BUNDLE_ID=com.woosublee.CLIProxyManager.dev` — bundled and codesign verified
- `git diff --check` — whitespace errors 없음

- [x] **Step 4: documentation, report, and fix commit**

Design spec을 controller immediate fitting resize 후 reveal scheduling semantics로 갱신하고, `/tmp/expanded-hud-staged-reveal-report.md`에 review fix RED/GREEN evidence와 새 commit SHA를 기록한다. Compact production source와 `build-development/`는 변경·commit하지 않는다.

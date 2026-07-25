# Usage HUD Account Content Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expanded와 Compact Usage HUD에서 계정 목록 추가·제거를 Chrome 아래 전체 콘텐츠의 conceal→swap→resize→reveal transaction으로 표시한다.

**Architecture:** 기존 `UsageOverlayAccountPresentation`을 desired/presented snapshot으로 재사용한다. 순수 `UsageOverlayAccountTransitionCoordinator`가 phase, generation, 최신 desired 값을 관리하고, `UsageOverlayWindowController`가 scheduler·SwiftUI state·AppKit frame resize를 실행한다. `UsageOverlayView`는 ViewModel의 즉시 계산값 대신 `UsageOverlayPresentationState.presentedAccountPresentation`만 렌더링한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, Combine, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- production bundle ID `com.woosublee.CLIProxyManager` 앱은 실행, 종료, 활성화, 재실행하거나 process를 조작하지 않는다.
- 자동 검증은 테스트, development bundle 생성, codesign까지 수행한다.
- development 앱 실행은 사용자가 명시적으로 요청한 경우에만 현재 worktree의 development bundle을 대상으로 한다.
- 기존 untracked `build-development/`는 commit하지 않는다.
- 계정 행별 insertion/removal transition을 추가하지 않는다.
- Chrome은 항상 opacity `1`을 유지한다.
- 콘텐츠 conceal/reveal은 `0.14`초 `easeInOut`, blur radius `8`, hidden opacity `0`을 사용한다.
- panel resize는 기존 `0.25`초 `easeInEaseOut`과 top-right anchor 정책을 유지한다.
- `hiddenAccountIDs`, 계정 순서, 메뉴바 filtering, usage polling/cache, 저장 rollback 동작을 변경하지 않는다.
- Compact hidden measurement stack과 마지막 계정 제거 후 empty-state 실제 높이 재측정 fix를 유지한다.

## File Structure

- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountTransitionCoordinator.swift` — 계정 콘텐츠 transaction의 순수 phase/generation/desired 상태와 callback guard
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountTransitionCoordinatorTests.swift` — coordinator의 identity, coalescing, stale callback, rollback 계약
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift` — direct snapshot initializer와 ordered provider IDs
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift` — presented snapshot, account phase projection, mode/account concealment 합성
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift` — presented snapshot만 렌더링하고 account phase로 content animation
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift` — ViewModel desired 계산, transaction orchestration, resize completion 분리, mode/lifecycle 충돌 처리
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift` — concealment 합성과 snapshot publication 검증
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift` — hide→swap→resize→show, rapid retarget, mode absorption, lifecycle, Reduce Motion 검증
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift` — row animation 부재와 buffered rendering source 계약 갱신
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md` — 롤백 이후 후속 설계가 별도 spec으로 승인됐음을 연결
- Modify: `docs/superpowers/plans/2026-07-25-hud-account-button-polish.md` — 재설계 대기 상태를 후속 plan 참조로 갱신

---

### Task 1: Account transition coordinator

**Files:**
- Create: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountTransitionCoordinator.swift`
- Create: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountTransitionCoordinatorTests.swift`
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift`

**Interfaces:**
- Produces: `UsageOverlayAccountPresentation.init(providers:emptyMessage:)`
- Produces: `UsageOverlayAccountPresentation.orderedProviderIDs: [ProviderRowState.ID]`
- Produces: `UsageOverlayAccountTransitionPhase`
- Produces: `UsageOverlayAccountTransitionCoordinator.receive(_:presentedProviderIDs:allowsAnimation:)`
- Produces: generation-guarded `completeConceal`, `beginResize`, `completeResize`, `completeReveal`, `retargetResize`, `absorbLatestPresentation`

- [ ] **Step 1: Write failing coordinator tests**

Create focused tests covering the public behavior:

```swift
func testIdentityChangeBeginsConcealWithoutReplacingPresentedSnapshot() {
    var coordinator = UsageOverlayAccountTransitionCoordinator(initialPresentation: oneAccount)

    let action = coordinator.receive(
        twoAccounts,
        presentedProviderIDs: oneAccount.orderedProviderIDs,
        allowsAnimation: true
    )

    XCTAssertEqual(action, .beginConceal(generation: 1))
    XCTAssertEqual(coordinator.phase, .concealing)
    XCTAssertEqual(coordinator.desiredPresentation, twoAccounts)
}

func testSameIdentityAppliesLatestValuesImmediately() {
    var coordinator = UsageOverlayAccountTransitionCoordinator(initialPresentation: oneAccount)
    let renamed = presentation(providerIDs: [.claude], displayNames: ["Renamed"])

    XCTAssertEqual(
        coordinator.receive(
            renamed,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        ),
        .applyImmediately(renamed)
    )
}

func testConcealingChangesCoalesceToLatestGeneration() {
    var coordinator = UsageOverlayAccountTransitionCoordinator(initialPresentation: oneAccount)
    XCTAssertEqual(coordinator.receive(twoAccounts, presentedProviderIDs: oneAccount.orderedProviderIDs, allowsAnimation: true), .beginConceal(generation: 1))
    XCTAssertEqual(coordinator.receive(threeAccounts, presentedProviderIDs: oneAccount.orderedProviderIDs, allowsAnimation: true), .beginConceal(generation: 2))
    XCTAssertNil(coordinator.completeConceal(generation: 1))
    XCTAssertEqual(coordinator.completeConceal(generation: 2), threeAccounts)
}

func testRollbackToPresentedIdentityCancelsPendingSwapAndReveals() {
    var coordinator = UsageOverlayAccountTransitionCoordinator(initialPresentation: oneAccount)
    _ = coordinator.receive(twoAccounts, presentedProviderIDs: oneAccount.orderedProviderIDs, allowsAnimation: true)

    XCTAssertEqual(
        coordinator.receive(oneAccount, presentedProviderIDs: oneAccount.orderedProviderIDs, allowsAnimation: true),
        .beginReveal(generation: 2)
    )
}

func testReduceMotionAppliesIdentityChangeImmediately() {
    var coordinator = UsageOverlayAccountTransitionCoordinator(initialPresentation: oneAccount)
    XCTAssertEqual(
        coordinator.receive(twoAccounts, presentedProviderIDs: oneAccount.orderedProviderIDs, allowsAnimation: false),
        .applyImmediately(twoAccounts)
    )
    XCTAssertEqual(coordinator.phase, .visible)
}
```

Also test ordered reordering, stale resize/reveal completions, resizing retarget, and mode/lifecycle absorption.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter UsageOverlayAccountTransitionCoordinatorTests
```

Expected: compile/test failure because the coordinator and direct snapshot API do not exist.

- [ ] **Step 3: Implement the minimal presentation helpers and coordinator**

Use a small action enum so the controller does not duplicate phase decisions:

```swift
enum UsageOverlayAccountTransitionPhase: Equatable {
    case visible, concealing, swapping, resizing, revealing
}

struct UsageOverlayAccountTransitionCoordinator {
    enum Action: Equatable {
        case none
        case applyImmediately(UsageOverlayAccountPresentation)
        case beginConceal(generation: Int)
        case beginReveal(generation: Int)
        case retargetHidden(generation: Int, presentation: UsageOverlayAccountPresentation)
    }

    private(set) var generation = 0
    private(set) var phase: UsageOverlayAccountTransitionPhase = .visible
    private(set) var desiredPresentation: UsageOverlayAccountPresentation

    init(initialPresentation: UsageOverlayAccountPresentation) {
        desiredPresentation = initialPresentation
    }
}
```

Every callback method must return no action/value when its generation is stale. `receive` compares ordered IDs rather than sets.

- [ ] **Step 4: Run coordinator tests and presentation model tests**

Run:

```bash
swift test --filter UsageOverlayAccountTransitionCoordinatorTests
swift test --filter UsageOverlayAccountPresentationTests
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerApp/Models/UsageOverlayAccountPresentation.swift \
  Sources/CLIProxyManagerApp/Models/UsageOverlayAccountTransitionCoordinator.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayAccountTransitionCoordinatorTests.swift
git commit -m "feat: model buffered HUD account transitions"
```

---

### Task 2: Presentation state and buffered SwiftUI rendering

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`

**Interfaces:**
- Consumes: `UsageOverlayAccountTransitionPhase`
- Consumes: `UsageOverlayAccountPresentation`
- Produces: `UsageOverlayPresentationState.presentedAccountPresentation`
- Produces: `UsageOverlayPresentationState.accountTransitionPhase`
- Produces: `UsageOverlayPresentationState.isContentHiddenForAccountTransition`
- Produces: `UsageOverlayPresentationState.isContentConcealed`

- [ ] **Step 1: Write failing presentation-state tests**

Add tests with an initial snapshot:

```swift
func testAccountTransitionConcealsContentWithoutConcealingChrome() {
    let state = UsageOverlayPresentationState(
        displayMode: .expanded,
        accountPresentation: oneAccountPresentation
    )

    state.accountTransitionPhase = .concealing

    XCTAssertEqual(state.contentBlurRadius, 8)
    XCTAssertEqual(state.contentOpacity, 0)
    XCTAssertEqual(state.chromeOpacity, 1)
}

func testModeAndAccountConcealmentComposeUntilBothRelease() {
    let state = makeState()
    state.isContentHiddenForModeTransition = true
    state.accountTransitionPhase = .resizing

    state.isContentHiddenForModeTransition = false
    XCTAssertEqual(state.contentOpacity, 0)

    state.accountTransitionPhase = .revealing
    XCTAssertEqual(state.contentOpacity, 1)
}

func testPresentationStatePublishesBufferedAccountSnapshot() {
    let state = makeState(accountPresentation: oneAccountPresentation)
    state.presentedAccountPresentation = twoAccountPresentation
    XCTAssertEqual(state.presentedAccountPresentation, twoAccountPresentation)
}
```

Update source-contract tests to require `presentationState.presentedAccountPresentation` in both Expanded and Compact rendering while still forbidding row-level `.transition(` calls and insertion state.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayAccountAnimationTests
```

Expected: failures for missing account presentation state and the view still using its local `accountPresentation`.

- [ ] **Step 3: Implement presentation state and view changes**

Initialize state with the initial snapshot and compose concealment:

```swift
@Published var presentedAccountPresentation: UsageOverlayAccountPresentation
@Published var accountTransitionPhase: UsageOverlayAccountTransitionPhase = .visible

var isContentHiddenForAccountTransition: Bool {
    switch accountTransitionPhase {
    case .concealing, .swapping, .resizing: true
    case .revealing, .visible: false
    }
}

var isContentConcealed: Bool {
    isContentHiddenForModeTransition || isContentHiddenForAccountTransition
}
```

Remove `UsageOverlayView.accountPresentation`. Read one local `let accountPresentation = presentationState.presentedAccountPresentation` in `body` and use it for Expanded, Compact, and compact measurement content. Animate against `presentationState.isContentConcealed`, not only mode concealment.

- [ ] **Step 4: Run focused tests**

```bash
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayAccountAnimationTests
```

Expected: all selected tests pass; Compact measurement regression remains green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift \
  Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift
git commit -m "feat: buffer Usage HUD account presentation"
```

---

### Task 3: Controller hide→swap→resize→show transaction

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`

**Interfaces:**
- Consumes: coordinator actions and presentation state from Tasks 1–2
- Produces: `UsageOverlayWindowController.updateAccountPresentation(_:)`
- Produces test-visible read-only `presentedAccountPresentation` and `accountTransitionPhase`
- Adds injectable `accountConcealScheduler` and `accountRevealScheduler`

- [ ] **Step 1: Write failing basic transaction tests**

Construct the controller with `initialAccountPresentation`, captured schedulers, fixed fitting size, and captured frame completion. Show the panel through `showForCurrentSession` before sending a changed presentation.

```swift
func testAccountAdditionKeepsOldSnapshotUntilConcealCompletes() {
    var completeConceal: (@MainActor () -> Void)?
    var frameAnimationStarted = false
    let controller = makeAccountTransitionController(
        initial: oneAccount,
        accountConcealScheduler: { completeConceal = $0 },
        frameAnimator: { _, _, _ in frameAnimationStarted = true }
    )

    controller.updateAccountPresentation(twoAccounts)

    XCTAssertEqual(controller.presentedAccountPresentation, oneAccount)
    XCTAssertEqual(controller.accountTransitionPhase, .concealing)
    XCTAssertFalse(frameAnimationStarted)

    completeConceal?()
    XCTAssertEqual(controller.presentedAccountPresentation, twoAccounts)
    XCTAssertEqual(controller.accountTransitionPhase, .resizing)
    XCTAssertTrue(frameAnimationStarted)
}

func testAccountContentRevealsOnlyAfterFrameAndRevealCompletions() {
    var completeConceal: (@MainActor () -> Void)?
    var completeFrame: (@MainActor () -> Void)?
    var completeReveal: (@MainActor () -> Void)?
    let controller = makeAccountTransitionController(
        initial: oneAccount,
        accountConcealScheduler: { completeConceal = $0 },
        accountRevealScheduler: { completeReveal = $0 },
        frameAnimator: { _, _, completion in completeFrame = completion }
    )

    controller.updateAccountPresentation(twoAccounts)
    completeConceal?()
    XCTAssertEqual(controller.accountTransitionPhase, .resizing)

    completeFrame?()
    XCTAssertEqual(controller.accountTransitionPhase, .revealing)

    completeReveal?()
    XCTAssertEqual(controller.accountTransitionPhase, .visible)
}
```

Mirror the first test for account removal to prove both directions share the same flow.

- [ ] **Step 2: Run controller tests and verify RED**

```bash
swift test --filter UsageOverlayWindowControllerTests/testAccount
```

Expected: compile failures for the new initializer inputs and controller methods.

- [ ] **Step 3: Add controller state, scheduling, and completion-safe resizing**

Add stored dependencies:

```swift
private let accountConcealScheduler: (@escaping @MainActor () -> Void) -> Void
private let accountRevealScheduler: (@escaping @MainActor () -> Void) -> Void
private var accountTransitionCoordinator: UsageOverlayAccountTransitionCoordinator
```

Defaults use `DispatchQueue.main.asyncAfter` with `0.14` seconds. Production initial presentation is computed from the supplied `DashboardViewModel`; tests may supply `initialAccountPresentation` directly.

Refactor `updateContentSize` to accept an optional completion closure and only clear mode concealment when a non-nil mode transition generation completes. An ordinary/account resize with `transitionGeneration == nil` must never reveal an active mode transition.

On conceal completion:

1. generation guard through coordinator
2. phase `.swapping`
3. commit latest desired to `presentationState.presentedAccountPresentation`
4. schedule layout on the next main queue turn
5. phase `.resizing`
6. calculate fitting size and call `updateContentSize(fittingSize, animated: true, transitionGeneration: nil, completion: accountResizeCompletion)`
7. on latest frame completion, phase `.revealing` and schedule reveal completion

- [ ] **Step 4: Connect ViewModel updates**

Replace the existing unconditional `viewModel.objectWillChange` resize with a next-main-queue snapshot calculation:

```swift
let presentation = UsageOverlayAccountPresentation(
    serverStatus: viewModel.serverStatus,
    serverControlState: viewModel.serverControlState,
    providerRows: viewModel.providerRows,
    port: viewModel.config.port
)
self.updateAccountPresentation(presentation)
```

When the full presentation is equal, do nothing. Same ordered IDs with changed values apply immediately and request the existing non-animated fitting resize.

- [ ] **Step 5: Run focused controller and view tests**

```bash
swift test --filter UsageOverlayWindowControllerTests/testAccount
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayAccountAnimationTests
```

Expected: basic add/remove transaction tests pass without row animation regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift
git commit -m "feat: transition buffered HUD account content"
```

---

### Task 4: Rapid updates, mode collision, lifecycle, and Reduce Motion

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayAccountTransitionCoordinator.swift`
- Modify: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountTransitionCoordinatorTests.swift`
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`

**Interfaces:**
- Consumes existing mode `UsageOverlayResizeCoordinator`
- Produces account transaction absorption/retarget methods
- Preserves existing window move and screen geometry APIs

- [ ] **Step 1: Write failing rapid-update tests**

Cover:

- two conceal callbacks where only the latest may swap
- a second desired presentation during frame resize interrupts the old frame and retargets latest fitting size
- old frame completion before or after new completion cannot reveal
- rollback to current presented IDs during conceal skips swap/resize and reveals
- same-identity usage changes during visible state do not conceal

Use arrays of captured callbacks and assert exact phase/snapshot/frame-animation counts.

- [ ] **Step 2: Write failing mode and lifecycle tests**

Add these concrete test cases:

- `testModeToggleAbsorbsAccountTransitionAndRevealsOnce`: start account conceal, toggle mode, invoke the stale account conceal callback, complete the mode frame, and assert the latest snapshot is presented with account phase `.visible` and mode content revealed once.
- `testAccountChangeDuringModeTransitionUsesLatestSnapshotForModeResize`: start a captured mode frame, update to a second account snapshot while mode content is hidden, drain the main queue, and assert the follow-up fitting resize uses the latest snapshot before reveal.
- `testHideCancelsAccountCallbacksAndAppliesLatestSnapshotWithoutAnimation`: start account conceal, hide the session, invoke the captured conceal callback, and assert the latest snapshot remains presented, phase remains `.visible`, and no frame animation was added.
- `testWindowMoveDuringAccountResizeSettlesAtMovedAnchorThenReveals`: start a captured account frame, simulate a user move, complete `windowDidMove`, invoke the stale frame callback, and assert the moved maxX/maxY, final fitting size, and one reveal path.
- `testScreenChangeDuringAccountResizeInvalidatesStaleCompletion`: start a captured account frame, trigger deferred screen resize, run it, invoke the stale frame callback, and assert the screen-adjusted frame and final `.visible` phase remain unchanged.
- `testReduceMotionAppliesAccountSnapshotAndFrameImmediately`: enable Reduce Motion, update the identity, and assert the new snapshot, fitting frame, and `.visible` phase are applied before the method returns with zero scheduler/frame-animation captures.

Each stale callback must be invoked explicitly after the newer path completes to prove it cannot mutate state.

- [ ] **Step 3: Run the new tests and verify RED**

```bash
swift test --filter UsageOverlayAccountTransitionCoordinatorTests
swift test --filter UsageOverlayWindowControllerTests/testRapidAccount
swift test --filter UsageOverlayWindowControllerTests/testModeToggleAbsorbsAccount
swift test --filter UsageOverlayWindowControllerTests/testAccountChangeDuringMode
swift test --filter UsageOverlayWindowControllerTests/testHideCancelsAccount
swift test --filter UsageOverlayWindowControllerTests/testWindowMoveDuringAccount
swift test --filter UsageOverlayWindowControllerTests/testScreenChangeDuringAccount
swift test --filter UsageOverlayWindowControllerTests/testReduceMotionAppliesAccount
```

Expected: behavior failures for unimplemented retarget/absorption paths.

- [ ] **Step 4: Implement rapid retargeting**

On desired changes during `.resizing`, increment generation, interrupt the current account frame animation, commit the latest snapshot while hidden, and start a new fitting resize. Completion closures always call coordinator generation guards.

On Compact measurement invalidation during `.resizing`, use `retargetResize()` to issue a new generation before fitting-size retarget so an earlier estimated-height completion cannot reveal.

- [ ] **Step 5: Implement mode precedence**

At the start of `toggleDisplayMode`, absorb the latest account snapshot and invalidate account callbacks before enabling mode concealment. If account data changes while mode concealment is active, commit it immediately under mode concealment and request a mode-coordinated fitting retarget. Mode completion is the sole reveal owner.

- [ ] **Step 6: Implement lifecycle settlement**

- hide/session close: invalidate callbacks, commit latest snapshot, set account phase `.visible`, no account animation
- user move during account resize: interrupt frame, keep account phase hidden, apply unanimated fitting size at `windowDidMove`, then reveal
- screen geometry change during account resize: invalidate old completion, commit latest snapshot, keep hidden through deferred screen resize, then reveal

- [ ] **Step 7: Implement Reduce Motion path**

With Reduce Motion enabled, `updateAccountPresentation` immediately commits the latest snapshot, lays out, applies the fitting frame without animation, and leaves phase `.visible`. It must also invalidate any previously scheduled callbacks.

- [ ] **Step 8: Run all focused HUD tests**

```bash
swift test --filter UsageOverlayAccountTransitionCoordinatorTests
swift test --filter UsageOverlayPresentationStateTests
swift test --filter UsageOverlayWindowControllerTests
swift test --filter UsageOverlayAccountAnimationTests
```

Expected: all focused tests pass, including existing mode, placement, Compact measurement, and row-animation rollback tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/CLIProxyManagerApp/Models/UsageOverlayAccountTransitionCoordinator.swift \
  Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayAccountTransitionCoordinatorTests.swift \
  Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift
git commit -m "fix: coalesce Usage HUD account transitions"
```

---

### Task 5: Documentation and full verification

**Files:**
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md`
- Modify: `docs/superpowers/plans/2026-07-25-hud-account-button-polish.md`
- Modify: `docs/superpowers/plans/2026-07-25-hud-account-content-transition.md`

**Interfaces:**
- Documents final implementation status and verification evidence

- [ ] **Step 1: Update rollback documents**

Keep the historical rollback explanation, but replace “재설계 대기” with a link to:

```text
docs/superpowers/specs/2026-07-25-hud-account-content-transition-design.md
docs/superpowers/plans/2026-07-25-hud-account-content-transition.md
```

State explicitly that row animation remains absent and the new implementation is whole-content buffered concealment.

- [ ] **Step 2: Run the complete test suite**

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Build and verify the development bundle**

```bash
make sign \
  CONFIGURATION=debug \
  BUILD_DIR=build-development \
  BUNDLE_ID=com.woosublee.CLIProxyManager.dev
codesign --verify --deep --strict --verbose=2 build-development/CLIProxyManager.app
```

Expected: both commands exit `0`. Do not launch either development or production app.

- [ ] **Step 4: Verify repository hygiene**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; `build-development/` remains untracked and excluded from commits.

- [ ] **Step 5: Record verification evidence in this plan**

Replace unchecked boxes with checked boxes and append the observed test count, failures, build result, and codesign result. Do not claim manual visual verification.

- [ ] **Step 6: Commit documentation**

```bash
git add docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md \
  docs/superpowers/plans/2026-07-25-hud-account-button-polish.md \
  docs/superpowers/plans/2026-07-25-hud-account-content-transition.md
git commit -m "docs: verify buffered HUD account transitions"
```

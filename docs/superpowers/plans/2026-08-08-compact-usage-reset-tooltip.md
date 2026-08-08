# Compact Usage Grouped Reset Tooltip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compact HUD의 둥근 subscription usage 카드 전체에 호버하면 모든 visible usage window의 초기화 상태를 한 multiline tooltip로 표시한다.

**Architecture:** `CompactUsagePresentation`이 subscription card 전체용 `cardTooltip`을 소유하고, 각 window를 `<label>  <reset status>` 한 줄로 변환해 줄바꿈으로 결합한다. Compact view는 padded rounded card 전체에 기존 `FastTooltip`을 적용한다. Subscription row tooltip은 비우고, API-cost presentation은 `cardTooltip == nil`과 기존 row tooltip을 유지한다.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation `Date.FormattedStyle`, XCTest, macOS 15+

## Global Constraints

- Hover target은 개별 usage 행이 아니라 둥근 subscription usage 카드 전체다.
- Tooltip은 현재 카드에 표시된 모든 subscription window를 같은 순서로 한 줄씩 표시한다.
- Timestamp line은 `<label>  <abbreviated local date and shortened local time>` 형식이다.
- `resetAt == nil` line은 사용량이 없으면 `<label>  Shown after usage starts`, 사용량이 이미 있으면 `<label>  Reset time unavailable` 형식이다.
- 특정 `five_hour` 또는 `seven_day` ID를 하드코딩하지 않는다.
- 클릭, toggle, inline expansion, HUD resize를 추가하지 않는다.
- `FastTooltip`의 공통 delay는 400밀리초로 조정하고 cancellation, popover, material, Reduce Transparency, Increase Contrast 동작은 유지한다.
- Bubble의 별도 opacity/scale transition은 제거하고 native macOS popover motion만 사용한다.
- Compact subscription row의 개별 reset tooltip은 제거한다.
- Compact API-cost row tooltip은 제거하되 Menu Bar의 기존 cost tooltip은 유지한다.
- Expanded HUD의 보이는 `Next reset: ...` 문구는 변경하지 않는다.
- 상대 시간, countdown, timer, tooltip 전용 refresh를 추가하지 않는다.
- Subscription usage API, parsing, cache, persistence, background refresh, stale-value 정책을 변경하지 않는다.
- 공개 테스트 식별자는 실제 계정 정보가 아닌 `example.com` fixture를 사용한다.
- 자동 검증은 focused/full tests, warnings-as-errors build, development app bundle 생성까지 수행한다.
- 실행 중인 프로덕션 앱과 프로덕션 CLIProxyAPI 서버를 중지, 재시작, kill, reconfigure, overwrite하지 않는다.
- Runtime 확인이 dev 인스턴스만으로 불가능하면 프로덕션에 접근하지 말고 limitation을 보고한다.
- 자동 검증 과정에서 production 또는 development 앱을 실행하지 않는다.

## Post-review Amendments

- Subscription window presentation은 row와 reset line을 한 번의 순회에서 만들고 reset 날짜를 window마다 한 번만 포맷한다.
- `resetAt == nil`은 사용 시작 전 상태를 의미하지 않을 수 있으므로 visible usage가 있으면 `Reset time unavailable`을 표시한다.
- Provider dispatcher 회귀 테스트는 파생 필드를 다시 작성하지 않고 direct subscription overload 결과와 전체 equality를 비교한다.
- Menu Bar의 `Next reset` 표시도 `subscriptionUsageResetTooltip(for:)`를 사용해 Compact·Expanded와 날짜 형식을 공유한다.
- 높이 측정용 hidden Compact tree는 tooltip text를 `nil`로 전달하고, `fastTooltip(nil)`은 stateful modifier 자체를 생성하지 않는다.
- Source contract는 임의의 직전 줄이나 `suffix(8)`에 의존하지 않고 row rendering부터 card tooltip까지의 modifier segment를 검사한다.
- All-reset-missing 동작은 clamping fixture와 mixed missing-reset 회귀 테스트가 함께 포괄하므로 중복 테스트를 유지하지 않는다.
- 공통 tooltip delay는 400밀리초로 늘리고 bubble의 별도 transition은 제거한다.
- Compact HUD는 API-cost row tooltip을 붙이지 않으며 Menu Bar는 기존 상세 tooltip을 유지한다.

## File Structure

- `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`: card-level tooltip, subscription reset-status line, Compact 전용 accessibility waiting copy, API-cost와 subscription tooltip ownership 분리를 담당한다.
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`: padded rounded subscription usage card 전체 hover target을 렌더링하고, Compact API-cost 및 hidden measurement tree의 tooltip을 비활성화한다.
- `Sources/CLIProxyManagerApp/Views/FastTooltip.swift`: nil 또는 빈 tooltip이 stateful hover/popover modifier를 만들지 않도록 한다.
- `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift`: 공유 reset tooltip helper로 Menu Bar 날짜 형식을 일치시킨다.
- `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`: ordered multiline tooltip, mixed/missing reset, stale snapshot, row tooltip 제거, accessibility를 검증한다.
- `Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift`: API-cost card tooltip은 없고 기존 row tooltip이 보존되는지 검증한다.
- `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift`: card-level FastTooltip과 row-level FastTooltip이 각각 올바른 위치에 남는 source contract를 검증한다.

---

### Task 1: Card-level reset presentation 만들기

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift:59-78, 151-173, 185-228`
- Modify: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift:5-315`
- Modify: `Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift:6-39`

**Interfaces:**
- Consumes: `subscriptionUsageDisplayLabel(for:) -> String`
- Consumes: `subscriptionUsageResetDateText(for:) -> String?`
- Produces: `CompactUsagePresentation.cardTooltip: String?`
- Produces: `CompactUsagePresentation.init(rows:placeholder:indicator:cardTooltip:)` with `cardTooltip` defaulting to `nil`
- Produces: subscription rows with `tooltip == nil`
- Produces: subscription `cardTooltip` containing one ordered line per visible window
- Produces: API-cost presentations with `cardTooltip == nil` and unchanged row tooltips
- Task 2 consumes `presentation.cardTooltip` without interpreting provider type or reset dates.

- [ ] **Step 1: Replace individual reset-tooltip expectations with one mixed multiline card-tooltip test**

In `CompactUsagePresentationTests`, replace `testSubscriptionRowsExposeIndependentResetTooltipsAndAccessibilityText` with:

```swift
func testSubscriptionCardTooltipCombinesResetAndWaitingRowsInOrder() {
    let fiveHourReset = Date(timeIntervalSince1970: 1_786_189_800)
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [
            UsageWindow(
                id: "primary",
                label: "Primary",
                usedPercent: 30,
                resetAt: fiveHourReset
            ),
            UsageWindow(
                id: "secondary",
                label: "Secondary",
                usedPercent: 0,
                resetAt: nil
            )
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let presentation = compactUsagePresentation(for: .available(snapshot))
    let resetText = fiveHourReset.formatted(date: .abbreviated, time: .shortened)

    XCTAssertEqual(
        presentation.cardTooltip,
        "5h  \(resetText)\n7d  Shown after usage starts"
    )
    XCTAssertEqual(presentation.rows.map(\.tooltip), [nil, nil])
    XCTAssertEqual(
        presentation.rows.map(\.accessibilityLabel),
        [
            "5h, 30 percent used, resets \(resetText)",
            "7d, 0 percent used, reset time shown after usage starts"
        ]
    )
}
```

This catches three realistic regressions: returning only one line, preserving individual subscription row tooltips, or dropping the waiting explanation.

- [ ] **Step 2: Update missing-reset and stale-snapshot expectations**

Replace the existing missing-reset and stale reset-tooltip tests with:

```swift
func testSubscriptionCardTooltipExplainsWhenAllResetTimesAreMissing() throws {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "claude.json",
        provider: .claude,
        windows: [
            UsageWindow(id: "five_hour", label: "5h", usedPercent: 0, resetAt: nil),
            UsageWindow(id: "seven_day", label: "7d", usedPercent: 0, resetAt: nil)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let presentation = compactUsagePresentation(for: .available(snapshot))

    XCTAssertEqual(
        presentation.cardTooltip,
        "5h  Shown after usage starts\n7d  Shown after usage starts"
    )
    XCTAssertTrue(presentation.rows.allSatisfy { $0.tooltip == nil })
    XCTAssertEqual(
        presentation.rows.map(\.accessibilityLabel),
        [
            "5h, 0 percent used, reset time shown after usage starts",
            "7d, 0 percent used, reset time shown after usage starts"
        ]
    )
}

func testStaleSnapshotRetainsGroupedResetTooltip() throws {
    let resetAt = Date(timeIntervalSince1970: 1_786_189_800)
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "codex.json",
        provider: .codex,
        windows: [
            UsageWindow(id: "primary", label: "Primary", usedPercent: 15, resetAt: resetAt)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let presentation = compactUsagePresentation(
        for: .stale(snapshot, .credentialExpired),
        now: Date(timeIntervalSince1970: 780)
    )
    let resetText = resetAt.formatted(date: .abbreviated, time: .shortened)

    XCTAssertEqual(presentation.cardTooltip, "5h  \(resetText)")
    XCTAssertNil(try XCTUnwrap(presentation.rows.first).tooltip)
    XCTAssertEqual(
        presentation.indicator,
        .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
    )
}
```

- [ ] **Step 3: Update existing nil-reset row equality expectations**

Any existing expected `CompactUsageRowPresentation` for a subscription window with `resetAt: nil` must use the Compact waiting accessibility copy. For example, update the first clamping test to:

```swift
XCTAssertEqual(
    presentation.rows,
    [
        CompactUsageRowPresentation(
            id: "primary",
            label: "5h",
            value: "0%",
            accessibilityLabel: "5h, 0 percent used, reset time shown after usage starts"
        ),
        CompactUsageRowPresentation(
            id: "secondary",
            label: "7d",
            value: "16%",
            accessibilityLabel: "7d, 16 percent used, reset time shown after usage starts"
        ),
        CompactUsageRowPresentation(
            id: "monthly",
            label: "1mo",
            value: "100%",
            accessibilityLabel: "1mo, 100 percent used, reset time shown after usage starts"
        )
    ]
)
XCTAssertEqual(
    presentation.cardTooltip,
    "5h  Shown after usage starts\n7d  Shown after usage starts\n1mo  Shown after usage starts"
)
```

Also update `testProviderUsageDispatcherPreservesSubscriptionPresentation` to expect the waiting accessibility suffix and `presentation.cardTooltip == "5h  Shown after usage starts"`.

- [ ] **Step 4: Add API-cost ownership regression assertions**

In `APICostUsagePresentationTests.testCompactPresentationPreservesExactTooltipsForZeroTinyAndNormalCosts`, add:

```swift
XCTAssertNil(presentation.cardTooltip)
```

Keep the existing assertions that every Day row tooltip contains exact estimate, UTC/time-zone, and estimated API-cost copy. This proves API-cost detail remains row-owned.

- [ ] **Step 5: Run focused tests to verify RED**

Run:

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter APICostUsagePresentationTests/testCompactPresentationPreservesExactTooltipsForZeroTinyAndNormalCosts
```

Expected:

- Compile failure because `CompactUsagePresentation` has no `cardTooltip`.
- After compilation is restored only by the later implementation, old subscription row tooltips and missing waiting accessibility would also violate the new assertions.

- [ ] **Step 6: Add `cardTooltip` to `CompactUsagePresentation`**

Replace the current stored-property section and implicit initializer with:

```swift
struct CompactUsagePresentation: Equatable {
    let rows: [CompactUsageRowPresentation]
    let placeholder: String?
    let indicator: CompactUsageIndicator?
    let cardTooltip: String?

    init(
        rows: [CompactUsageRowPresentation],
        placeholder: String?,
        indicator: CompactUsageIndicator?,
        cardTooltip: String? = nil
    ) {
        self.rows = rows
        self.placeholder = placeholder
        self.indicator = indicator
        self.cardTooltip = cardTooltip
    }

    var headerIndicator: CompactUsageIndicator? {
        rows.isEmpty ? nil : indicator
    }

    var placeholderIndicator: CompactUsageIndicator? {
        rows.isEmpty ? indicator : nil
    }

    static func placeholder(
        _ value: String,
        indicator: CompactUsageIndicator
    ) -> CompactUsagePresentation {
        CompactUsagePresentation(rows: [], placeholder: value, indicator: indicator)
    }
}
```

The default argument preserves placeholder and API-cost construction sites until they are explicitly verified.

- [ ] **Step 7: Add a shared Compact window presentation**

Immediately above `compactSnapshotPresentation`, add one helper that formats each reset timestamp once and produces both the row and tooltip line:

```swift
private let compactUsageResetWaitingText = "Shown after usage starts"
private let compactUsageResetUnavailableText = "Reset time unavailable"

private struct CompactUsageWindowPresentation {
    let row: CompactUsageRowPresentation
    let resetLine: String
}

private func compactUsageWindowPresentation(
    for window: UsageWindow
) -> CompactUsageWindowPresentation {
    let percent = min(max(window.usedPercent, 0), 100)
    let rounded = Int(percent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    let resetText = subscriptionUsageResetDateText(for: window)

    let resetStatus: String
    let accessibilityLabel: String
    if let resetText {
        resetStatus = resetText
        accessibilityLabel = "\(label), \(rounded) percent used, resets \(resetText)"
    } else if window.usedPercent <= 0 {
        resetStatus = compactUsageResetWaitingText
        accessibilityLabel = "\(label), \(rounded) percent used, reset time shown after usage starts"
    } else {
        resetStatus = compactUsageResetUnavailableText
        accessibilityLabel = "\(label), \(rounded) percent used, reset time unavailable"
    }

    return CompactUsageWindowPresentation(
        row: CompactUsageRowPresentation(
            id: window.id,
            label: label,
            value: "\(rounded)%",
            accessibilityLabel: accessibilityLabel
        ),
        resetLine: "\(label)  \(resetStatus)"
    )
}
```

Keep the waiting and unavailable copy scoped to Compact presentation. Do not change Menu Bar or Expanded HUD accessibility for nil reset timestamps.

- [ ] **Step 8: Move subscription reset ownership from rows to card**

Change `compactSnapshotPresentation` to make one window-presentation pass, then derive rows and the joined card tooltip from those results:

```swift
let windowPresentations = snapshot.windows.map(compactUsageWindowPresentation(for:))
let rows = windowPresentations.map(\.row)
let indicator = warning.map { issue in
    CompactUsageIndicator.warning(
        message: SubscriptionUsageWarningPresentation.message(
            issue: issue,
            lastUpdatedAt: snapshot.fetchedAt,
            now: now
        )
    )
}
let cardTooltip = windowPresentations
    .map(\.resetLine)
    .joined(separator: "\n")
return CompactUsagePresentation(
    rows: rows,
    placeholder: nil,
    indicator: indicator,
    cardTooltip: cardTooltip
)
```

Do not change `compactAPICostSnapshotPresentation`; its default `cardTooltip` remains `nil`, and its row detail data remains available for Menu Bar and other non-Compact consumers.

- [ ] **Step 9: Run presentation tests to verify GREEN**

Run:

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter APICostUsagePresentationTests
swift test --filter MenuBarStatusSnapshotTests
```

Expected: grouped reset, waiting and unavailable copy, stale snapshot, preserved API-cost row detail data, and shared accessibility tests all pass with 0 failures.

- [ ] **Step 10: Commit Task 1**

```bash
git add \
  Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift \
  Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift \
  Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift
git commit -m "feat: group compact reset tooltip content" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Apply FastTooltip to the complete usage card

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:137-164`
- Modify: `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift:33-49`

**Interfaces:**
- Consumes: Task 1 `CompactUsagePresentation.cardTooltip: String?`
- Consumes: existing `View.fastTooltip(_:edge:delay:)`
- Produces: padded rounded subscription card with one card-level tooltip target
- Preserves: `CompactUsageRowPresentation.tooltip` data for Menu Bar and other non-Compact consumers without attaching it in Compact HUD

- [ ] **Step 1: Replace the old whole-row source contract with card ownership contracts**

Replace `testCompactUsageTooltipIsAttachedToWholeRow` in `FastTooltipMigrationTests` with tests that locate the closing brace of the row `ForEach`, inspect only the following card modifiers, and verify Compact omits API-cost row tooltips while Menu Bar keeps them:

```swift
func testCompactUsageCardOwnsGroupedResetTooltip() throws {
    let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
    let rowsRange = try XCTUnwrap(compact.range(of: "ForEach(presentation.rows) { row in"))
    let openingBrace = try XCTUnwrap(compact[rowsRange].firstIndex(of: "{"))
    let closingBrace = try XCTUnwrap(
        matchingClosingBrace(in: compact, openingBrace: openingBrace)
    )
    let cardModifierStart = compact.index(after: closingBrace)
    let tooltipRange = try XCTUnwrap(
        compact.range(
            of: ".fastTooltip(tooltipsEnabled ? presentation.cardTooltip : nil)",
            range: cardModifierStart..<compact.endIndex
        )
    )
    let cardSegment = String(compact[cardModifierStart..<tooltipRange.upperBound])

    XCTAssertTrue(cardSegment.contains(".padding(.horizontal, 7)"))
    XCTAssertTrue(cardSegment.contains(".padding(.vertical, 7)"))
    XCTAssertTrue(cardSegment.contains(".background(.primary.opacity(0.055)"))
    XCTAssertTrue(cardSegment.contains(".contentShape(Rectangle())"))
}

func testCompactOmitsAPICostRowTooltipWhileMenuBarKeepsIt() throws {
    let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
    let menuBar = try appSource(relativePath: "Views/MenuBarStatusView.swift")

    XCTAssertFalse(compact.contains("row.tooltip"))
    XCTAssertTrue(menuBar.contains(".fastTooltip(row.tooltip)"))
}
```

Add a small brace-matching test helper so the grouped-card assertions cannot accidentally inspect row modifiers.

- [ ] **Step 2: Run source contract tests to verify RED**

Run:

```bash
swift test --filter FastTooltipMigrationTests/testCompactUsageCardOwnsGroupedResetTooltip
swift test --filter FastTooltipMigrationTests/testCompactOmitsAPICostRowTooltipWhileMenuBarKeepsIt
```

Expected:

- The grouped card test fails because the complete padded card does not yet own `cardTooltip`.
- The API-cost contract fails because Compact still contains `.fastTooltip(row.tooltip)`.

- [ ] **Step 3: Move grouped reset hover to the padded rounded card**

Remove the row-level tooltip modifier from Compact HUD and attach only the aggregate tooltip to the complete padded card:

```swift
VStack(spacing: 5) {
    ForEach(presentation.rows) { row in
        HStack(spacing: 4) {
            Text(row.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(row.value)
                .foregroundStyle(.primary)
                .lineLimit(row.textLayout.lineLimit)
                .minimumScaleFactor(row.textLayout.minimumScaleFactor)
                .allowsTightening(true)
                .layoutPriority(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}
.padding(.horizontal, 7)
.padding(.vertical, 7)
.background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
.contentShape(Rectangle())
.fastTooltip(tooltipsEnabled ? presentation.cardTooltip : nil)
```

Pass `tooltipsEnabled: false` from `measurementAccountStack` and `true` from `visibleAccountStack`. API-cost rows retain their detail data in the presentation model, but Compact HUD does not attach it; Menu Bar continues to use `.fastTooltip(row.tooltip)`.

- [ ] **Step 4: Run grouped hover and tooltip regression tests**

Run:

```bash
swift test --filter FastTooltipMigrationTests
swift test --filter CompactUsagePresentationTests
swift test --filter APICostUsagePresentationTests
swift test --filter FastTooltipTests
```

Expected: card-level source contract, Compact API-cost omission with Menu Bar preservation, grouped content, and existing FastTooltip behavior pass with 0 failures.

- [ ] **Step 5: Commit Task 2**

```bash
git add \
  Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift \
  Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift
git commit -m "feat: expand reset tooltip to usage card" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Verify regressions without touching production runtime

**Files:**
- Verify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`
- Verify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Verify: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Verify: `Tests/CLIProxyManagerAppTests/APICostUsagePresentationTests.swift`
- Verify: `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift`
- Verify: `docs/superpowers/specs/2026-08-08-compact-usage-reset-tooltip-design.md`
- Modify: `docs/superpowers/plans/2026-08-08-compact-usage-reset-tooltip.md` only to mark completed checkboxes if the execution workflow records progress in-file

**Interfaces:**
- Verifies: one ordered multiline subscription card tooltip, waiting and unavailable copy, stale preservation, Compact API-cost tooltip omission with Menu Bar preservation, whole-card hover target, accessibility
- Produces: structurally verified development app bundle
- Prohibits: commands that stop, restart, kill, reconfigure, or overwrite production app/server/data

- [ ] **Step 1: Run all focused tests**

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter APICostUsagePresentationTests
swift test --filter FastTooltipMigrationTests
swift test --filter FastTooltipTests
swift test --filter MenuBarStatusSnapshotTests
```

Expected: every command selects tests and passes with 0 failures.

- [ ] **Step 2: Run warnings-as-errors build and complete regression suite**

```bash
make ci-build
swift test
git diff --check
```

Expected:

- `make ci-build` succeeds with `-warnings-as-errors`.
- Full XCTest suite passes with 0 failures.
- `git diff --check` exits 0 without output.

- [ ] **Step 3: Verify change scope statically**

```bash
git diff --name-only main...HEAD
rg -n "cardTooltip|Shown after usage starts|fastTooltip\(presentation\.cardTooltip\)|fastTooltip\(row\.tooltip\)" \
  Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift \
  Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift
git status --short
```

Expected:

- Grouped reset changes are limited to App presentation/view tests and design/plan documents.
- `Sources/CLIProxyManagerCore`, quota client, cache, scheduler, config, process control, and server lifecycle files are absent from the new grouped-hover diff.
- Both card-level and row-level tooltip modifiers are present for their separate ownership roles.

- [ ] **Step 4: Build and structurally verify a development bundle only**

```bash
make development-bundle BUILD_DIR=build/compact-reset-tooltip-dev
```

Expected:

```text
build/compact-reset-tooltip-dev/CLIProxyManager.app
App structure verification passed
```

Do not run `open`, `pkill`, `kill`, `cpm stop`, `cpm start`, `cpm restart`, server-control UI automation, or any command targeting the production app or production port.

- [ ] **Step 5: Commit the updated implementation plan**

```bash
git add docs/superpowers/plans/2026-08-08-compact-usage-reset-tooltip.md
git commit -m "docs: update grouped reset tooltip plan" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git status --short
```

Expected: the plan update is committed and the worktree is clean. Do not include generated build artifacts.

- [ ] **Step 6: Report the dev bundle and manual checks without launching it**

Report this bundle path:

```text
build/compact-reset-tooltip-dev/CLIProxyManager.app
```

Ask the user to verify manually:

1. Hovering the label, percentage, blank column space, row gap, or internal card padding shows the same grouped tooltip.
2. A typical `5h` and `7d` account displays two lines at once.
3. Claude windows with `resets_at: null` display `Shown after usage starts` at 0% usage and `Reset time unavailable` after usage begins.
4. A timestamp supplied by Codex or Claude uses the same local absolute time as Expanded HUD.
5. API-cost Day/Mon rows show no tooltip in Compact HUD, while Menu Bar retains the detail tooltip.
6. Light/Dark appearance and tooltip clipping remain correct.
7. The production app and production server continue running without interruption.

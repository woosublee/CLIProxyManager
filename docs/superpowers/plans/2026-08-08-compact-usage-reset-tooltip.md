# Compact Usage Reset Tooltip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compact HUD의 subscription usage 행 전체에 호버하면 해당 window의 다음 초기화 절대 시각을 기존 fast tooltip으로 표시한다.

**Architecture:** 기존 `UsageWindow.resetAt`을 공유 presentation helper에서 로컬 절대 시각 문자열로 변환한다. Compact subscription presentation은 이 문자열을 tooltip과 VoiceOver label에 넣고, Compact HUD view는 tooltip modifier를 퍼센트 `Text`가 아니라 행 `HStack` 전체에 적용한다. API, cache, refresh, timer에는 손대지 않는다.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation `Date.FormattedStyle`, XCTest, macOS 15+

## Global Constraints

- Tooltip 문구는 `Next reset: <abbreviated local date and shortened local time>` 형식이다.
- 날짜는 `Date.formatted(date: .abbreviated, time: .shortened)`로 현재 locale과 time zone을 따른다.
- 상대 시간, countdown, timer, 주기적 tooltip 갱신을 추가하지 않는다.
- `resetAt == nil`이면 tooltip은 `nil`이며 기존 accessibility label을 유지한다.
- 특정 `five_hour` 또는 `seven_day` ID를 하드코딩하지 않고, `resetAt`이 있는 모든 subscription usage window에 적용한다.
- Expanded HUD의 보이는 문구와 형식은 변경하지 않는다.
- Compact API-cost row의 기존 tooltip 내용은 변경하지 않는다.
- 기존 `FastTooltip`의 120밀리초 지연, material, Reduce Motion, Reduce Transparency, Increase Contrast 동작은 변경하지 않는다.
- Subscription usage API, parsing, cache persistence, background refresh, stale-value 정책을 변경하지 않는다.
- 공개 테스트 식별자는 실제 계정 정보가 아닌 `example.com` fixture를 사용한다.
- 자동 검증은 전체 `swift test`와 development app bundle 생성까지 수행하고, 앱 실행 및 수동 UI 확인은 사용자가 담당한다.

## File Structure

- `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift`: subscription usage label, reset date formatting, tooltip 문구, accessibility 문구의 단일 기준을 소유한다.
- `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`: `UsageWindow`를 Compact HUD row presentation으로 변환하며 tooltip과 clamp된 퍼센트 기반 accessibility label을 채운다.
- `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`: Expanded HUD가 공유 reset tooltip 문구를 사용하되 보이는 결과는 유지한다.
- `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`: Compact usage row 전체의 hover hit area와 `fastTooltip` 연결을 소유한다.
- `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`: reset tooltip, nil reset, stale snapshot, window별 독립 문구를 검증한다.
- `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift`: `fastTooltip(row.tooltip)`이 퍼센트 text가 아닌 행 container에 연결되는 source contract를 검증한다.

---

### Task 1: Subscription reset presentation 만들기

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift:32-60`
- Modify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift:185-224`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift:408-434`
- Modify: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift:5-225`

**Interfaces:**
- Consumes: `UsageWindow.resetAt: Date?`, `UsageWindow.usedPercent: Double`, `subscriptionUsageDisplayLabel(for:) -> String`
- Produces: `subscriptionUsageResetDateText(for:) -> String?`
- Produces: `subscriptionUsageResetTooltip(for:) -> String?`
- Produces: `subscriptionUsageAccessibilityLabel(for:usedPercent:) -> String`이며 `usedPercent` 기본값은 `nil`이라 기존 호출이 그대로 동작한다.
- Produces: Compact subscription rows whose `tooltip` and `accessibilityLabel` include the same reset timestamp.
- Task 2 consumes the populated `CompactUsageRowPresentation.tooltip` without interpreting dates.

- [ ] **Step 1: reset 정보가 있는 여러 window의 실패 테스트 작성**

`CompactUsagePresentationTests`에 다음 테스트를 추가한다. 예상 문자열도 production과 같은 시스템 locale/time zone에서 계산하되, 최종 조합 문구 전체를 비교해 `resetAt` 전달과 prefix를 함께 검증한다.

```swift
func testSubscriptionRowsExposeIndependentResetTooltipsAndAccessibilityText() {
    let fiveHourReset = Date(timeIntervalSince1970: 1_786_189_800)
    let sevenDayReset = Date(timeIntervalSince1970: 1_786_449_600)
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
                usedPercent: 12,
                resetAt: sevenDayReset
            )
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let rows = compactUsagePresentation(for: .available(snapshot)).rows
    let fiveHourText = fiveHourReset.formatted(date: .abbreviated, time: .shortened)
    let sevenDayText = sevenDayReset.formatted(date: .abbreviated, time: .shortened)

    XCTAssertEqual(
        rows,
        [
            CompactUsageRowPresentation(
                id: "primary",
                label: "5h",
                value: "30%",
                accessibilityLabel: "5h, 30 percent used, resets \(fiveHourText)",
                tooltip: "Next reset: \(fiveHourText)"
            ),
            CompactUsageRowPresentation(
                id: "secondary",
                label: "7d",
                value: "12%",
                accessibilityLabel: "7d, 12 percent used, resets \(sevenDayText)",
                tooltip: "Next reset: \(sevenDayText)"
            )
        ]
    )
}
```

- [ ] **Step 2: nil reset과 stale snapshot의 실패 테스트 작성**

동일 test class에 다음 두 테스트를 추가한다.

```swift
func testSubscriptionRowWithoutResetKeepsExistingAccessibilityAndNoTooltip() throws {
    let snapshot = SubscriptionUsageSnapshot(
        profileID: "claude.json",
        provider: .claude,
        windows: [
            UsageWindow(id: "primary", label: "Primary", usedPercent: 25, resetAt: nil)
        ],
        fetchedAt: Date(timeIntervalSince1970: 60)
    )

    let row = try XCTUnwrap(compactUsagePresentation(for: .available(snapshot)).rows.first)

    XCTAssertEqual(row.accessibilityLabel, "5h, 25 percent used")
    XCTAssertNil(row.tooltip)
}

func testStaleSnapshotRetainsLastSuccessfulResetTooltip() throws {
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
    let row = try XCTUnwrap(presentation.rows.first)
    let resetText = resetAt.formatted(date: .abbreviated, time: .shortened)

    XCTAssertEqual(row.tooltip, "Next reset: \(resetText)")
    XCTAssertEqual(row.accessibilityLabel, "5h, 15 percent used, resets \(resetText)")
    XCTAssertEqual(
        presentation.indicator,
        .warning(message: "Credential needs attention. Showing usage last updated 12 minutes ago.")
    )
}
```

- [ ] **Step 3: focused test를 실행해 RED 확인**

Run:

```bash
swift test --filter CompactUsagePresentationTests
```

Expected: 새 reset fixture가 있는 row의 `tooltip`이 `nil`이고 accessibility label에 `resets ...`가 없어 실패한다. 기존 nil-reset assertion은 계속 통과한다.

- [ ] **Step 4: 공유 reset formatting helper 구현**

`SubscriptionUsageProgressPresentation.swift`에서 `subscriptionUsageDisplayLabel(for:)` 아래에 다음 helper를 추가하고, 기존 accessibility helper가 optional override를 받도록 바꾼다.

```swift
func subscriptionUsageResetDateText(for window: UsageWindow) -> String? {
    guard let resetAt = window.resetAt else { return nil }
    return resetAt.formatted(date: .abbreviated, time: .shortened)
}

func subscriptionUsageResetTooltip(for window: UsageWindow) -> String? {
    subscriptionUsageResetDateText(for: window).map { "Next reset: \($0)" }
}

func subscriptionUsageAccessibilityLabel(
    for window: UsageWindow,
    usedPercent: Int? = nil
) -> String {
    let used = usedPercent ?? Int(window.usedPercent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    guard let resetText = subscriptionUsageResetDateText(for: window) else {
        return "\(label), \(used) percent used"
    }
    return "\(label), \(used) percent used, resets \(resetText)"
}
```

기본 parameter 때문에 `MenuBarStatusView`와 Expanded HUD의 기존 `subscriptionUsageAccessibilityLabel(for:)` 호출은 수정하지 않는다.

- [ ] **Step 5: Compact subscription row에 tooltip과 accessibility 문구 연결**

`compactSnapshotPresentation`의 row mapping을 다음처럼 변경한다. Compact HUD에서 표시한 0~100 clamp 결과와 VoiceOver 숫자가 계속 일치하도록 `rounded`를 명시적으로 전달한다.

```swift
let rows = snapshot.windows.map { window in
    let percent = min(max(window.usedPercent, 0), 100)
    let rounded = Int(percent.rounded())
    let label = subscriptionUsageDisplayLabel(for: window)
    return CompactUsageRowPresentation(
        id: window.id,
        label: label,
        value: "\(rounded)%",
        accessibilityLabel: subscriptionUsageAccessibilityLabel(
            for: window,
            usedPercent: rounded
        ),
        tooltip: subscriptionUsageResetTooltip(for: window)
    )
}
```

특정 window ID 조건문은 추가하지 않는다.

- [ ] **Step 6: Expanded HUD를 공유 tooltip 문구에 연결**

`ExpandedUsageOverlayProgressRow`의 reset block을 다음으로 교체한다. 출력은 기존과 동일하고 formatting 기준만 helper로 통합된다.

```swift
if let resetTooltip = subscriptionUsageResetTooltip(for: window) {
    Text(resetTooltip)
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .padding(.leading, 36)
}
```

- [ ] **Step 7: presentation 테스트를 GREEN으로 확인**

Run:

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter MenuBarStatusSnapshotTests
```

Expected: Compact reset tooltip, nil reset, stale snapshot, 기존 progress accessibility 테스트가 모두 선택되어 0 failures로 통과한다.

- [ ] **Step 8: Task 1 커밋**

```bash
git add \
  Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift \
  Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift \
  Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift \
  Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift
git commit -m "feat: add compact usage reset tooltips" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Compact usage 행 전체를 hover target으로 만들기

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift:140-158`
- Modify: `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift:19-48`

**Interfaces:**
- Consumes: Task 1이 채운 `CompactUsageRowPresentation.tooltip: String?`
- Consumes: 기존 `View.fastTooltip(_:edge:delay:)`
- Produces: label, spacer, value를 포함하는 usage-row `HStack` 전체의 rectangular hover target
- Preserves: Compact API-cost row의 기존 tooltip 문자열과 accessibility label

- [ ] **Step 1: row-level tooltip source contract 실패 테스트 작성**

`FastTooltipMigrationTests`에 다음 테스트를 추가한다. modifier chain을 확인해 tooltip이 value `Text`에 남는 회귀도 함께 막는다.

```swift
func testCompactUsageTooltipIsAttachedToWholeRow() throws {
    let compact = try appSource(relativePath: "Views/CompactUsageOverlayView.swift")
    let rowLevelContract = """
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .contentShape(Rectangle())
                        .fastTooltip(row.tooltip)
                        .accessibilityElement(children: .ignore)
    """
    let valueLevelContract = """
                                .layoutPriority(1)
                                .fastTooltip(row.tooltip)
    """

    XCTAssertTrue(compact.contains(rowLevelContract))
    XCTAssertFalse(compact.contains(valueLevelContract))
}
```

- [ ] **Step 2: source contract test를 실행해 RED 확인**

Run:

```bash
swift test --filter FastTooltipMigrationTests/testCompactUsageTooltipIsAttachedToWholeRow
```

Expected: row-level modifier chain이 없고 value-level `fastTooltip`이 남아 있어 실패한다.

- [ ] **Step 3: tooltip modifier를 usage-row container로 이동**

`CompactUsageOverlayView`의 usage row modifier 순서를 다음처럼 바꾼다. `Text(row.value)`의 `.fastTooltip(row.tooltip)`은 제거한다.

```swift
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
.contentShape(Rectangle())
.fastTooltip(row.tooltip)
.accessibilityElement(children: .ignore)
.accessibilityLabel(row.accessibilityLabel)
```

`contentShape(Rectangle())`는 보이지 않는 새 surface를 추가하지 않고 현재 HStack bounds 전체를 hover 영역으로 만든다.

- [ ] **Step 4: tooltip migration과 compact presentation 테스트를 GREEN으로 확인**

Run:

```bash
swift test --filter FastTooltipMigrationTests
swift test --filter CompactUsagePresentationTests
swift test --filter FastTooltipTests
```

Expected: row-level source contract, 기존 tooltip migration, reset presentation, 기존 120ms tooltip contract가 모두 0 failures로 통과한다.

- [ ] **Step 5: Task 2 커밋**

```bash
git add \
  Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift \
  Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift
git commit -m "feat: expand compact usage tooltip target" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 전체 회귀 검증과 development bundle 생성

**Files:**
- Verify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift`
- Verify: `Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift`
- Verify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Verify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Verify: `Tests/CLIProxyManagerAppTests/CompactUsagePresentationTests.swift`
- Verify: `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift`
- Verify: `docs/superpowers/specs/2026-08-08-compact-usage-reset-tooltip-design.md`

**Interfaces:**
- Verifies: reset tooltip 문구, nil-reset 처리, stale snapshot 유지, row-level hover target, accessibility 문구, 기존 FastTooltip contract
- Produces: 사용자가 수동 hover 확인에 사용할 structurally verified development app bundle

- [ ] **Step 1: 모든 관련 focused test 실행**

```bash
swift test --filter CompactUsagePresentationTests
swift test --filter FastTooltipMigrationTests
swift test --filter FastTooltipTests
swift test --filter MenuBarStatusSnapshotTests
```

Expected: 각 명령이 실제 test를 선택하고 모두 0 failures로 통과한다.

- [ ] **Step 2: CI debug build와 전체 test suite 실행**

```bash
make ci-build
swift test
git diff --check
```

Expected: warnings-as-errors debug build가 성공하고, 전체 XCTest suite가 0 failures로 통과하며, `git diff --check`는 출력 없이 exit 0이다.

- [ ] **Step 3: 변경 범위 정적 확인**

```bash
git diff --name-only main...HEAD
git status --short
rg -n "subscriptionUsageResetTooltip|fastTooltip\(row\.tooltip\)|contentShape\(Rectangle\(\)\)" \
  Sources/CLIProxyManagerApp/Views/SubscriptionUsageProgressPresentation.swift \
  Sources/CLIProxyManagerApp/Models/CompactUsagePresentation.swift \
  Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift \
  Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift
```

Expected:

- 변경된 production code는 App presentation/view 파일에 한정된다.
- `Sources/CLIProxyManagerCore`, quota client, cache, scheduler 파일은 변경 목록에 없다.
- plan 문서가 아직 untracked라면 `git status --short`에 이 plan 파일만 추가로 보일 수 있다.
- reset helper는 Compact presentation과 Expanded HUD에서 사용되고, row tooltip은 `contentShape(Rectangle())`가 있는 HStack modifier chain에 존재한다.

- [ ] **Step 4: development app bundle 생성 및 구조 검증**

```bash
make development-bundle BUILD_DIR=build/compact-reset-tooltip-dev
```

Expected: command가 exit 0이고 다음 bundle이 생성된다.

```text
build/compact-reset-tooltip-dev/CLIProxyManager.app
```

`development-bundle`은 development release marker를 포함한 debug bundle을 만들고 `scripts/verify-app-structure.sh` 검증까지 실행한다. 앱은 자동 실행하지 않는다.

- [ ] **Step 5: plan 문서를 커밋하고 최종 상태 확인**

```bash
git add docs/superpowers/plans/2026-08-08-compact-usage-reset-tooltip.md
git commit -m "docs: add compact reset tooltip plan" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git status --short
```

Expected: plan 문서가 별도 documentation commit으로 기록되고 `git status --short`가 출력 없이 clean이다.

- [ ] **Step 6: 사용자 수동 검증 항목 전달**

다음 bundle path와 확인 항목을 사용자에게 전달한다. 프로젝트 지침에 따라 앱 실행은 수행하지 않는다.

```text
build/compact-reset-tooltip-dev/CLIProxyManager.app
```

수동 확인 항목:

1. Compact HUD에서 `5h` 행의 label, 빈 공간, 퍼센트 어느 위치에 hover해도 120ms 뒤 `Next reset: ...` tooltip이 보인다.
2. `7d` 행도 자신의 reset 시각을 독립적으로 표시한다.
3. Expanded HUD의 `Next reset: ...` 문구와 Compact tooltip 시각이 동일하다.
4. reset 정보가 없는 행에는 빈 tooltip이 나타나지 않는다.
5. Light/Dark mode에서 tooltip이 읽히고 HUD bounds에 잘리지 않는다.
6. VoiceOver가 reset 정보가 있는 행에서 사용률과 reset 시각을 함께 읽는다.

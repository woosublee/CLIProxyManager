# Command Badge Layout Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메인 계정 카드의 command badge를 Usage HUD 버튼 바로 왼쪽에 한 줄로 배치하고, 좁은 폭에서도 세로 줄바꿈이 발생하지 않게 한다.

**Architecture:** `ProviderAccountCardView`의 유연한 계정 정보 영역과 trailing controls를 분리한다. 재사용되는 `SlugPill` 자체에 단일 행·말줄임 계약을 추가하고, 카드에서는 `SlugPill`과 기존 `actions`를 새 `trailingControls`로 묶는다.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, Swift Package Manager, Make

## Global Constraints

- 지원 플랫폼은 `macOS 15.0` 이상을 유지한다.
- `AppWindowMetrics.mainWidth`는 `380pt`를 유지한다.
- HUD·설정·더보기 버튼의 `26×26` interaction target을 유지한다.
- Usage HUD 저장 동작, command 복사 동작, hover·copied feedback을 변경하지 않는다.
- Connected, Disabled, Disconnected별 기존 action 순서와 동작을 유지한다.
- production 앱은 실행·종료·활성화하지 않는다.
- 자동 검증은 `CONFIGURATION=debug` development app bundle과 codesign verification까지 수행한다.
- subagent는 사용자가 명시적으로 동의한 경우에만 사용한다.
- 구현 commit은 사용자가 실행 방식을 승인하면서 단계별 commit을 허용한 경우에만 생성한다.

---

## File Structure

- Create: `Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`
  - command badge의 단일 행 계약과 계정 카드 내 trailing 배치를 source-contract 방식으로 검증한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift`
  - 재사용 가능한 `SlugPill`의 command 텍스트가 한 줄에서 말줄임되도록 한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - 계정 정보 영역에서 `SlugPill`을 제거하고 HUD 버튼 왼쪽의 `trailingControls`로 이동한다.

---

### Task 1: `SlugPill` 단일 행 계약

**Files:**
- Create: `Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift:98-109`

**Interfaces:**
- Consumes: `SlugPill.init(slug:onCopy:)`
- Produces: `SlugPill` 내부 `Text(slug)`의 `.lineLimit(1)` 및 `.truncationMode(.tail)` 계약

- [ ] **Step 1: command 텍스트 단일 행 회귀 테스트 작성**

`Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`를 다음 내용으로 생성한다.

```swift
import Foundation
import XCTest

final class DashboardCommandBadgeLayoutUITests: XCTestCase {
    func testSlugPillKeepsCommandTextOnOneLine() throws {
        let slugPill = try sourceSection(
            in: designChromeSource(),
            after: "struct SlugPill: View {",
            before: "\n}\n\n// MARK: - Provider avatar"
        )
        let commandText = try sourceSection(
            in: slugPill,
            after: "Text(slug)",
            before: "Image(systemName:"
        )

        XCTAssertTrue(commandText.contains(".lineLimit(1)"))
        XCTAssertTrue(commandText.contains(".truncationMode(.tail)"))
    }

    private func dashboardSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DashboardView.swift")
    }

    private func designChromeSource() throws -> String {
        try source(at: "Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift")
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
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

- [ ] **Step 2: 새 테스트가 현재 구현에서 실패하는지 확인**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests/testSlugPillKeepsCommandTextOnOneLine
```

Expected: FAIL. `DesignChromeViews.swift`의 `Text(slug)` 구간에 `.lineLimit(1)`과 `.truncationMode(.tail)`이 없다는 assertion이 실패해야 한다.

- [ ] **Step 3: `SlugPill`에 최소 단일 행 구현 추가**

`Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift`의 `Text(slug)`에 다음 modifier를 추가한다.

```swift
Text(slug)
    .foregroundStyle(.primary.opacity(hovering ? 1.0 : 0.78))
    .lineLimit(1)
    .truncationMode(.tail)
```

`HStack`, padding, background, overlay, copy action, hover와 copied 상태는 변경하지 않는다.

- [ ] **Step 4: 단일 행 회귀 테스트 통과 확인**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests/testSlugPillKeepsCommandTextOnOneLine
```

Expected: PASS, 1 test, 0 failures.

- [ ] **Step 5: 단일 행 변경 commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift \
  Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift
git commit -m "fix: keep command badge on one line" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: command badge를 HUD 버튼 왼쪽으로 이동

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:654-677`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:712`

**Interfaces:**
- Consumes: Task 1의 `SlugPill` 단일 행 계약, 기존 `actions: some View`
- Produces: `ProviderAccountCardView.trailingControls: some View`
- Layout order: `SlugPill(slug: account.commandName)` → `actions`

- [ ] **Step 1: trailing controls 배치 회귀 테스트 추가**

`DashboardCommandBadgeLayoutUITests`에 다음 test method를 추가한다.

```swift
func testDashboardMovesCommandBadgeBeforeAccountActions() throws {
    let providerCard = try sourceSection(
        in: dashboardSource(),
        after: "private struct ProviderAccountCardView: View {",
        before: "private struct ProviderAccountDragPreview: View"
    )
    let cardBody = try sourceSection(
        in: providerCard,
        after: "var body: some View {",
        before: "private var trailingControls: some View {"
    )
    let accountInfo = try sourceSection(
        in: cardBody,
        after: "VStack(alignment: .leading, spacing: 4) {",
        before: "\n\n            trailingControls"
    )
    let trailingControls = try sourceSection(
        in: providerCard,
        after: "private var trailingControls: some View {",
        before: "\n    }\n\n    private var dragHandle"
    )

    XCTAssertFalse(accountInfo.contains("SlugPill(slug: account.commandName)"))

    let badgeRange = try XCTUnwrap(
        trailingControls.range(of: "SlugPill(slug: account.commandName)")
    )
    let actionsRange = try XCTUnwrap(trailingControls.range(of: "actions"))
    XCTAssertLessThan(
        trailingControls.distance(from: trailingControls.startIndex, to: badgeRange.lowerBound),
        trailingControls.distance(from: trailingControls.startIndex, to: actionsRange.lowerBound)
    )
    XCTAssertTrue(trailingControls.contains(".layoutPriority(1)"))
}
```

- [ ] **Step 2: trailing controls 테스트가 현재 구현에서 실패하는지 확인**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests/testDashboardMovesCommandBadgeBeforeAccountActions
```

Expected: FAIL. 현재 `ProviderAccountCardView`에는 `trailingControls` property가 없으므로 source marker를 찾지 못해야 한다.

- [ ] **Step 3: 계정 정보와 trailing controls를 분리**

`ProviderAccountCardView.body`에서 현재 계정 정보와 `actions` 배치를 다음 구조로 교체한다.

```swift
VStack(alignment: .leading, spacing: 4) {
    Text(account.title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)

    accountDetailRow
        .padding(.top, 2)
}
.frame(maxWidth: .infinity, alignment: .leading)

trailingControls
```

다음 기존 요소는 제거한다.

```swift
HStack(spacing: 6) {
    Text(account.title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
    SlugPill(slug: account.commandName)
    Spacer(minLength: 0)
}
```

또한 계정 정보 `VStack`과 `actions` 사이에 있던 다음 spacer를 제거한다.

```swift
Spacer(minLength: 4)
```

- [ ] **Step 4: HUD 버튼 왼쪽에 command badge를 배치**

`ProviderAccountCardView`의 `body` 다음, `dragHandle` 이전에 다음 property를 추가한다.

```swift
private var trailingControls: some View {
    HStack(spacing: 4) {
        SlugPill(slug: account.commandName)
            .layoutPriority(1)

        actions
    }
}
```

`actions` 내부의 Connected, Disabled, Disconnected branch는 변경하지 않는다. 각 branch의 첫 항목은 계속 `usageOverlayButton`이어야 한다.

- [ ] **Step 5: command badge 레이아웃 테스트 통과 확인**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests
```

Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 6: 기존 Usage HUD 액션 계약 회귀 확인**

Run:

```bash
swift test --filter UsageOverlayAccountVisibilityUITests
```

Expected: PASS, 3 tests, 0 failures. 모든 account status branch의 HUD 버튼과 26×26 interaction target이 유지되어야 한다.

- [ ] **Step 7: trailing 배치 변경 commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift
git commit -m "fix: align command badge with account actions" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 전체 회귀 및 development bundle 검증

**Files:**
- Verify only: `Package.swift`
- Verify only: `Makefile`
- Verify only: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Verify only: `Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift`
- Verify only: `Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`

**Interfaces:**
- Consumes: Task 1과 Task 2의 최종 source 및 test 상태
- Produces: 전체 test suite와 development app bundle의 검증 근거

- [ ] **Step 1: command badge와 HUD 관련 targeted tests 재실행**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests
swift test --filter UsageOverlayAccountVisibilityUITests
```

Expected: 두 명령 모두 PASS, 합계 5 tests, 0 failures.

- [ ] **Step 2: 전체 Swift test suite 실행**

Run:

```bash
swift test
```

Expected: 전체 Swift test suite가 0 failures로 통과한다.

- [ ] **Step 3: development app bundle과 codesign 검증**

Run:

```bash
make CONFIGURATION=debug verify
```

Expected:

```text
Bundled build/CLIProxyManager.app
codesign verification passed
```

- [ ] **Step 4: 최종 변경 상태 확인**

Run:

```bash
git status --short --branch
git log --oneline -3
```

Expected: worktree branch가 설계 commit과 두 구현 commit만큼 앞서 있고 tracked file 변경은 없어야 한다. `build/`와 `.build/` 산출물은 git status에 나타나지 않아야 한다.

- [ ] **Step 5: 수동 확인 범위 전달**

사용자에게 development app에서 다음을 확인하도록 전달한다.

1. 짧은 command(`cc`, `cdxa`)가 HUD 버튼 바로 왼쪽에 한 줄로 표시되는지
2. 긴 account nickname에서 계정명은 말줄임되고 command·HUD·설정·더보기는 같은 trailing row를 유지하는지
3. 긴 command가 두 줄로 내려가지 않고 badge 내부에서 말줄임되는지
4. Connected, Disabled, Disconnected 카드에서 command가 동일한 위치를 유지하는지

production 앱은 실행하지 않는다.

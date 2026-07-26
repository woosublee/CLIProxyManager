# Account Row Alignment Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메인 계정 카드의 32pt 프로바이더 아이콘을 카드 콘텐츠 기준으로 상하 중앙 정렬하고, 계정명과 이메일·상태 상세정보 사이의 실질 간격을 6pt에서 2pt로 줄인다.

**Architecture:** `ProviderAccountCardView`의 top-aligned 바깥 `HStack`은 유지하여 제목과 trailing controls의 현재 위치를 보존한다. `ProviderAvatar`만 전체 카드 콘텐츠 높이를 차지하는 중앙 정렬 frame으로 감싸고, 계정 정보 `VStack`이 단일 2pt spacing만 소유하도록 중복 상단 padding을 제거한다.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, Swift Package Manager, Make

## Global Constraints

- 지원 플랫폼은 `macOS 15.0` 이상을 유지한다.
- `ProviderAvatar` 크기는 `32pt`를 유지한다.
- 계정 카드의 `.padding(.horizontal, 12)`와 `.padding(.vertical, 10)`을 유지한다.
- 메인 창 폭과 계정 수 기반 `preferredHeight` 계산을 변경하지 않는다.
- 계정명, command badge, HUD·설정·더보기 action의 현재 배치와 동작을 유지한다.
- drag handle, `ProviderAccountDragPreview`, Add provider 카드의 레이아웃을 변경하지 않는다.
- privacy, status, command 복사, account action 동작을 변경하지 않는다.
- production 앱은 실행·종료·활성화하지 않는다.
- 자동 검증은 전체 `swift test`와 `CONFIGURATION=debug` development app bundle codesign verification까지 수행한다.
- development 앱 실행과 수동 UI 확인은 사용자가 담당한다.
- subagent는 사용자가 명시적으로 동의한 경우에만 사용한다.
- 구현 commit은 사용자가 실행 방식을 승인하면서 단계별 commit을 허용한 경우에만 생성한다.

---

## File Structure

- Create: `Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift`
  - 메인 계정 카드의 프로바이더 아이콘 중앙 정렬과 두 텍스트 행 사이의 단일 2pt 간격을 source-contract 방식으로 검증한다.
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - `ProviderAccountCardView` 내부에서 아이콘만 중앙 정렬하고 계정 정보의 중복 세로 간격을 제거한다.

---

### Task 1: 프로바이더 아이콘을 카드 콘텐츠 중앙에 정렬

**Files:**
- Create: `Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:654-662`

**Interfaces:**
- Consumes: `ProviderAvatar(providerID:providerType:size:)`, 기존 `ProviderAccountCardView.body`
- Produces: 메인 계정 카드의 `ProviderAvatar`에 적용되는 `.frame(maxHeight: .infinity, alignment: .center)` 레이아웃 계약

- [ ] **Step 1: 아이콘 중앙 정렬 회귀 테스트 작성**

`Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift`를 다음 내용으로 생성한다.

```swift
import Foundation
import XCTest

final class DashboardAccountCardLayoutUITests: XCTestCase {
    func testDashboardCentersProviderAvatarWithinAccountCardContent() throws {
        let cardBody = try providerAccountCardBody()
        let avatar = try sourceSection(
            in: cardBody,
            after: "ProviderAvatar(providerID: account.id, providerType: account.providerType)",
            before: "\n\n            VStack"
        )

        XCTAssertTrue(
            avatar.contains(".frame(maxHeight: .infinity, alignment: .center)")
        )
    }

    private func providerAccountCardBody() throws -> String {
        let providerCard = try sourceSection(
            in: dashboardSource(),
            after: "struct ProviderAccountCardView: View {",
            before: "private struct ProviderAccountDragPreview: View"
        )
        return try sourceSection(
            in: providerCard,
            after: "var body: some View {",
            before: "private var trailingControls: some View"
        )
    }

    private func dashboardSource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp/Views/DashboardView.swift"),
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
swift test --filter DashboardAccountCardLayoutUITests/testDashboardCentersProviderAvatarWithinAccountCardContent
```

Expected: FAIL. 현재 `ProviderAvatar` 뒤에는 전체 높이 중앙 정렬 frame이 없으므로 `XCTAssertTrue`가 실패해야 한다.

- [ ] **Step 3: 아이콘에 최소 중앙 정렬 구현 추가**

`Sources/CLIProxyManagerApp/Views/DashboardView.swift`의 메인 계정 카드 아바타를 다음과 같이 변경한다.

```swift
ProviderAvatar(providerID: account.id, providerType: account.providerType)
    .frame(maxHeight: .infinity, alignment: .center)
```

바깥 `HStack(alignment: .top, spacing: 10)`, drag handle, 계정 정보 `VStack`, trailing controls는 변경하지 않는다.

- [ ] **Step 4: 아이콘 중앙 정렬 테스트 통과 확인**

Run:

```bash
swift test --filter DashboardAccountCardLayoutUITests/testDashboardCentersProviderAvatarWithinAccountCardContent
```

Expected: PASS, 1 test, 0 failures.

- [ ] **Step 5: 아이콘 정렬 변경 commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift
git commit -m "fix: center provider icon in account row" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: 계정명과 상세정보 간격을 2pt로 축소

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift:661-675`

**Interfaces:**
- Consumes: 기존 `accountDetailRow: some View`, Task 1의 중앙 정렬 아바타
- Produces: `VStack(alignment: .leading, spacing: 2)`와 추가 top padding이 없는 `accountDetailRow` 계약

- [ ] **Step 1: 단일 2pt 텍스트 간격 회귀 테스트 추가**

`DashboardAccountCardLayoutUITests`에 다음 test method를 추가한다.

```swift
func testDashboardUsesSingleTwoPointGapBetweenAccountNameAndDetail() throws {
    let cardBody = try providerAccountCardBody()
    let detailPlacement = try sourceSection(
        in: cardBody,
        after: "accountDetailRow",
        before: "\n            }\n            .frame(maxWidth:"
    )

    XCTAssertTrue(
        cardBody.contains("VStack(alignment: .leading, spacing: 2) {")
    )
    XCTAssertFalse(detailPlacement.contains(".padding(.top"))
}
```

- [ ] **Step 2: 간격 테스트가 현재 구현에서 실패하는지 확인**

Run:

```bash
swift test --filter DashboardAccountCardLayoutUITests/testDashboardUsesSingleTwoPointGapBetweenAccountNameAndDetail
```

Expected: FAIL. 현재 계정 정보 `VStack`은 `spacing: 4`이고 `accountDetailRow`에 `.padding(.top, 2)`가 있으므로 두 assertion이 요구하는 계약을 만족하지 않아야 한다.

- [ ] **Step 3: 중복 간격을 단일 2pt spacing으로 교체**

`ProviderAccountCardView.body`의 계정 정보 영역을 다음과 같이 변경한다.

```swift
VStack(alignment: .leading, spacing: 2) {
    HStack(spacing: 6) {
        Text(account.title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)

        Spacer(minLength: 0)

        trailingControls
            .layoutPriority(1)
    }

    accountDetailRow
}
.frame(maxWidth: .infinity, alignment: .leading)
```

`accountDetailRow`에서 제거하는 modifier는 다음 하나뿐이다.

```swift
.padding(.top, 2)
```

제목 `HStack`, `trailingControls`, `accountDetailRow` 자체의 status·privacy UI는 변경하지 않는다.

- [ ] **Step 4: 계정 카드 레이아웃 테스트 전체 통과 확인**

Run:

```bash
swift test --filter DashboardAccountCardLayoutUITests
```

Expected: PASS, 2 tests, 0 failures.

- [ ] **Step 5: 기존 command badge 렌더링 회귀 확인**

Run:

```bash
swift test --filter DashboardCommandBadgeLayoutUITests
```

Expected: PASS, 4 tests, 0 failures. command badge 순서, 한 줄 표시, 짧은 command 렌더링, 계정 상세정보 suffix 가시성이 유지되어야 한다.

- [ ] **Step 6: 텍스트 간격 변경 commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift \
  Sources/CLIProxyManagerApp/Views/DashboardView.swift
git commit -m "fix: tighten account row text spacing" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 전체 회귀 및 development bundle 검증

**Files:**
- Verify only: `Package.swift`
- Verify only: `Makefile`
- Verify only: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Verify only: `Tests/CLIProxyManagerAppTests/DashboardAccountCardLayoutUITests.swift`
- Verify only: `Tests/CLIProxyManagerAppTests/DashboardCommandBadgeLayoutUITests.swift`

**Interfaces:**
- Consumes: Task 1과 Task 2의 최종 source 및 test 상태
- Produces: targeted/full test suite와 development app bundle의 검증 근거

- [ ] **Step 1: 계정 카드 관련 targeted tests 재실행**

Run:

```bash
swift test --filter DashboardAccountCardLayoutUITests
swift test --filter DashboardCommandBadgeLayoutUITests
swift test --filter AccountReorderingUITests
```

Expected: 세 명령 모두 PASS, 합계 9 tests, 0 failures. 새 내부 정렬 계약과 기존 command badge·drag handle 계약이 함께 유지되어야 한다.

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

production 앱은 실행하지 않는다.

- [ ] **Step 4: 최종 변경 상태 확인**

Run:

```bash
git diff --check
git status --short --branch
git log --oneline -5
```

Expected: whitespace 오류가 없고 tracked file 변경이 없어야 한다. worktree branch에는 설계 commit, 구현 계획 문서 변경, 승인된 경우 두 구현 commit이 있어야 하며 `build/`와 `.build/` 산출물은 git status에 나타나지 않아야 한다.

- [ ] **Step 5: 사용자 수동 확인 범위 전달**

사용자에게 `build/CLIProxyManager.app` development bundle에서 다음을 확인하도록 전달한다.

1. Connected, Disabled, Disconnected 카드에서 프로바이더 아이콘이 카드 콘텐츠 기준으로 상하 중앙에 보이는지
2. 계정명과 이메일·상태 상세정보 사이가 기존보다 조밀하고 두 행이 붙어 보이지는 않는지
3. command badge, HUD·설정·더보기 action의 수직·수평 위치가 기존과 동일한지
4. drag handle과 drag preview 정렬이 기존과 동일한지

production 앱은 실행하지 않는다.

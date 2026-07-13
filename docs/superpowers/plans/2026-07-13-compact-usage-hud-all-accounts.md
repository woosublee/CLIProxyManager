# Compact Usage HUD 전체 계정 표시 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** compact Usage HUD를 실제 콘텐츠 높이에 맞추고, 최대 높이를 초과할 때만 모든 계정에 접근 가능한 세로 스크롤을 제공한다.

**Architecture:** `CompactUsageMeasurementState`가 최초 임시 높이, 실제 측정 높이, provider ID 변경을 관리한다. `CompactUsageOverlayView`는 숨겨진 자연 높이 스택을 측정하고, 측정값과 provider ID를 함께 기록해 callback 순서 및 reorder로 측정값이 유실되지 않도록 한다.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, Swift Package Manager

## Global Constraints

- Usage HUD 전체 최대 높이는 기존 720pt를 유지한다.
- 측정 전 viewport는 120pt를 사용한다.
- provider 수에 따른 높이 사전 예약은 하지 않는다.
- 측정 후 viewport는 실제 콘텐츠 높이와 `maximumAccountHeight` 중 작은 값이다.
- 실제 콘텐츠가 최대 높이를 넘을 때만 기본 세로 스크롤바를 표시한다.
- 동일 계정 집합의 reorder는 기존 측정 높이를 유지한다.
- 계정 추가·삭제는 측정값을 초기화하고 다시 측정한다.
- expanded HUD와 관련 없는 UI는 변경하지 않는다.

---

### Task 1: 실제 콘텐츠 높이 기반 viewport

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`

- [x] 측정 전 viewport가 120pt인지 실패 테스트를 작성한다.
- [x] provider 수가 늘어도 측정 전 높이를 예약하지 않는 실패 테스트를 작성한다.
- [x] 실제 측정 높이가 최대값 안에서는 그대로 사용되는지 테스트한다.
- [x] 실제 측정 높이가 최대값을 넘으면 viewport 제한과 scrolling 상태가 활성화되는지 테스트한다.
- [x] `viewportHeight(maximumHeight:)`와 `needsScrolling(maximumHeight:)`를 구현한다.

### Task 2: 최초 측정 callback 순서 보존

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`

- [x] 최초 실제 높이 측정 뒤 initial provider callback이 높이를 지우지 않는 실패 테스트를 작성한다.
- [x] `record(height:providerIDs:)`가 provider IDs와 실제 높이를 함께 기록하도록 구현한다.
- [x] `CompactUsageOverlayView`의 height preference callback에서 provider IDs를 함께 전달한다.

### Task 3: 계정 목록 변경 처리

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Models/UsageOverlayPresentationState.swift`
- Test: `Tests/CLIProxyManagerAppTests/UsageOverlayPresentationStateTests.swift`

- [x] 계정 추가 시 측정값이 초기화되는지 테스트한다.
- [x] 계정 삭제 시 측정값이 초기화되는지 테스트한다.
- [x] 동일 ID 집합의 reorder가 측정값을 보존하는 실패 테스트를 작성한다.
- [x] `updateProviderIDs(_:)`가 ID 집합이 바뀔 때만 측정값을 초기화하도록 구현한다.

### Task 4: 검증

- [x] `swift test --filter UsageOverlayPresentationStateTests` 실행
- [x] 전체 `swift test` 실행
- [x] 별도 Bundle ID의 debug app bundle 생성 및 ad-hoc 서명 검증
- [x] 계정 여러 개의 compact 표시, 실제 콘텐츠 높이 반영, reorder 후 높이 유지 수동 확인
- [x] `git diff --check`와 clean worktree 확인

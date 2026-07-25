# Usage HUD Account Button Polish and Motion Rollback Plan

> **For agentic workers:** The account button polish remains implemented. All account-row motion experiments are intentionally rolled back. Do not reintroduce row animation without a new approved design.

**Goal:** `macwindow` 기반 계정 카드 버튼 개선은 유지하고, Expanded/Compact 계정 행 모션 변경을 버튼 개선 직후 기준점으로 복구한다.

**Baseline:** `8cef470` (`style: refine Usage HUD account button`)

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, XCTest, macOS 15, Swift Package Manager

## Global Constraints

- production 앱은 실행, 종료, 활성화하거나 프로세스를 조작하지 않는다.
- 기존 `build-development/`는 commit하지 않는다.
- 버튼 symbol `macwindow`, 26×26 target, label, active/inactive foreground 표현을 유지한다.
- HUD 계정 선택 저장, filtering, menu bar, usage polling/cache 동작을 변경하지 않는다.
- Compact empty-state 실제 높이 재측정 fix를 유지한다.
- Expanded/Compact 계정 row에 insertion/removal animation을 추가하지 않는다.
- 후속 hidden measurement/visible buffer 구조는 별도 설계 승인 전 구현하지 않는다.

---

### Task 1: 버튼 시각 표현 유지

**완료 커밋:** `8cef470`

- [x] `chart.bar.xaxis`를 `macwindow`로 변경
- [x] 선택 background 제거
- [x] active accent, inactive hover-aware opacity 적용
- [x] 26×26, help, accessibility label 유지
- [x] 버튼 focused tests 통과

---

### Task 2: 행 모션 롤백 RED 계약

**Files:**
- Modify: `Tests/CLIProxyManagerAppTests/UsageOverlayAccountAnimationTests.swift`

- [x] Expanded에 insertion state/scheduler/opacity animation이 없어야 한다는 테스트 작성
- [x] Compact에 transition/Reduce Motion insertion/stable scroll wrapper가 없어야 한다는 테스트 작성
- [x] Window controller에 Expanded reveal coordination이 없어야 한다는 테스트 작성
- [x] 현재 motion 구현에서 RED 확인

RED evidence:

```text
UsageOverlayAccountAnimationTests
Executed 3 tests, with 15 failures
```

---

### Task 3: source를 pre-animation 기준점으로 복구

**Files:**
- Restore: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Restore: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Restore: `Sources/CLIProxyManagerApp/Services/UsageOverlayWindowController.swift`
- Restore: `Tests/CLIProxyManagerAppTests/UsageOverlayWindowControllerTests.swift`

- [x] 위 파일을 `8cef470` 기준으로 복구
- [x] Compact empty-state measurement fix가 유지되는지 확인
- [x] `UsageOverlayAccountAnimationTests` GREEN 확인
- [x] `UsageOverlayPresentationStateTests` GREEN 확인
- [x] `UsageOverlayWindowControllerTests` GREEN 확인

Focused GREEN evidence:

```text
UsageOverlayAccountAnimationTests: 3 tests, 0 failures
UsageOverlayPresentationStateTests: 18 tests, 0 failures
UsageOverlayWindowControllerTests: 53 tests, 0 failures
```

---

### Task 4: 문서 및 최종 검증

**Files:**
- Modify: `docs/superpowers/specs/2026-07-25-hud-account-button-polish-design.md`
- Modify: `docs/superpowers/plans/2026-07-25-hud-account-button-polish.md`

- [x] 실패한 motion 접근과 롤백 상태 기록
- [x] 전체 `swift test` — 1,011 tests, 0 failures
- [x] isolated debug `make verify` 및 codesign 검증
- [x] `git diff --check`
- [x] rollback commit 생성
- [ ] 사용자가 요청하면 development bundle만 다시 빌드·실행

## 완료 후 상태

- 계정 카드 HUD 버튼 개선: 유지
- Expanded 계정 추가 깜빡임: 미해결, 후속 재설계 대기
- Compact 계정 표시: motion 작업 전 rendering 구조로 복구
- 계정 row animation: 두 모드 모두 없음

# Usage HUD 계정 버튼 시각 개선 설계

**작성일:** 2026-07-25  
**상태:** 버튼 개선 완료 · 계정 행 모션 롤백 완료 — 재설계 대기

## 현재 적용 범위

계정 카드의 Usage HUD 표시 버튼 개선만 유지한다.

- symbol: `macwindow`
- HUD 표시 중: `BrandPalette.accent`
- HUD 숨김: 낮은 primary opacity, 카드 hover 시 opacity 상승
- 선택 background 없음
- 26×26 click target 유지
- help/accessibility label 유지
  - `Hide from Usage HUD`
  - `Show in Usage HUD`
- Connected, Disabled, Disconnected의 기존 action 순서 유지

## 계정 행 모션 롤백

Expanded 계정 재표시 깜빡임을 완화하기 위해 시도했던 다음 변경은 모두 롤백한다.

- Expanded/Compact account row insertion transition
- `0.12`초 `easeOut` opacity fade
- Expanded transparent-first staged reveal
- Expanded insertion state 및 generation guard
- Controller fitting-resize-before-reveal scheduler
- Compact stable visible/measurement container 변경
- 계정 insertion을 위한 Reduce Motion 분기

버튼 개선 직후인 commit `8cef470`의 HUD rendering 구조로 source를 복구한다. 이 기준점에는 기존 Compact empty-state 실제 높이 재측정 fix가 포함되어 있다.

## 롤백 이유

수동 development build 확인에서 다음이 확인됐다.

1. Expanded의 깜빡임이 여러 opacity/queue ordering 수정 후에도 해결되지 않았다.
2. Compact는 처음에는 상대적으로 자연스러웠지만 행 transition과 stable container 변경 후 깜빡임이 새로 관찰됐다.
3. opacity가 0이어도 새 행이 visible SwiftUI layout에 참여하면 기존 행 위치와 panel fitting size가 즉시 바뀐다. 따라서 opacity timing만 조절하는 접근은 근본 해결이 아니다.
4. 자동 source-contract 테스트와 fitting-size 테스트는 시각적 composition 결과를 증명하지 못했다.

Compact 회귀를 우선 제거하기 위해 두 모드 모두 계정 insertion animation을 소유하지 않는 상태로 되돌린다.

## 현재 HUD 동작

- Expanded와 Compact 모두 provider 목록 변경을 즉시 렌더링한다.
- 계정 제거와 재표시에 별도 row transition을 적용하지 않는다.
- Compact는 기존 hidden measurement stack, viewport 계산, empty-state 측정 흐름을 사용한다.
- Expanded는 기존 natural-height account stack과 AppKit fitting resize 흐름을 사용한다.
- 저장, filtering, menu bar, usage polling/cache, panel placement 정책은 변경하지 않는다.

## 남은 문제

Expanded에서 숨긴 계정을 다시 표시할 때 관찰되는 원래 깜빡임은 이번 롤백으로 해결하지 않는다.

후속 재설계에서는 timing patch가 아니라 다음 구조를 검토한다.

1. 최종 provider 목록을 계산하는 hidden measurement 계층
2. 현재 사용자에게 보이는 provider 목록을 유지하는 visible 계층
3. 목표 panel size를 먼저 적용한 뒤 visible 목록을 commit하는 명시적 단계
4. 제거, 빠른 연속 변경, mode transition과의 상태 전이 정의

이 후속 구조는 별도 설계 승인 전에는 구현하지 않는다.

## 회귀 테스트 계약

- Expanded source에 insertion state, staged reveal scheduler, row opacity animation이 없어야 한다.
- Compact source에 account transition, Reduce Motion insertion 분기, stable scroll wrapper 변경이 없어야 한다.
- Window controller에 Expanded insertion reveal coordination이 없어야 한다.
- 기존 Compact empty-state 실제 높이 측정 테스트는 계속 통과해야 한다.
- 버튼 presentation 및 accessibility 테스트는 계속 통과해야 한다.

## 자동 검증

1. `UsageOverlayAccountAnimationTests`
2. `UsageOverlayPresentationStateTests`
3. `UsageOverlayWindowControllerTests`
4. 전체 `swift test`
5. `CONFIGURATION=debug` development bundle 및 codesign verification

production 앱은 실행·종료·활성화하지 않는다. development 앱 실행과 수동 UI 확인은 사용자가 요청한 경우에만 development bundle을 대상으로 수행한다.

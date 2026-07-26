# 메인 계정 카드 command badge 레이아웃 개선 설계

**작성일:** 2026-07-26
**상태:** 설계 승인

## 문제

Usage HUD 계정 표시 버튼이 메인 계정 카드의 action 영역에 추가되면서 우측 고정 폭이 약 30pt 증가했다. 계정명과 `SlugPill`은 같은 `HStack`에서 남은 폭을 공유하지만, `SlugPill` 내부에는 단일 행 제약이 없다. 이 때문에 SwiftUI가 폭이 부족한 카드에서 command 텍스트를 두 줄로 배치해 badge 높이가 늘어난다.

메인 창의 고정 폭이나 HUD 버튼 자체가 문제라기보다, 유연한 계정 정보와 trailing controls의 레이아웃 책임이 분리되지 않은 것이 근본 원인이다.

## 목표

- command badge를 항상 한 줄로 표시한다.
- command badge를 Usage HUD 버튼 바로 왼쪽에 배치한다.
- 계정명·상세정보와 trailing controls가 서로 다른 레이아웃 영역을 사용하도록 한다.
- HUD·설정·더보기 버튼의 26×26 interaction target을 유지한다.
- 메인 창 폭과 계정 카드 높이를 변경하지 않는다.

## 비목표

- Usage HUD 표시 상태나 저장 동작을 변경하지 않는다.
- command 복사 동작과 hover·copied feedback을 변경하지 않는다.
- 계정명, 상세정보 또는 action icon의 시각 스타일을 재설계하지 않는다.
- provider 설정의 command 이름 validation 규칙을 변경하지 않는다.

## 레이아웃

계정 카드의 가로 구조를 다음과 같이 분리한다.

```text
[drag] [avatar] [계정명 / 상세정보] … [$ command] [HUD] [설정] [더보기]
```

`ProviderAccountCardView`의 계정 정보 `VStack`에는 계정명과 상세정보만 둔다. `SlugPill`은 해당 영역에서 제거하고, 새 `trailingControls`의 첫 항목으로 이동한다.

`trailingControls`는 command badge와 기존 `actions`를 하나의 가운데 정렬 `HStack`으로 묶는다. 따라서 command badge는 모든 account status에서 Usage HUD 버튼 바로 왼쪽에 위치한다. Connected, Disabled, Disconnected별 기존 action 순서와 동작은 유지한다.

## command badge 압축 규칙

`SlugPill`의 command 텍스트에 단일 행 제약과 말줄임을 적용한다.

1. 일반적인 command 이름은 badge 안에서 모두 표시한다.
2. 폭이 부족하면 계정명이 먼저 말줄임된다.
3. command 자체가 trailing controls가 사용할 수 있는 폭보다 길면 badge 내부에서 한 줄 말줄임한다.
4. HUD·설정·더보기 같은 고정 action은 축소하거나 숨기지 않는다.

이 규칙은 메인 카드뿐 아니라 `SlugPill`을 재사용하는 drag preview에도 동일한 단일 행 계약을 제공한다.

## 구성요소 변경

### `ProviderAccountCardView`

- 계정명 `HStack`에서 `SlugPill`을 제거한다.
- `SlugPill`과 `actions`를 묶는 `trailingControls`를 추가한다.
- 본문에서 기존 `actions` 대신 `trailingControls`를 배치한다.

### `SlugPill`

- command 텍스트를 한 줄로 제한한다.
- 가용 폭이 부족할 때 말줄임한다.
- 복사, hover, copied 상태, 색상, padding, border는 유지한다.

### `AppWindowMetrics`

변경하지 않는다. `mainWidth`는 380pt를 유지한다.

## 테스트

기존 UI source-contract 테스트 관례를 따라 다음 회귀 계약을 추가한다.

1. 계정명 영역에 `SlugPill`이 남아 있지 않아야 한다.
2. `trailingControls`에서 `SlugPill`이 `actions`보다 앞에 있어야 한다.
3. `SlugPill`의 command 텍스트가 단일 행 제약과 말줄임을 가져야 한다.
4. 기존 Usage HUD 버튼의 모든 status branch 배치, presentation, accessibility 테스트가 계속 통과해야 한다.

## 자동 검증

1. 새 command badge 레이아웃 회귀 테스트
2. `UsageOverlayAccountVisibilityUITests`
3. 전체 `swift test`
4. `CONFIGURATION=debug` development app bundle build 및 codesign verification

production 앱은 실행·종료·활성화하지 않는다. development 앱 실행과 수동 UI 확인은 사용자가 담당한다.

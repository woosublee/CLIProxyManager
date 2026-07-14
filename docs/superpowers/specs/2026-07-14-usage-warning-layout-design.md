# 사용량 조회 경고 레이아웃 개선 설계

## 목표

GitHub 이슈 #82에 따라 stale 사용량 snapshot과 함께 표시되는 경고 아이콘을 각 화면의 주변 요소와 자연스럽게 정렬한다. compact HUD에서는 경고로 인해 계정 행의 높이가 늘어나지 않도록 하면서 기존 provider avatar의 위치를 유지한다.

## 현재 문제

- expanded HUD와 메뉴바는 사용량 콘텐츠와 경고 아이콘을 `HStack(alignment: .top)`으로 배치한 뒤 경고에 `.padding(.top, 1)`을 적용한다. 이 수동 보정은 사용량 첫 행의 시각적 중심과 일치하지 않는다.
- compact HUD는 사용량 카드 다음에 경고 아이콘을 별도 `VStack` 항목으로 배치한다. stale 상태가 되면 계정 행의 높이가 늘어나고 전체 HUD 점유 공간도 커진다.
- 현재 테스트는 경고 상태와 메시지는 검증하지만 실제 레이아웃 정책은 검증하지 않는다.

## 설계

### 공통 경고 아이콘

`SubscriptionUsageWarningIcon`의 색상, 크기, tooltip, accessibility label은 유지한다. 화면별 배치 책임은 각 컨테이너가 담당하며, 임의의 top padding으로 정렬하지 않는다.

### Expanded HUD와 메뉴바

snapshot 사용량과 경고 아이콘을 첫 번째 사용량 행의 높이에 맞춘 공통 수평 컨테이너로 배치한다.

- 경고 아이콘은 첫 번째 사용량 행과 수직 중앙 정렬한다.
- 여러 usage window가 있어도 경고 아이콘은 기존처럼 한 번만 표시한다.
- snapshot 내용과 정상 상태의 폭·높이 계산은 유지한다.
- stale 경고가 없을 때는 기존 snapshot 레이아웃과 동일해야 한다.

이를 위해 snapshot 사용량 뷰와 경고를 외부에서 top 정렬하는 대신, 첫 행과 경고를 함께 구성하고 나머지 행은 아래에 이어 붙이는 작은 presentation/layout 단위를 사용한다.

### Compact HUD

provider header의 avatar를 고정 기준으로 사용한다.

- avatar와 provider 이름의 기존 중심축과 위치는 유지한다.
- stale 또는 warning indicator가 있을 때 경고 아이콘을 avatar 오른쪽에 overlay한다.
- 경고 아이콘은 일반 레이아웃 흐름에 참여하지 않아 header나 계정 행의 높이를 늘리지 않는다.
- 사용량 카드 아래의 별도 indicator 행은 제거한다.
- loading, disabled, unavailable처럼 사용량 row가 없는 placeholder 상태는 현재 placeholder 내부 indicator를 유지한다.
- 정상 snapshot에는 overlay가 없으며 기존 레이아웃과 크기가 동일하다.
- 상세 경고 메시지는 기존 tooltip과 accessibility label로 제공한다.

## 범위

변경 대상은 다음으로 제한한다.

- `SubscriptionUsageWarningIcon.swift`: 재사용 가능한 경고 presentation 또는 layout 보조 타입
- `UsageOverlayView.swift`: expanded HUD snapshot 경고 정렬
- `MenuBarStatusView.swift`: 메뉴바 snapshot 경고 정렬
- `CompactUsageOverlayView.swift`: stale snapshot 경고를 avatar 우측 overlay로 이동
- 관련 app test: 경고 배치 정책과 정상 상태 회귀 검증

window geometry, HUD 전환 애니메이션, 사용량 조회·cache 로직, 일반 indicator의 의미와 문구는 변경하지 않는다.

## 검증

1. stale snapshot은 expanded HUD와 메뉴바에서 첫 usage row와 경고 아이콘을 함께 표시한다.
2. 두 화면의 경고 아이콘은 수동 top padding 없이 첫 행의 수직 중심에 맞는다.
3. compact stale snapshot은 avatar 우측에 경고 아이콘을 표시하고 사용량 카드 하단에는 별도 indicator를 만들지 않는다.
4. compact placeholder 상태는 기존 indicator를 유지한다.
5. 정상 snapshot은 경고 전용 레이아웃 요소를 추가하지 않는다.
6. 관련 단위 테스트와 전체 `swift test`를 통과한다.
7. 격리된 경로에 development app bundle을 생성한다.
8. 최종 시각 확인은 사용자가 development app을 실행해 수행한다.

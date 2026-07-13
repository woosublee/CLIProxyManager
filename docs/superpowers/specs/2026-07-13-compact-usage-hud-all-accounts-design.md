# Compact Usage HUD 전체 계정 표시 설계

## 목표

GitHub 이슈 #71에 따라 compact Usage HUD에서 연결된 모든 계정에 접근할 수 있도록 한다. 콘텐츠가 화면 안에 들어오면 실제 콘텐츠 높이에 맞춰 HUD를 표시하고, 화면별 최대 높이를 넘을 때만 기본 세로 스크롤을 제공한다.

## 원인

compact 뷰는 실제 계정 스택 높이를 측정하기 전 120pt를 임시 viewport로 사용한다. 기존 구현에서는 다음 상태 전환에서 이 임시 높이에 머물 수 있었다.

- 최초 실제 높이를 측정한 뒤 initial provider ID callback이 측정값을 초기화하는 경우
- 동일 계정의 순서만 변경했는데 provider ID 배열 변경으로 측정값을 초기화하는 경우
- 초기화 후 콘텐츠 총높이가 같아 SwiftUI height preference가 다시 발생하지 않는 경우

## 높이 계산

- 측정 전 임시 viewport: 120pt
- 측정 후 viewport: `min(실제 콘텐츠 높이, maximumAccountHeight)`
- 실제 콘텐츠가 `maximumAccountHeight`를 초과할 때만 vertical scrolling과 기본 스크롤바 활성화
- 계정 수에 비례한 사전 높이 예약은 하지 않음

현재 window 제약은 유지한다.

- Usage HUD 전체 최대 높이: 720pt
- compact 계정 viewport 최대 높이: 전체 최대 높이에서 chrome과 padding 52pt를 제외한 668pt
- 작은 화면: visible frame의 상하 16pt margin과 chrome/padding을 제외한 높이

## 측정 상태 갱신

최초 height preference를 기록할 때 해당 provider ID 목록도 함께 저장한다. 따라서 뒤이어 실행되는 initial provider ID callback은 동일 목록을 새 변경으로 처리하지 않는다.

provider 목록 갱신은 다음처럼 처리한다.

- 동일 ID와 동일 순서: 기존 측정값 유지
- 동일 ID 집합의 순서 변경: 총 콘텐츠 높이가 같으므로 기존 측정값 유지
- 계정 추가·삭제: 측정값을 초기화하고 120pt 임시 viewport로 돌아간 뒤 새 자연 높이를 측정
- 계정 콘텐츠 높이 변경: 새 height preference를 기록하고 panel fitting size 재계산 요청

## 변경 범위

- `CompactUsageMeasurementState`: 실제 높이, provider ID 집합 변경, viewport 및 overflow 판단 관리
- `CompactUsageOverlayView`: 최초 측정 시 provider ID 동시 기록, measurement state의 overflow 판단 사용
- `UsageOverlayPresentationStateTests`: 최초 측정 순서, 실제 높이 제한, 계정 추가·삭제, reorder 회귀 검증

관련 없는 UI 스타일, expanded HUD, window geometry 상수는 변경하지 않는다.

## 검증

1. 측정 전 120pt 임시 viewport를 사용한다.
2. provider 수와 무관하게 실제 측정 전 추가 공간을 예약하지 않는다.
3. 실제 콘텐츠 높이가 측정되면 그 높이로 조정한다.
4. 최대 높이를 넘을 때만 viewport를 제한하고 스크롤을 활성화한다.
5. 최초 provider callback과 reorder가 측정 높이를 지우지 않는다.
6. 계정 추가·삭제는 측정값을 초기화한다.
7. 전체 `swift test`와 격리된 development build를 검증한다.

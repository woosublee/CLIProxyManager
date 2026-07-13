# Compact Usage HUD 전체 계정 표시 설계

## 목표

GitHub 이슈 #71에 따라 compact Usage HUD가 연결된 모든 계정에 접근할 수 있도록 한다. 화면 공간이 충분하면 전체 계정 높이에 맞춰 HUD가 확장되고, 공간이 부족하면 현재 최대 높이 안에서 기본 세로 스크롤바를 제공한다.

## 현재 원인

`CompactUsageMeasurementState`는 실제 계정 스택 높이를 측정하기 전 항상 120pt를 viewport 높이로 사용한다. 여러 계정이 있어도 첫 layout에서 한 계정 정도의 높이만 요청하므로 panel의 fitting height가 작게 고정될 수 있다. 이후 계정 목록이나 display mode가 바뀔 때 측정 상태와 panel resize 요청이 최신 콘텐츠 높이를 안정적으로 반영해야 한다.

현재 높이 제한은 다음과 같다.

- Usage HUD 전체 최대 높이: 720pt
- compact 계정 viewport 최대 높이: 전체 최대 높이에서 chrome과 padding 52pt를 제외한 668pt
- 작은 화면: visible frame의 상하 16pt margin과 chrome/padding을 제외한 높이

## 수정 설계

### 초기 viewport 높이

실제 측정 전에는 계정 수를 기준으로 초기 viewport 높이를 계산한다.

- 계정 0개: 기존 빈 상태 높이 72pt 유지
- 계정 1개 이상: 계정당 120pt를 추정 높이로 사용
- 추정 높이는 `maximumAccountHeight`를 넘지 않는다.

따라서 화면 공간이 충분하면 2개 계정은 약 240pt, 3개 계정은 약 360pt가 초기부터 확보된다. 실제 측정이 완료되면 추정값 대신 측정된 자연 높이를 사용한다.

### 측정 무효화

계정 식별자 목록이 변경되면 이전 측정 높이를 폐기하고 새 계정 수 기반 추정값으로 돌아간다. SwiftUI preference가 새 자연 높이를 전달하면 측정 상태를 갱신하고 `onMeasurementChange`를 호출해 panel fitting size를 다시 계산한다.

expanded/compact 전환 시에는 compact 뷰가 다시 생성되고 계정 수 기반 초기 높이를 사용하며, 측정 완료 후 같은 resize 경로로 정확한 높이를 반영한다.

### 스크롤

자연 높이가 `maximumAccountHeight`를 초과할 때만 vertical scrolling을 활성화하고 SwiftUI 기본 스크롤바를 표시한다. 별도 fade나 custom indicator는 추가하지 않는다.

## 변경 범위

- `CompactUsageMeasurementState`: 계정 수를 보관하고 초기 추정 높이를 계산하도록 조정
- `CompactUsageOverlayView`: 계정 수 기반 viewport 계산 사용
- 관련 presentation state 테스트: 0개, 1개, 여러 개, 측정 후 값, 계정 추가·삭제, 작은 최대 높이 검증
- 필요한 경우 기존 window controller 테스트에서 compact 최대 높이 재계산 경로 보강

관련 없는 UI 리팩터링, 스타일 변경, expanded HUD 변경은 하지 않는다.

## 검증

1. 단위 테스트에서 측정 전 계정 수에 따른 viewport 높이를 검증한다.
2. 측정 후 실제 높이가 추정값을 대체하는지 검증한다.
3. 계정 추가·삭제 후 이전 측정값이 폐기되고 새 추정값을 사용하는지 검증한다.
4. 작은 최대 높이에서는 viewport가 제한되고 스크롤 조건이 성립하는지 검증한다.
5. 전체 `swift test`와 development build를 실행한다. 앱 실행과 수동 UI 확인은 사용자가 담당한다.

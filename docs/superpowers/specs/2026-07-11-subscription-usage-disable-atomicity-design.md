# 구독 사용량 비활성화 원자성 설계

**작성일:** 2026-07-11
**상태:** 승인됨 — 구현 계획 작성 전 검토 대기

## 목표

구독 사용량을 끄거나 전체 설정을 초기화할 때 `subscriptionUsage.isEnabled`와 management key 파일이 config 저장 실패로 어긋나지 않게 한다. 서버가 중지된 뒤에는 마지막으로 성공한 사용량을 계속 표시하지만, 새 management API 조회는 하지 않는 현재 정책을 유지한다.

## 범위

- `DashboardViewModel.saveSubscriptionUsageEnabled(false)`의 키 삭제와 config 저장 순서를 수정한다.
- `DashboardViewModel.resetAllSettings()`의 동일한 순서 문제를 수정한다.
- config 저장 실패와 key 삭제 실패를 검증하는 회귀 테스트를 추가한다.
- 서버 중지 뒤 일반 상태 갱신이 기존 사용량을 보존하고 새 사용량 요청을 만들지 않는 동작을 테스트한다.

다음은 범위 밖이다.

- 마지막 성공 사용량을 숨기거나, 서버 중지 시 표시 문구를 새로 추가하는 UI 변경
- 사용량 조회 API·polling 주기·키 파일 형식 변경
- stale key 즉시 삭제 실패를 위한 별도 persistent retry queue 도입

## 설계

### 비활성화 흐름

1. 현재 config를 복사해 `subscriptionUsage.isEnabled = false`로 설정한다.
2. `saveConfig`로 shell 설치, config 파일 저장, ViewModel 상태 반영을 모두 성공시킨다.
3. 성공한 뒤에만 진행 중 새로고침·polling을 취소한다.
4. management key를 삭제한다.
5. 삭제 성공 시 모든 계정 사용량 상태를 `.disabled`로 바꾸고, 실행 중인 프록시는 비동기로 재시작한다.

config 저장이 실패하면 key, polling, 마지막 사용량 상태를 전혀 변경하지 않는다. 따라서 활성 config와 key가 항상 함께 남는다.

key 삭제가 실패하면 config는 이미 비활성화 상태로 유지한다. 다음 시작의 `prepareSubscriptionUsage()`가 남은 key를 정리한다. 호출자는 오류를 받아 사용자에게 실패 메시지를 보이지만, 프록시가 다음에 재시작될 때 `remote-management` 블록은 비활성 config에 따라 제외된다.

### 전체 설정 초기화 흐름

1. 기존 계정·명령을 보존한 default config를 `saveConfig`로 먼저 저장한다.
2. 성공한 뒤에만 구독 사용량 작업을 취소하고 key 삭제를 시도한다.
3. key 삭제 성공 시 `.disabled` 상태와 기본 appearance를 적용하고 성공 메시지를 보인다.
4. key 삭제 실패 시 이미 성공한 설정 초기화를 되돌리지 않는다. 설정은 기본값으로 적용하고, key cleanup 실패를 설명하는 메시지를 보인다.

config 저장 실패에서는 key·polling·사용량 상태·appearance를 변경하지 않는다.

### 서버 중지 시 캐시 정책

`refresh()`는 서버와 계정 상태만 갱신하며 구독 사용량 조회를 시작하지 않는다. 서버가 ready가 아닌 상태가 되어도 기존 `.available` snapshot은 보존한다. 메뉴바의 manual reload는 이미 `canRefreshSubscriptionUsage`으로 비활성화되며, 새 polling 또는 API 요청은 시작되지 않는다.

## 오류 처리

| 단계 | 실패 결과 |
| --- | --- |
| 비활성화 config 저장 | key와 활성 config를 보존하고 오류를 반환 |
| 비활성화 key 삭제 | 비활성 config를 유지하고 오류를 반환; 다음 앱 시작에서 stale key 정리 재시도 |
| reset config 저장 | key와 기존 config를 보존하고 reset 실패를 표시 |
| reset key 삭제 | 기본 config는 유지하고 key cleanup 실패를 표시 |
| 서버 중지 상태 | 마지막 성공 usage snapshot 유지; API 요청하지 않음 |

## 테스트

- 비활성화 config 저장 실패가 기존 key와 활성 config를 보존하는지 검증한다.
- reset config 저장 실패가 기존 key와 활성 config를 보존하는지 검증한다.
- key 삭제 실패 뒤에도 비활성화 config가 유지되는지 검증한다.
- reset key 삭제 실패가 기본 config를 되돌리지 않고 실패 메시지를 제공하는지 검증한다.
- 서버 상태가 ready에서 stopped로 갱신돼도 마지막 usage snapshot이 유지되고 quota client 호출 수가 증가하지 않는지 검증한다.

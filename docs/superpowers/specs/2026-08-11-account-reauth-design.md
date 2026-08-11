# OAuth 계정 재로그인 설계

## 목표

OAuth 크리덴셜이 만료되었거나 사용자가 직접 인증을 갱신하려 할 때, 앱 메인의 기존 계정 카드에서 재로그인을 시작할 수 있게 한다. 재로그인 결과는 새 계정을 추가하지 않고 사용자가 선택한 기존 카드에 귀속한다.

## 범위

- 앱 메인 `Accounts` 목록의 OAuth 계정 액션 메뉴에 `Re-login`을 추가한다.
- OAuth 계정의 `Move Up`, `Move Down` 메뉴 항목을 제거한다. 계정 순서 변경은 기존 drag handle로 계속 지원한다.
- 재로그인 결과의 크리덴셜을 기존 계정의 인증 파일에 안전하게 교체한다.
- 기존 command, nickname, 모델·라우팅 설정, 계정 표시 순서, Usage HUD 표시 설정, 활성화·비활성화 상태를 보존한다.
- 재로그인 성공 후 기존 OAuth 완료 흐름과 같은 proxy 설정 재적용 및 사용량 갱신 흐름을 사용한다.

## 비목표

- API Key 프로필의 키 갱신 UX 변경
- 계정 카드에 별도의 만료 문구, 경고 배지 또는 `Re-login` 텍스트 버튼 추가
- 사용량 조회 결과에 따라 계정 카드의 레이아웃이나 액션 버튼 외형 변경
- 계정 순서 변경 drag handle 제거 또는 재설계
- 재로그인 중 여러 OAuth 로그인을 동시에 실행하는 기능

## 메인 화면 메뉴

카드의 기존 `…` 액션 버튼 위치와 외형은 바꾸지 않는다. 재로그인이 필요한지 여부를 계정 카드에서 별도로 표현하지 않는다. OAuth 크리덴셜이 만료된 경우에도 사용자는 같은 메뉴에서 즉시 재로그인을 시작한다.

### 연결된 OAuth 계정

```text
↻  Re-login
⏻  Disable account
──────────────
🗑  Remove account
```

### 비활성화된 OAuth 계정

```text
↻  Re-login
⏻  Enable account
──────────────
🗑  Remove account
```

`Re-login`은 크리덴셜 복구와 수동 갱신을 위한 우선 동작이므로 가장 위에 둔다. Enable/Disable은 계정의 실행 상태를 바꾸는 일반 관리 동작으로 그 다음에 둔다. `Remove account`는 유일한 destructive 동작으로 구분선 아래 마지막에 둔다.

### 연결 해제 OAuth 계정과 API Key 프로필

```text
🗑  Remove account
```

- 연결 해제 OAuth 계정은 기존 `Connect` 버튼으로 로그인하므로 `Re-login`을 제공하지 않는다.
- API Key 프로필은 OAuth 브라우저 로그인 대상이 아니므로 `Re-login`을 제공하지 않는다. 기존 label인 `Remove API key profile`을 유지한다.

## 재로그인 세션

일반 provider 추가 로그인과 대상 계정 재로그인을 구분하는 로그인 intent를 둔다.

- 일반 추가: provider 유형만 가진다.
- 재로그인: `ProviderRowState.ID`, 대상 `authProfileID`, provider 유형, 기존 활성화·비활성화 상태를 가진다.

`Re-login`을 누르면 재로그인 intent로 OAuth 세션을 시작하고 별도의 `Re-login <계정 이름>` 진행 시트를 표시한다. 시트는 브라우저 로그인을 완료하도록 안내하며, 진행 중에는 중복 로그인을 시작할 수 없다.

일반 provider 추가가 완료되면 현재처럼 provider settings 시트로 이동한다. 재로그인이 완료되면 provider settings를 열지 않고 메인 화면으로 돌아간다.

## 크리덴셜 교체 트랜잭션

재로그인은 선택한 기존 카드의 크리덴셜만 바꾼다. 브라우저에서 다른 계정으로 로그인해도 새 로그인 결과는 재로그인을 시작한 카드에 연결된다.

1. 로그인 전, 같은 provider에 속한 모든 인증 파일의 raw JSON과 파일 목록을 메모리에 스냅샷한다. 대상 파일의 `disabled`와 `prefix`도 보존값으로 기록한다.
2. `OAuthLoginService`가 CLIProxyAPI 브라우저 로그인 절차를 실행한다.
3. 로그인 후 인증 파일을 다시 읽고 스냅샷과 비교해 변경 결과를 판별한다.
   - **대상 파일만 변경됨:** 대상 파일을 로그인 결과로 사용하고, 보존한 `disabled`와 `prefix`를 다시 적용한다.
   - **새 인증 파일 하나가 생성됨:** 새 파일의 로그인 결과를 대상 파일에 원자적으로 반영하고 새 파일을 제거한다. 대상의 `disabled`와 `prefix`는 보존한다.
   - **기존의 비대상 인증 파일 하나가 변경됨:** 변경된 파일의 로그인 결과를 대상 파일에 원자적으로 반영한 뒤, 비대상 파일은 로그인 전 raw JSON으로 되돌린다. 다른 계정 카드의 기존 크리덴셜을 잃지 않는다.
   - **변경 결과가 없거나 후보가 여러 개임:** 성공 처리하지 않는다.
4. 교체, 정리, 복원 단계 중 하나라도 실패하면 모든 기존 인증 파일을 로그인 전 raw JSON으로 되돌리고 로그인 중 새로 생성된 인증 파일을 제거한다.
5. 성공 후 `refreshProfiles()`로 상태를 다시 읽고, 대상 카드 ID를 완료한 계정으로 유지한 채 기존 OAuth configuration work를 실행한다.

이 트랜잭션은 `oauthCommandProfiles`와 `accountOrder`를 재구성하거나 새 command profile을 만들지 않는다. 따라서 command, nickname, Claude/Codex 모델·라우팅, 계정 순서, Usage HUD 표시 여부는 유지된다.

비활성화된 계정을 재로그인해도 대상 인증 파일과 command profile은 비활성화 상태로 남는다. 재인증은 사용자의 명시적인 Enable 의도를 무시하지 않는다.

## 만료 신호

현재 구독 사용량 흐름이 다음 신호를 감지할 수 있다.

- 인증 프로필의 `expired` 시간이 과거다.
- 구독 사용량 상태가 `.unavailable(.credentialExpired)`다.

이 신호는 재로그인이 필요한 원인이지만, 이 기능은 카드에 새 텍스트·버튼·배지를 추가하지 않는다. 만료 여부와 무관하게 OAuth 계정의 `… → Re-login`은 동일하게 제공된다.

## 실패 처리

- 사용자가 로그인 시트를 취소하거나 OAuth 프로세스가 실패하면 인증 파일, 앱 설정, 계정 순서를 변경하지 않는다. 기존 취소/실패 toast를 사용한다.
- 로그인 결과를 대상 카드에 안전하게 판별할 수 없으면 provider 인증 파일을 로그인 전 스냅샷으로 복원하고, 로그인 중 새로 생긴 인증 파일을 제거한다. 앱 설정과 기존 카드는 바꾸지 않고 재시도를 안내한다.
- 크리덴셜 교체가 성공한 뒤 proxy 설정 재적용 또는 재시작에 실패하면 새 크리덴셜은 유지한다. `Re-login succeeded, but CLIProxyAPI could not restart: <localized error>`처럼 인증 성공과 런타임 적용 실패를 구분한다.
- 재로그인 뒤 사용량 갱신이 실패해도 새 크리덴셜을 되돌리지 않는다. 기존 자동/수동 갱신에서 다시 시도한다.
- OAuth 로그인 task가 이미 진행 중이면 모든 `Re-login` 메뉴 항목을 비활성화한다.

## 구성 요소와 책임

### `AuthProfileStore`

인증 파일 스냅샷, 로그인 결과 후보 판별, 대상 파일 원자 교체, 비대상 변경 파일 복원, 새 source 파일 정리, 실패 시 전체 복원을 담당하는 제한된 재로그인 트랜잭션 API를 제공한다. 이 API는 raw JSON을 내부에서만 다루며 credential 값을 로그로 남기지 않는다.

### `DashboardViewModel`

재로그인 intent의 대상 정보를 보관하고 OAuth 로그인 lifecycle을 조정한다. 성공 시 기존 계정 ID를 완료 대상으로 설정하고, provider settings 시트 대신 메인 화면 복귀를 선택한다. 재로그인 전후에도 기존 config와 계정 카드 설정이 유지되도록 한다.

### `DashboardView`와 로그인 진행 UI

OAuth 카드 메뉴에 상태별 순서로 `Re-login`을 추가하고 Move Up/Move Down을 제거한다. 일반 추가와 재로그인 intent에 맞는 로그인 진행 시트와 완료 후 화면 전환을 렌더링한다.

## 테스트

### `AuthProfileStore` 테스트

- 대상 파일이 로그인으로 직접 갱신된 경우 성공 처리하고 `disabled`, `prefix`를 유지한다.
- 새 source 인증 파일의 로그인 결과를 대상 파일로 교체하고 새 source를 제거한다.
- 기존 비대상 source 파일이 변경된 경우 대상 파일에는 결과를 반영하고 source는 로그인 전 값으로 복원한다.
- 결과 후보가 모호한 경우 모든 기존 인증 파일을 복원하고 새 파일을 제거한다.
- 교체와 정리 중 오류가 발생하면 기존 파일을 복원한다.

### `DashboardViewModel` 테스트

- 대상 account ID와 auth profile ID를 가진 재로그인 세션을 시작한다.
- 성공 후 command, nickname, 모델·라우팅, 표시 순서, Usage HUD 설정이 유지된다.
- 비활성화 계정이 재로그인 후에도 비활성화 상태다.
- 취소, OAuth 실패, 모호한 결과에서 기존 카드와 config가 바뀌지 않는다.
- 재로그인 성공은 provider settings 시트를 열지 않고 성공 toast와 configuration work를 사용한다.
- proxy 재적용 실패와 사용량 갱신 실패가 크리덴셜 교체 성공과 구분되어 표시된다.

### SwiftUI 메뉴 계약 테스트

- 연결된 OAuth 계정에서 `Re-login`, Enable/Disable, destructive Remove 순서가 유지된다.
- 비활성화 OAuth 계정에서도 `Re-login`, Enable, destructive Remove 순서가 유지된다.
- `Move Up`과 `Move Down`이 `DashboardView.swift`에 존재하지 않는다.
- API Key 메뉴에 `Re-login`이 없다.
- OAuth 로그인 진행 중 `Re-login` 항목이 비활성화된다.

## 검증

1. 재로그인 트랜잭션과 ViewModel 관련 단위 테스트를 실행한다.
2. 전체 `swift test`를 실행한다.
3. development build를 실행한다.
4. 사용자는 development build에서 실제 OAuth 계정으로 다음을 수동 확인한다.
   - 만료 또는 수동 재로그인 시 `… → Re-login`으로 브라우저 인증을 시작할 수 있다.
   - 재로그인 뒤 동일 카드의 command, nickname, 모델·라우팅, 계정 순서, Usage HUD 표시, 활성화 상태가 유지된다.
   - 브라우저에서 다른 계정으로 로그인한 경우에도 선택한 기존 카드가 그 새 크리덴셜을 사용한다.
   - 일반 Add provider 로그인만 기존처럼 provider settings로 이어진다.

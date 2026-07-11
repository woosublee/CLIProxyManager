# 구독 사용량 자동화 및 메뉴바 진행률 표시 설계

**작성일:** 2026-07-11  
**상태:** 승인됨 — 구현 계획 작성 전 검토 대기

## 배경

CLIProxyManager의 Experimental Subscription Usage 기능은 Claude 및 Codex OAuth 계정의 사용량을 CLIProxyAPI 로컬 관리 API를 통해 조회한다. 기존 구현은 사용자가 Management key를 직접 만들고 저장해야 하며, 메뉴바를 열 때마다 사용량을 즉시 다시 조회한다. 이 때문에 다음 문제가 있다.

- 사용자가 Management key의 목적과 값을 이해·생성·보관해야 한다.
- 키가 없으면 사용량 영역이 완전히 숨겨져 기능이 동작하지 않는 이유를 알기 어렵다.
- 메뉴바 팝오버를 열 때마다 중복 네트워크 요청과 로딩 표시가 발생한다.
- 긴 계정 이름과 사용량 텍스트가 한 줄에 섞여 메뉴바에서 읽기 어렵다.
- 현재 Claude 사용량 미표시는 키가 미설정되어 로컬 관리 API 요청 자체가 시작되지 않은 상태인지, 실제 Claude 조회 문제인지 구분되지 않는다.

## 목표

1. 사용자가 직접 키를 입력하지 않아도 구독 사용량 기능을 안전하게 활성화한다.
2. 기능을 끌 때 관련 Keychain 항목과 프록시 관리 API 설정을 함께 제거한다.
3. 메뉴바 팝오버에서는 최신 캐시를 즉시 보이고, 백그라운드 주기에만 사용량을 재조회한다.
4. 사용량을 계정별 상세 진행률 바로 읽기 쉽게 표시한다.
5. 실제 로컬 프록시를 경유한 Claude/Codex 조회를 검증하고, Claude만 실패할 경우 원인을 분리해 수정한다.

## 범위 밖

- OAuth 토큰을 CLIProxyManager가 직접 읽거나 노출하는 기능
- 구독 한도, 라우팅, 공급자 활성 상태를 변경하는 기능
- 원격 호스트에 CLIProxyAPI 관리 API를 노출하는 기능
- `cpm quota key get`처럼 Keychain 값을 다시 출력하는 기능

## 설계

### Management key 자동 수명주기

Management key는 CLIProxyAPI 로컬 관리 API의 `remote-management.secret-key` 및 그 API를 호출하는 앱의 Bearer 인증에만 사용한다. OAuth 토큰, Anthropic/OpenAI API 키, 일반 프록시 클라이언트 인증에는 재사용하지 않는다.

#### 활성화

사용자가 **Show subscription usage** 토글을 켤 때:

1. Keychain에 키가 없으면 cryptographically secure random bytes로 충분히 긴 새 키를 생성한다.
2. 생성한 키를 기존 Keychain 서비스/계정(`io.woosublee.CLIProxyManager` / `subscription-usage-management-key`)에 저장한다.
3. 구독 사용량 설정을 활성화 상태로 저장한다.
4. 프록시가 실행 중이면 재시작해 생성된 설정의 `remote-management.secret-key`를 적용한다.
5. 프록시가 준비되면 사용량을 한 번 즉시 조회한다.

키가 이미 있으면 유지하고 새로 만들지 않는다. Keychain은 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 접근성으로 저장한다. CLIProxyAPI 설정 파일은 현재처럼 소유자 전용 `0600` 권한으로 작성한다.

#### 비활성화

사용자가 토글을 끌 때:

1. 진행 중인 사용량 조회와 예약 폴링을 취소한다.
2. Keychain의 Management key 항목을 삭제한다.
3. 구독 사용량 설정을 비활성화 상태로 저장한다.
4. 프록시가 실행 중이면 재시작한다.
5. 새 프록시 구성에서는 `remote-management` 블록을 생략해 로컬 관리 API 인증 구성을 제거한다.
6. 메뉴바 계정 행에서 사용량 UI를 즉시 숨긴다.

이 순서는 Keychain의 키와 프록시 구성 중 하나만 남는 시간을 최소화한다. 삭제나 재시작이 실패하면 UI는 성공으로 표시하지 않고 설정 메시지로 오류를 보여 준다.

#### 기존 상태 및 CLI 호환성

- 앱 시작 또는 설정 동기화 시 `subscriptionUsage.isEnabled == true`인데 Keychain 키가 없으면, 활성화된 기능의 복구로 간주하여 키를 자동 생성하고 실행 중 프록시를 재시작한다.
- 기능이 비활성화됐는데 과거 Keychain 키가 남아 있으면 삭제한다.
- SSH/자동화 호환성을 위해 `cpm quota key set --stdin`, `status`, `delete`는 유지한다. GUI 설정에서는 키 입력·교체·삭제 필드를 제거한다.
- GUI 토글을 끄는 동작은 CLI로 입력된 키를 포함해 동일 Keychain 항목을 삭제한다.

### 메뉴바 사용량 표시

사용자 선택은 **계정별 상세 진행률 바**다.

각 연결된 계정 행은 공급자 아이콘과 계정 식별자를 우선 표시하고, 사용량이 있으면 각 사용량 창을 별도 줄에 표시한다.

```text
Claude
woosub@classting.com
5h       [████████░░░░░░░░] 37%
7d       [██████████████░░] 68%
다음 초기화: 오늘 오후 8:42
```

- 기존 `$ functionName`은 메뉴바에서 제거하거나 보조 정보로 축소해 계정명과 사용량에 공간을 우선 배정한다.
- 계정 식별자는 중간 생략 대신 최대 두 줄까지 표시한다.
- Claude 응답의 5h, 7d, 7d Sonnet, 7d Opus, Extra usage와 Codex 응답의 Primary, Secondary 중 실제 응답에 존재하는 모든 창을 표시한다.
- 색상과 접근성 텍스트는 사용률을 모두 전달한다.
  - 0–49%: 기본 파랑
  - 50–79%: 주황
  - 80–100%: 빨강
- 계정의 사용량을 조회할 수 없으면 빈 영역으로 숨기지 않고 계정 아래에 짧고 안전한 원인 메시지를 표시한다. 예: `Usage unavailable — Credential needs attention.`
- 계정 상세 숨김 설정이 켜졌다면 기존 개인정보 보호 동작을 유지하고 `Subscription usage hidden`만 표시한다.

### 재조회 및 캐시 정책

구독 사용량은 상태를 ViewModel에 보관한다. 메뉴바 팝오버는 이 상태를 즉시 렌더링하고, 팝오버를 열었다는 이유만으로 사용량 요청을 발생시키지 않는다.

조회 트리거는 다음과 같다.

1. 앱 시작 후 프록시가 준비된 경우
2. 사용량 기능 활성화 또는 자동 키 생성 후 프록시가 준비된 경우
3. 프록시가 준비 상태로 전환된 경우
4. 이전 조회가 성공한 뒤 5분이 지난 경우

현재의 일시적 실패 재시도 정책은 유지한다.

- 일시 오류는 1분부터 시작해 2배로 증가시키고, 최대 15분으로 제한한다.
- 자격 증명 만료, 비활성화, 관리 API 미지원, 키 거부, 응답 형식 불일치처럼 재시도로 해결되지 않는 오류는 주기 폴링을 멈춘다.
- 조회 작업이 이미 진행 중이면 새 요청을 만들지 않는다.
- 메뉴바 열기 시 일반 서버/계정 상태는 갱신할 수 있으나, 구독 사용량 조회는 시작하지 않는다.

### Claude 사용량 조회 진단

현재 로컬 상태에서 Claude 사용량 미표시는 Management key가 미설정된 탓에 발생한다. 이 상태에서는 앱이 `/v0/management/auth-files` 또는 `/v0/management/api-call` 요청을 전송하지 않으므로 Claude API 자체의 실패로 판단할 수 없다.

자동 키 생성 뒤 실제 개발 빌드 및 로컬 CLIProxyAPI로 아래를 점검한다.

1. Keychain 키 생성 및 프록시 구성의 `remote-management` 적용
2. `/v0/management/auth-files`로 Claude 인증 파일과 `auth_index` 매칭
3. `/v0/management/api-call`을 통한 `https://api.anthropic.com/api/oauth/usage` 요청
4. Claude 사용량 응답의 창·퍼센트·초기화 시각 파싱
5. Codex 조회가 같은 관리 API 경로를 통해 계속 동작하는지 확인

비밀 값은 명령 출력, 로그, 테스트 실패 메시지에 기록하지 않는다. Claude만 실패하면 HTTP 상태와 정규화한 오류 유형으로 다음 원인을 구분한다.

- CLIProxyAPI 관리 API의 지원 여부 또는 계약 변경
- Claude OAuth 자격 증명 만료·비활성화·인증 파일 매칭 실패
- Claude usage 엔드포인트/헤더 계약 변경
- Claude 응답 JSON 구조 변경

확인된 원인에 대응하는 요청 구성 또는 파서를 수정하고 회귀 테스트를 추가한다.

## 컴포넌트 변경 방향

| 영역 | 책임 |
| --- | --- |
| `SubscriptionUsageManagementKeyStore` | 새 키의 안전한 생성, Keychain 저장·조회·삭제 |
| `DashboardViewModel` | 토글 수명주기, 기존 상태 복구, 조회 중복 방지, 메뉴 오픈과 사용량 갱신 분리 |
| `ProxyServiceManager` | 활성 상태에서만 `remote-management.secret-key`를 프록시 구성에 반영 |
| `GeneralSettingsView` | 수동 키 입력 UI 제거, 자동 생성·제거 동작을 설명하는 토글 UI 제공 |
| `MenuBarStatusView` | 계정별 상세 진행률 바, 초기화 시각, 조회 불가 메시지 및 접근성 텍스트 표시 |
| `CLIProxyAPISubscriptionQuotaClient` | 실제 Claude/Codex 관리 API 조회를 진단·검증하고 안전한 오류 상태 반환 |
| 테스트 | Keychain 수명주기, 구성 반영, 폴링, 메뉴바 렌더링, Claude/Codex 파싱 회귀 방지 |

## 오류 처리

- Keychain 생성·저장·삭제 실패: 설정 변경을 성공으로 표시하지 않고 사용자 메시지를 제공한다.
- 프록시 재시작 실패: 키/설정 변경 자체를 롤백하지 않으며, 실패를 표시하고 다음 정상 시작에서 구성을 적용한다.
- 관리 API 인증 실패: 키 값은 노출하지 않고 `managementKeyRejected` 상태만 제공한다.
- OAuth 인증 또는 구독 API 오류: 계정별 상태만 표시하고 다른 계정의 폴링을 불필요하게 중단하지 않는다.
- 응답 계약 오류: 안전한 `schemaMismatch` 상태를 표시하고 재시도하지 않는다.

## 테스트 및 런타임 검증

### 단위 테스트

- 키가 없는 상태에서 토글 활성화 시 키가 생성·저장되는지
- 키가 이미 있을 때 재생성하지 않는지
- 토글 비활성화 시 키가 삭제되고 프록시 구성에서 `remote-management`가 빠지는지
- 기존 `enabled + missing key` 상태의 자동 복구
- 사용량 요청이 진행 중일 때 중복 조회를 방지하는지
- 메뉴바를 열어도 사용량 조회를 시작하지 않는지
- 정상 5분 폴링, 1–15분 재시도 backoff, 비재시도 오류 중단
- Claude/Codex 사용량 창 파싱과 진행률 색상 임계값
- 진행률 바의 접근성 레이블과 계정 상세 숨김 상태

### 개발 앱 검증

1. 개발 구성으로 서명된 앱 번들을 빌드한다.
2. 사용량 토글을 켜서 Keychain 항목과 `remote-management` 구성을 확인한다. 키 값은 출력하지 않는다.
3. 프록시가 준비된 뒤 Claude/Codex 사용량을 실제로 조회하고 메뉴바 진행률 바를 확인한다.
4. 메뉴바 팝오버를 반복으로 열어도 즉시 사용량 요청이 반복되지 않는지 확인한다.
5. 토글을 끄고 Keychain 항목 삭제, 프록시 구성 제거, 메뉴바 사용량 숨김을 확인한다.
6. `cpm quota` 출력도 키·OAuth 토큰을 노출하지 않는지 확인한다.

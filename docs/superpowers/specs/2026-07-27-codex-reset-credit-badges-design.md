# Codex 초기화권 계정 배지 설계

## 배경

Codex는 일부 계정에 rate-limit reset credit을 제공한다. 현재 Codex UI에서는 초기화권의 존재나 대략적인 날짜를 확인할 수 있지만, 사용자가 실제 활용 시점을 계획하는 데 필요한 정확한 만료 시각을 빠르게 확인하기 어렵다.

커뮤니티의 `codex-reset-credits` 참고 구현은 로컬 Codex 인증 세션으로 다음 ChatGPT backend endpoint를 호출해 초기화권 수량과 각 항목의 만료 시각을 확인한다.

```text
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

참고 자료:

- <https://github.com/wisdom-in-a-nutshell/agents/tree/main/skills-source/owned/codex-reset-credits>
- <https://github.com/wisdom-in-a-nutshell/agents/blob/main/skills-source/owned/codex-reset-credits/scripts/check_codex_reset_credits.py>

이 endpoint는 공식 공개 API가 아니라 커뮤니티를 통해 알려진 undocumented ChatGPT backend endpoint다. 따라서 초기화권 조회 오류나 응답 스키마 변경이 기존 subscription usage 조회, cache 또는 UI를 손상하지 않도록 독립적으로 격리해야 한다.

CLIProxyManager는 이미 계정별 Codex OAuth credential을 CLIProxyAPI Management API를 통해 선택하고, `https://chatgpt.com/backend-api/wham/usage`에서 일반 subscription usage를 5분 단위로 조회한다. 초기화권도 같은 credential 선택 경계를 재사용하되, 데이터 특성상 일반 사용량보다 훨씬 낮은 빈도로 조회한다.

## 목표

- 메뉴바 상단 앱 아이콘이 아니라, 메뉴바 팝업에 표시되는 각 Codex OAuth 계정 avatar에 초기화권 개수 배지를 표시한다.
- Expanded HUD와 Compact HUD의 각 Codex OAuth 계정 avatar에도 같은 배지를 표시한다.
- 계정별 수량을 독립적으로 표시하며 여러 계정의 수량을 합산하지 않는다.
- avatar와 배지를 합친 전체 영역에 pointer를 올리면 각 초기화권의 정확한 로컬 만료 일시를 확인할 수 있게 한다.
- 초기화권이 없거나 표시 가능한 마지막 성공 결과가 없으면 배지와 초기화권 tooltip을 표시하지 않는다.
- 배지는 참고 이미지처럼 avatar 우상단 경계를 조금 넘어 겹치되, 채도가 지나치게 높은 빨강 대신 절제된 red glass 스타일을 사용한다.
- 초기화권 자동 조회는 계정별 최대 3시간에 한 번 수행한다.
- 사용자가 `Reload usage`를 실행하면 3시간 throttle과 관계없이 즉시 조회한다.
- 초기화권 endpoint 오류가 일반 subscription usage의 그래프, 상태, polling 또는 cache를 변경하지 않게 한다.
- 마지막 성공 초기화권 결과를 디스크에 저장하고 성공한 background 결과로만 교체한다.
- token, account ID, 사용자 ID, credit ID 또는 raw credential을 화면, cache, 오류 메시지나 로그에 노출하지 않는다.

## 비목표

- 메뉴바 상단 앱 아이콘에 aggregate 배지를 표시하는 기능
- 여러 Codex 계정의 초기화권 수량을 합산하는 기능
- 초기화권을 사용하거나 적용하는 action
- 초기화권 지급 또는 만료에 대한 macOS notification
- 초기화권 전용 설정 toggle이나 상세 화면
- custom hover popover 또는 별도 floating panel
- auth JSON에서 access token을 앱이 직접 읽는 방식
- Claude OAuth, Claude API Key 또는 OpenAI API Key 계정 지원
- 기존 5분 subscription usage polling 주기 변경
- ChatGPT backend endpoint 자체의 안정성이나 공식 지원 보장

## 설계 원칙

### 계정 단위 일관성

초기화권은 Codex account에 귀속된다. 메뉴바 팝업과 HUD 모두 이미 account avatar를 기준으로 정보를 구성하므로 배지는 각 account avatar에만 연결한다. 메뉴바 상단 앱 아이콘이나 화면 전체에 aggregate count를 추가하지 않는다.

### 조회 lifecycle 공유, 결과 상태 분리

초기화권 조회는 기존 Subscription Usage refresh task와 credential 선택 경계를 재사용한다. 하지만 일반 사용량과 초기화권은 서로 다른 endpoint와 응답 계약을 가지므로 마지막 성공 데이터, cache 및 오류 처리는 분리한다. 초기화권만을 위한 별도 polling task는 만들지 않는다.

### 마지막 성공값 보존

일시적인 네트워크 오류, credential 문제 또는 undocumented response schema 변경만으로 마지막 성공 초기화권을 제거하지 않는다. cache와 화면 값은 성공한 결과로만 교체한다. 다만 cache에 남은 항목이 현재 시각에 만료되면 네트워크 호출 없이 화면에서 제외한다.

### 절제된 친숙함

배지는 Apple 알림 배지의 익숙한 위치와 형태를 따르되, 작은 macOS utility UI에서 과도하게 시선을 빼앗지 않도록 반투명 red tint, 얇은 highlight와 작은 shadow만 사용한다. bounce나 강조 animation은 사용하지 않는다.

## 데이터 모델

### 초기화권 항목

서버의 credit ID는 저장하거나 UI에 노출하지 않는다. 화면과 만료 계산에 필요한 redacted 필드만 보존한다.

```swift
public struct CodexResetCredit: Codable, Equatable, Sendable {
    public let title: String?
    public let status: String?
    public let resetType: String?
    public let expiresAt: Date?
    public let grantedAt: Date?
}
```

- `title`: tooltip 행 label에 사용한다.
- `status`: `available` 여부 판단에 사용한다.
- `resetType`: 이후 응답 분석과 deterministic presentation fallback에 사용할 수 있도록 보존한다.
- `expiresAt`: 로컬 만료 필터와 tooltip 시각에 사용한다.
- `grantedAt`: 서버가 제공하는 redacted timestamp로 보존하되 기본 UI에는 표시하지 않는다.

### 계정별 마지막 성공 snapshot

```swift
public struct CodexResetCreditsSnapshot: Codable, Equatable, Sendable {
    public let profileID: String
    public let reportedAvailableCount: Int?
    public let reportedTotalEarnedCount: Int?
    public let credits: [CodexResetCredit]
    public let fetchedAt: Date
}
```

`profileID`는 기존 `AuthProfile.id`와 동일한 app-managed credential file name이다. account ID나 token은 snapshot에 포함하지 않는다.

### 조회 결과

초기화권을 요청하지 않은 profile과 요청했지만 실패한 profile을 구분한다.

```swift
public enum CodexResetCreditsRefreshOutcome: Equatable, Sendable {
    case available(CodexResetCreditsSnapshot)
    case unavailable(CodexResetCreditsIssue)
}
```

`SubscriptionUsageReport`는 일반 사용량 결과와 별도로 요청한 profile의 outcome을 전달한다.

```swift
public struct SubscriptionUsageReport: Equatable, Sendable {
    public let statesByProfileID: [String: AccountSubscriptionUsageState]
    public let resetCreditsOutcomesByProfileID: [String: CodexResetCreditsRefreshOutcome]
    public let fetchedAt: Date
}
```

Dictionary에 key가 없으면 해당 refresh에서 초기화권을 요청하지 않은 것이다. `.unavailable`은 UI에 직접 표시할 상태가 아니라 마지막 성공값 보존 여부를 결정하기 위한 refresh 결과다.

### ViewModel 상태

```swift
@Published private(set) var codexResetCreditsSnapshots:
    [String: CodexResetCreditsSnapshot] = [:]

private var codexResetCreditsLastAttemptAt: [String: Date] = [:]
```

- `codexResetCreditsSnapshots`: 계정별 마지막 성공 snapshot
- `codexResetCreditsLastAttemptAt`: 현재 앱 실행 중 자동 retry throttle에 사용하는 마지막 실제 요청 시각

실패 시각은 디스크에 저장하지 않는다. 앱을 재실행했을 때 성공 cache가 없으면 첫 refresh에서 다시 시도할 수 있다. 성공 cache가 있으면 `fetchedAt`을 자동 조회 기준으로 사용한다.

## Cache

`ManagedPaths`에 초기화권 cache 경로를 추가한다.

```text
codex-reset-credits.json
```

기본 위치는 기존 managed root를 따른다.

- Production: `~/.cliproxy-manager/codex-reset-credits.json`
- Development: `~/.cliproxy-manager/dev/codex-reset-credits.json`

`CodexResetCreditsSnapshotCacheFileStore`는 `[String: CodexResetCreditsSnapshot]`을 atomic write한다.

정책:

- 앱 시작 시 활성 Codex OAuth profile의 성공 snapshot만 복원한다.
- decode 실패 시 빈 cache로 안전하게 시작한다.
- 초기화권 조회 성공 시 해당 profile snapshot만 교체한다.
- 조회 실패 시 기존 snapshot과 cache를 변경하지 않는다.
- profile 제거, 비활성화 또는 subscription usage 전체 비활성화 시 더 이상 활성 대상이 아닌 snapshot을 제거한다.
- token, account ID, user ID, credit ID, raw response 및 오류 본문을 저장하지 않는다.

## 조회 주기와 orchestration

### 자동 조회

기존 subscription usage refresh는 정상 상태에서 5분마다 실행된다. 각 refresh 전에 `DashboardViewModel`이 활성 Codex OAuth profile별 초기화권 요청 대상을 계산한다.

요청 대상 조건:

1. profile이 활성 Codex OAuth account다.
2. subscription usage가 활성화되어 있고 Management key가 설정되어 있다.
3. 해당 profile의 마지막 실제 초기화권 요청으로부터 3시간 이상 지났다.

기준 시각:

- 현재 실행에서 이미 요청한 profile: `codexResetCreditsLastAttemptAt[profileID]`
- 앱 시작 후 아직 요청하지 않았고 cache가 있는 profile: cache snapshot의 `fetchedAt`
- cache도 요청 이력도 없는 profile: 즉시 요청 대상

일반 사용량 refresh가 5분마다 실행되더라도 위 조건을 만족하지 않으면 reset-credit endpoint는 호출하지 않는다.

### 수동 Reload

메뉴바 팝업과 HUD의 `Reload usage`는 기존 `DashboardViewModel.reloadUsage()`를 사용한다. 수동 Reload는 다음 정책을 적용한다.

- 활성 Codex OAuth profile 전체를 초기화권 요청 대상으로 지정한다.
- 마지막 요청 시각과 3시간 throttle을 무시한다.
- 이미 refresh task가 진행 중이면 기존 forced refresh coalescing 정책에 따라 후속 강제 refresh를 예약한다.
- 일반 사용량과 초기화권을 모두 즉시 새로 조회한다.
- 로컬 proxy가 준비되지 않아 기존 `reloadUsage()`가 중단되는 경우 새 직접 credential 경로를 만들지 않는다. 마지막 성공 cache를 유지한다.

### 자동 실패 throttle

실제 reset-credit 요청을 시작한 시점에 `codexResetCreditsLastAttemptAt`을 갱신한다. 자동 요청이 실패해도 같은 앱 실행 중에는 3시간 동안 자동 재시도하지 않는다. 수동 Reload는 이 제한을 항상 무시한다.

## API 요청

기존 `CLIProxyAPISubscriptionQuotaClient`와 CLIProxyAPI Management API를 재사용한다.

```text
POST http://127.0.0.1:<port>/v0/management/api-call
```

Management API에 전달하는 upstream request는 다음과 같다.

```text
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
Authorization: Bearer $TOKEN$
ChatGPT-Account-ID: <AuthProfile.accountID>
originator: Codex Desktop
Accept: application/json
```

동작:

1. 기존 `/v0/management/auth-files` 응답에서 profile file name과 provider가 일치하는 credential의 `auth_index`를 찾는다.
2. `Authorization`에는 앱이 token을 읽지 않고 `$TOKEN$` placeholder를 전달한다.
3. CLIProxyAPI가 선택된 credential에서 placeholder를 실제 token으로 치환한다.
4. `ChatGPT-Account-ID`는 기존 `AuthProfileStore`가 redacted metadata로 읽은 `AuthProfile.accountID`를 요청 header에만 사용한다.
5. `originator`는 참고 구현과 동일하게 `Codex Desktop`을 사용한다.
6. upstream 응답 body는 typed decoder로 전달하고 raw body를 로그에 남기지 않는다.

Account ID가 없으면 reset-credit 요청만 `.unavailable(.accountIDUnavailable)`로 처리한다. 일반 사용량 요청은 기존 계약대로 계속 수행한다.

## Client 인터페이스와 부분 성공

`SubscriptionQuotaFetching`은 refresh마다 reset-credit을 요청할 profile ID 집합을 받는다.

```swift
func fetchUsage(
    port: Int,
    profiles: [AuthProfile],
    resetCreditsProfileIDs: Set<String>
) async -> SubscriptionUsageReport
```

일반 사용량과 초기화권은 credential match 이후 서로의 성공 여부에 의존하지 않고 수행한다. 한 endpoint의 실패 때문에 다른 endpoint 호출을 생략하지 않는다.

| 일반 사용량 | 초기화권 | 적용 결과 |
| --- | --- | --- |
| 성공 | 성공 | 양쪽 최신 성공값 저장 |
| 성공 | 실패 | 사용량만 갱신하고 마지막 초기화권 유지 |
| 실패 | 성공 | 초기화권만 갱신하고 마지막 사용량 유지 |
| 실패 | 실패 | 양쪽 마지막 성공값 유지 |
| 초기화권 cache 없음 + 실패 | 해당 계정 배지 숨김 |

`DashboardViewModel.applySubscriptionUsageReport`는 일반 사용량 상태 merge와 초기화권 outcome merge를 별도 단계로 수행한다. 초기화권 `.available`만 `codexResetCreditsSnapshots`와 cache를 갱신한다. `.unavailable`은 기존 snapshot을 제거하지 않는다.

## 응답 decode

참고 구현에서 확인된 top-level 필드:

- `available_count`
- `total_earned_count`
- `credits`

각 credit에서 사용하는 필드:

- `title`
- `status`
- `reset_type`
- `expires_at`
- `granted_at`

Timestamp는 `Z` suffix, 일반 ISO-8601 offset 및 fractional seconds를 허용한다. 잘못된 개별 timestamp는 전체 raw response를 노출하지 않고 typed schema error로 처리한다.

응답의 credit ID, user ID 또는 알 수 없는 추가 필드는 decode하거나 저장하지 않는다.

## 유효 초기화권 presentation

`CodexResetCreditsPresentation`은 snapshot과 명시적인 `now`를 받아 순수 presentation을 만든다.

```swift
struct CodexResetCreditsPresentation: Equatable {
    let badgeText: String?
    let tooltip: String?
    let accessibilityLabel: String?
    let availableCount: Int
}
```

### 필터 규칙

- `status`를 case-insensitive하게 비교해 `available`인 항목만 사용한다.
- `expiresAt`이 존재하고 `expiresAt <= now`이면 제외한다.
- `expiresAt`이 없는 available 항목은 개수에는 포함하고 tooltip에 `Expiration unavailable`을 표시한다.
- 상세 `credits` 목록을 성공적으로 decode했다면 필터된 목록의 수를 화면 개수로 사용한다.
- 상세 목록이 없지만 `reportedAvailableCount > 0`이면 reported count를 fallback으로 사용하고 `Expiration details unavailable`을 표시한다.
- 최종 `availableCount == 0`이면 badge, tooltip과 reset-credit accessibility 문구를 모두 `nil`로 만든다.

### 배지 문자열

- `1...99`: 실제 숫자
- `100...`: `99+`
- `0`: 배지 숨김

### Tooltip

Avatar와 badge를 합친 전체 영역에 native macOS `.help`를 적용한다.

예시:

```text
2 reset credits available
Full reset · Jul 27, 5:40 PM
Weekly reset · Jul 30, 9:00 AM
```

규칙:

- 앱의 기존 영어 UI와 일치하는 영어 문구를 사용한다.
- 시스템 로컬 timezone으로 분 단위까지 표시한다.
- `title`에서 첫 ` (` 이후의 suffix를 제거한다.
- title이 비어 있으면 `Reset credit`을 사용한다.
- expiration이 없으면 `Expiration unavailable`을 사용한다.
- fallback count만 있고 상세 목록이 없으면 `Expiration details unavailable`을 사용한다.
- 같은 의미의 전체 문장을 VoiceOver accessibility label로 제공한다.

## 시각 설계

### 위치와 형태

사용자가 제공한 참고 이미지처럼 badge는 avatar 우상단 경계를 약간 넘어 겹친다.

- 한 자리 숫자: 원형
- 두 자리 이상: 최소 원형 높이를 유지하며 가로로 늘어나는 capsule
- 일반 layout 흐름에 참여하지 않는 `overlay`
- 계정 행의 intrinsic width와 height를 변경하지 않음
- avatar 바깥으로 약 3~4pt 이동하되 계정명과 충돌하지 않도록 화면별 offset 조정

권장 크기:

- 메뉴바 팝업 22pt avatar: badge 최소 높이 약 14pt
- Expanded HUD 20pt avatar: badge 최소 높이 약 14pt
- Compact HUD 26pt avatar: badge 최소 높이 약 15pt

### Glass 스타일

프로젝트 최소 지원 버전인 macOS 15에서 동작하도록 최신 macOS 전용 `glassEffect` API에 의존하지 않는다.

구성:

- capsule 또는 circle 내부의 thin material
- `BrandPalette.statusError`를 기반으로 한 낮은 채도의 반투명 red tint
- 상단에 매우 약한 white highlight
- 약 0.5pt의 밝은 내부 stroke
- avatar와 분리되는 작은 soft shadow
- 흰색 rounded semibold 숫자와 `monospacedDigit()`
- Light/Dark appearance에서 숫자 대비가 유지되는 opacity 범위

과도한 glow, 고채도 solid red, 반복 pulse와 bounce는 사용하지 않는다. Count 변경은 필요한 경우 짧은 opacity transition만 허용하며 Reduce Motion에서는 즉시 교체한다.

## 화면별 적용

### 메뉴바 팝업

`MenuBarAccountRow`의 `ProviderAvatar` 우상단에 해당 account의 badge를 표시한다.

- 메뉴바 상단 `MenuBarExtra` label은 변경하지 않는다.
- `subscriptionUsage.showInMenuBar == false`이면 badge도 menu bar popup에서 숨긴다.
- Codex OAuth account만 대상이다.

### Expanded HUD

`ExpandedUsageOverlayAccountView`의 account avatar 우상단에 badge를 표시한다.

- HUD에 포함된 account만 대상이다.
- 기존 provider name, command name, usage progress layout을 변경하지 않는다.

### Compact HUD

`CompactUsageAccountView`의 26pt avatar 우상단에 badge를 표시한다.

현재 compact stale warning이 avatar trailing 영역에 overlay되므로 장식 위치를 명시적으로 분리한다.

- reset-credit badge: 우상단
- usage warning indicator: 우하단
- 둘 중 하나만 존재해도 각 장식 위치가 움직이지 않음
- 둘 다 일반 layout 크기를 늘리지 않음
- placeholder indicator 정책은 변경하지 않음

### 공통 avatar hover 영역

작은 badge만 정확히 가리킬 필요가 없도록 avatar와 badge를 감싼 decoration container 전체에 tooltip과 accessibility label을 적용한다. 유효 초기화권이 없으면 기존 avatar 동작과 help만 유지하고 reset-credit tooltip을 추가하지 않는다.

## 만료 시각 갱신

새 네트워크 요청 없이도 cache의 항목이 정해진 시각에 화면에서 사라져야 한다.

- `MenuBarStatusView`는 기존 분 단위 `refreshAgeReferenceDate`를 presentation의 `now`로 전달한다.
- `UsageOverlayView`는 기존 분 단위 `refreshStatusReferenceDate`를 Expanded/Compact content에 전달한다.
- presentation은 항상 전달된 `now`로 유효 credit 목록을 다시 계산한다.
- 만료 경계는 `expiresAt <= now`일 때 즉시 제외하는 것으로 정의한다.

따라서 최대 약 1분 이내에 만료된 credit이 badge와 tooltip에서 사라진다. 새 credit 지급이나 사용으로 인한 서버 수량 변화는 다음 3시간 자동 조회 또는 수동 Reload에서 반영된다.

## 오류 처리

초기화권 전용 issue는 일반 subscription usage issue와 분리한다.

예상 범주:

- `accountIDUnavailable`
- `credentialRejected`
- `endpointUnsupported`
- `schemaMismatch`
- `transientFailure`

정책:

- 401/403: reset-credit credential issue로만 기록
- 404/405/501: endpoint unsupported로 처리
- 429/5xx, timeout, network 오류: transient failure
- malformed JSON 또는 필수 top-level 계약 불일치: schema mismatch
- 모든 오류에서 일반 usage state, graph, warning 및 polling schedule은 변경하지 않음
- 마지막 성공 reset-credit snapshot이 있으면 아직 만료되지 않은 항목을 계속 표시
- 마지막 성공 snapshot이 없으면 badge를 숨김
- reset-credit 오류를 위한 별도 warning icon이나 사용자-facing 오류 문구는 추가하지 않음
- raw response body, token, account ID와 credential contents를 오류 메시지나 로그에 포함하지 않음

## 구성 요소 경계

- `CodexResetCreditsModels`: redacted model과 typed issue
- `CLIProxyAPISubscriptionQuotaClient`: 기존 credential match를 사용한 선택적 reset-credit request와 decode
- `SubscriptionUsageReport`: 일반 사용량과 독립적인 reset-credit refresh outcome 전달
- `CodexResetCreditsSnapshotCacheFileStore`: 마지막 성공 snapshot 영속화
- `DashboardViewModel`: 3시간 대상 선택, forced reload, outcome merge와 account lifecycle 정리
- `CodexResetCreditsPresentation`: 현재 시각 기준 count, tooltip과 accessibility 생성
- `CodexResetCreditBadge`: 공통 red glass badge 렌더링
- `MenuBarAccountRow`, `ExpandedUsageOverlayAccountView`, `CompactUsageAccountView`: 화면별 avatar decoration 배치만 담당

Network policy, cache policy와 유효 항목 계산을 SwiftUI view에 중복 구현하지 않는다.

## 테스트 전략

### Core client 테스트

1. reset-credit endpoint URL과 `GET` method가 정확하다.
2. `Authorization: Bearer $TOKEN$`을 사용한다.
3. `ChatGPT-Account-ID`에 대상 `AuthProfile.accountID`를 넣는다.
4. `originator: Codex Desktop`과 `Accept: application/json`을 전달한다.
5. 선택된 credential의 `auth_index`를 사용한다.
6. Claude profile과 요청 대상이 아닌 Codex profile에는 reset-credit 요청을 보내지 않는다.
7. account ID가 없으면 token이나 credential file을 직접 읽지 않고 typed failure를 반환한다.
8. 일반 usage 성공과 reset-credit 실패를 부분 성공으로 반환한다.
9. 일반 usage 실패와 reset-credit 성공도 독립적으로 반환한다.
10. ISO-8601 `Z`, offset 및 fractional timestamp를 decode한다.
11. `available_count`, `total_earned_count`와 redacted credit 필드를 보존한다.
12. malformed reset-credit response가 일반 usage 결과를 손상하지 않는다.
13. 오류 표현에 token, account ID, raw response 또는 credit ID가 포함되지 않는다.

공개 테스트 fixture의 email은 프로젝트 정책에 따라 `example.com` 기반 식별자만 사용한다.

### ViewModel과 cache 테스트

1. cache와 요청 이력이 없으면 첫 refresh에서 조회한다.
2. 마지막 요청 후 3시간 미만이면 자동 조회를 생략한다.
3. 정확히 3시간이 지나면 다음 refresh에서 조회한다.
4. 자동 조회 실패도 같은 실행 중 3시간 동안 재시도하지 않는다.
5. 수동 `Reload usage`는 3시간 throttle을 무시한다.
6. 진행 중 refresh가 있을 때 forced refresh coalescing을 유지한다.
7. reset-credit 성공 결과만 snapshot과 cache를 교체한다.
8. reset-credit 실패 시 기존 snapshot과 cache를 유지한다.
9. 3시간 이내 성공 cache를 앱 시작 시 즉시 복원하고 자동 호출을 생략한다.
10. 3시간 이상 된 cache는 표시하면서 첫 refresh의 조회 대상이 된다.
11. profile 제거·비활성화와 subscription usage 비활성화 시 대상 cache를 정리한다.
12. Claude와 API Key provider row에는 reset-credit snapshot을 연결하지 않는다.

### Presentation 테스트

1. `available` status만 표시한다.
2. `expiresAt <= now`인 항목을 제외한다.
3. expiration이 없는 available 항목을 count에 포함하고 fallback 문구를 만든다.
4. 유효 항목이 0개면 badge와 tooltip을 숨긴다.
5. `1...99`는 실제 숫자, 100 이상은 `99+`다.
6. tooltip에 각 title과 로컬 만료 시각이 분 단위로 표시된다.
7. title이 없으면 `Reset credit`을 사용한다.
8. title의 첫 ` (` 이후 suffix를 제거한다.
9. 상세 목록이 없을 때 reported count와 `Expiration details unavailable`을 사용한다.
10. tooltip과 accessibility label이 같은 정보를 완전한 문장으로 전달한다.

### View와 layout 테스트

1. menu bar popup의 Codex account avatar에만 badge가 표시된다.
2. 메뉴바 상단 app icon label은 변경되지 않는다.
3. Expanded HUD와 Compact HUD가 같은 presentation을 사용한다.
4. badge overlay가 account row의 intrinsic size를 변경하지 않는다.
5. Compact HUD에서 badge는 우상단, usage warning은 우하단에 함께 표시된다.
6. 하나의 decoration만 존재해도 위치가 바뀌지 않는다.
7. avatar 전체 영역에 tooltip과 accessibility label을 적용한다.
8. Light/Dark appearance에서 숫자 대비가 유지된다.
9. Reduce Motion에서 count 변경의 불필요한 motion이 제거된다.

### 전체 검증

- 관련 targeted tests
- 전체 `swift test`
- `git diff --check`
- development configuration 앱 bundle 생성
- 생성된 bundle의 실행 파일과 필수 resource 존재 확인

실제 undocumented endpoint 응답과 최종 hover·glass 시각 품질은 사용자가 development build를 실행해 확인한다. 자동 검증 과정은 token, account ID, credit ID 또는 raw credential을 출력하지 않는다.

## 완료 기준

- 메뉴바 팝업과 Expanded/Compact HUD의 각 Codex OAuth account avatar에 독립적인 초기화권 badge가 표시된다.
- 메뉴바 상단 앱 아이콘은 변경되지 않는다.
- 여러 account의 수량을 합산하지 않는다.
- badge는 avatar 우상단에 겹치며 절제된 반투명 red glass 스타일을 사용한다.
- avatar 전체 hover에서 각 유효 초기화권의 로컬 만료 시각을 분 단위로 확인할 수 있다.
- 유효 초기화권이 없으면 badge와 reset-credit tooltip이 모두 사라진다.
- 자동 조회는 account별 최대 3시간에 한 번 수행된다.
- 수동 `Reload usage`는 throttle을 무시하고 즉시 조회한다.
- 초기화권 조회 성공과 실패가 일반 subscription usage 성공과 실패에서 독립적으로 병합된다.
- 초기화권 오류가 기존 usage graph, warning, cache 또는 polling을 손상하지 않는다.
- 마지막 성공값은 cache에서 복원되고 성공한 결과로만 교체된다.
- 만료된 cache 항목은 네트워크 조회 없이 최대 약 1분 내 화면에서 제외된다.
- 관련 단위 테스트, 전체 Swift test suite와 development build가 통과한다.

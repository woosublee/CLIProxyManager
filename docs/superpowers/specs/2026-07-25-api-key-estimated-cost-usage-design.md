# API Key 예상 비용 사용량 설계

## 배경

CLIProxyManager는 현재 Claude·Codex OAuth 계정의 구독 사용량을 메뉴바, 확장형 Usage HUD, 미니 Usage HUD에 표시한다. 이 경로는 CLIProxyAPI의 범용 Management API 호출 기능을 사용해 provider별 구독 사용량 API를 조회하며, 계정별 사용률과 초기화 시각을 `SubscriptionUsageSnapshot`으로 보관한다.

Claude API Key와 OpenAI/Codex API Key 계정은 같은 계정 목록에 나타나지만 구독 quota가 없으므로 현재 사용량 영역을 표시하지 않는다. 반면 번들된 CLIProxyAPI `v7.2.97`은 요청별 token accounting을 `/v0/management/usage-queue`에 제공한다.

CLIProxyAPI `v7.2.97`의 관련 특성은 다음과 같다.

- `usage-statistics-enabled: true`일 때 요청별 usage 레코드를 queue에 적재한다.
- `GET /v0/management/usage-queue?count=N`은 오래된 레코드부터 destructive pop한다.
- queue 보존 기간은 기본 60초이며 `redis-usage-queue-retention-seconds`로 최대 3,600초까지 설정할 수 있다.
- 레코드에는 provider, model, alias, `auth_type`, `auth_index`, timestamp, 성공 여부, request ID, service tier와 token 정보가 포함된다.
- `token_breakdown.schema_version == 2`는 input을 uncached/cache-read/cache-write로, output을 non-reasoning/reasoning으로 정규화한다.
- `token_breakdown.quality`는 `complete`, `unclassified`, `inconsistent` 중 하나다.
- 레코드에는 원본 `api_key`도 포함되므로 수집 경계에서 특별한 보안 처리가 필요하다.
- CLIProxyAPI는 token을 제공하지만 달러 비용은 계산하지 않는다.

따라서 API Key 비용을 표시하려면 CLIProxyManager가 queue를 지속적으로 소비하고, token을 로컬 ledger에 누적하고, provider별 가격표로 예상 비용을 산출해야 한다.

## 목표

- Claude API Key와 OpenAI/Codex API Key 요청의 token 사용량을 CLIProxyAPI `usage-queue`에서 수집한다.
- API Key 계정별 `Day`와 `Mon` 예상 비용을 메뉴바, 확장형 HUD, 미니 HUD에 표시한다.
- OAuth 계정은 기존 구독 사용률을 유지하고 API Key 계정은 예상 비용을 표시하여 같은 계정 목록 안에서 지표를 전환한다.
- 화면 높이와 정보 밀도를 기존 subscription usage 행에 최대한 맞춘다.
- 원본 요청 이벤트나 API key를 저장하지 않고, 가격 재계산에 필요한 일별 token 합계만 저장한다.
- 가격표 변경이나 계산 오류를 수정한 뒤에도 과거 예상 비용을 다시 계산할 수 있게 한다.
- 일시적인 수집 오류가 발생해도 마지막 성공 금액을 유지하고, 불완전성은 경고로 표현한다.
- 기능을 중간에 켰거나 수집 공백이 발생한 경우 관측된 금액은 유지하면서 `partial` 상태를 명확히 표시한다.
- 현재 번들된 CLIProxyAPI `v7.2.97`의 accounting contract를 명시적으로 검증한다.

## 비목표

- OAuth 구독 계정을 종량제 비용으로 환산하는 기능
- Anthropic 또는 OpenAI의 공식 invoice·credit balance·예산을 조회하는 기능
- 세금, 계약 할인, 프로모션 credit, 조직별 negotiated pricing 반영
- Bedrock, Vertex AI, Microsoft Foundry 또는 임의의 OpenAI-compatible provider 비용 계산
- web search, code execution 등 token 외 별도 도구 요금의 완전한 계산
- Message Batches 할인 계산
- 사용자가 가격표를 직접 편집하는 UI
- 주간 그래프, 예산 알림, 월말 예상치, CSV export
- 시간대 선택 또는 기존 ledger의 시간대 재분할 UI
- 여러 Claude API Key 또는 여러 OpenAI API Key를 각각 별도 계정으로 표시하는 기능
- CLIProxyAPI의 queue 전달 보장이나 schema 자체를 변경하는 작업

## 용어

- **Usage 표시 활성화:** 메뉴바의 usage 표시 또는 Usage HUD 중 하나 이상이 켜진 상태
- **API cost tracking:** CLIProxyAPI usage queue를 소비하고 API Key token ledger를 갱신하는 동작
- **Day:** 저장된 reporting time zone의 오늘 00:00부터 현재까지
- **Mon:** 저장된 reporting time zone의 이번 달 1일 00:00부터 현재까지
- **Estimated cost:** 공식 청구액이 아니라 CLIProxyAPI에서 관측한 token과 번들 가격표로 계산한 예상 USD 비용
- **Complete period:** 해당 기간 전체에서 collector가 동작했거나 proxy가 중지되어 요청이 발생할 수 없었음이 확인된 기간
- **Partial period:** 추적 시작 전 시간, 추적 비활성 구간, queue 보존 기간을 초과한 수집 공백 또는 미계산 요청이 포함된 기간

## 1. 화면별 정보 계층

### 공통 원칙

- 전체 합계 카드는 추가하지 않고 **계정별 값만** 표시한다.
- OAuth와 API Key 계정을 별도 섹션으로 나누지 않는다.
- OAuth 계정은 기존 usage percentage를, API Key 계정은 예상 비용을 표시한다.
- 모든 화면에서 API Key 계정에 `Day`와 `Mon` 두 행을 제공한다.
- 비용에는 상한이 없으므로 progress bar나 비율처럼 보이는 장식을 사용하지 않는다.
- UI에는 `Estimated cost`임을 tooltip과 접근성 문구에서 명시한다.
- 표시 currency는 초기 버전에서 USD로 고정한다.

### 메뉴바

기존 계정 행 아래의 subscription usage 영역과 같은 폭과 두 행 높이를 사용한다.

```text
Claude API
Day                         $0.42
Mon                         $8.73
```

- 왼쪽에는 `Day`와 `Mon`, 오른쪽에는 비용을 정렬한다.
- token과 요청 수는 메뉴바에 표시하지 않는다.
- partial 또는 pricing issue가 있으면 기존 usage warning과 같은 작은 경고 아이콘을 계정 usage 영역에 표시한다.
- warning tooltip에는 불완전한 이유, 마지막 성공 갱신 시각, 시간대와 정확한 기간을 포함한다.

### 확장형 Usage HUD

기존 progress bar가 차지하던 중앙 영역에 실제 보조 정보를 배치한다.

```text
Claude API
Day    84K TOK · 14 REQ             $0.42
Mon    1.8M TOK · 218 REQ           $8.73
```

- 왼쪽 label과 오른쪽 비용 위치는 기존 subscription usage 행의 문법을 따른다.
- 중앙 영역에는 token 합계와 요청 수만 표시한다.
- token 합계는 input과 output을 합친 `token_breakdown.total_tokens` 기준이다.
- progress bar 모양의 배경이나 장식은 넣지 않는다.
- 정확한 날짜 범위는 tooltip에서 제공한다.

```text
Jul 25, 00:00–now · Asia/Seoul
Estimated API cost from requests observed through CLIProxyAPI.
```

- partial 상태이면 같은 tooltip에 누락 가능 구간과 미계산 요청 수를 추가한다.

### 미니 Usage HUD

기존 compact usage와 같은 `label / value` 2열 구조를 유지한다.

```text
Claude API
Day        $0.42
Mon        $8.73
```

- token과 요청 수는 표시하지 않는다.
- warning icon은 기존 compact usage의 avatar/header warning 배치를 재사용한다.

### 헤더와 새로고침 문구

혼합 지표를 포괄하도록 확장형 HUD의 `Subscription Usage` 제목을 `Usage`로 변경한다.

기존 `Reload usage` 동작은 유지하되 내부적으로 두 작업을 함께 수행한다.

```text
Reload usage
├─ OAuth subscription quota refresh
└─ API usage queue immediate drain
```

`UPDATED` 시각은 현재 화면에 표시되는 subscription snapshot과 API cost snapshot의 **가장 오래된 마지막 성공 시각**을 사용한다. 일부 데이터만 최신인데 전체가 최신인 것처럼 표시하지 않는다.

### 숫자 formatting

- 정확히 0달러: `$0.00`
- 0보다 크고 0.01달러보다 작음: `<$0.01`
- 0.01달러 이상: 소수점 둘째 자리까지 표시
- tooltip: 최소 소수점 넷째 자리까지 제공하여 작은 차이를 확인할 수 있게 함
- token: `84K`, `1.8M`처럼 compact decimal 표기
- request: 정수 표기
- 접근성 label은 축약어를 풀어 읽는다.

## 2. Usage 표시와 추적 활성화 정책

별도 `Track API cost` toggle은 추가하지 않는다. 기존 Usage 표시 설정과 연동한다.

### 활성화 조건

`menu bar usage == on` 또는 `Usage HUD == on`이면 Usage 기능이 활성화된다.

- OAuth profile이 있으면 기존 subscription quota polling을 수행한다.
- Claude 또는 OpenAI API Key가 있으면 API cost tracking을 수행한다.
- API Key가 하나도 없으면 usage statistics queue와 collector는 활성화하지 않는다.
- Usage 표시가 모두 꺼지면 quota polling과 API collector를 중지한다.

### CLIProxyAPI 설정

Usage 표시가 활성화되고 API Key가 하나 이상 있으면 생성되는 `config.yaml`에 다음을 추가한다.

```yaml
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 3600
```

Management key가 준비된 경우 기존 `remote-management.secret-key`도 함께 생성한다.

- enable/disable 전환으로 생성 설정이 바뀌면 기존 방식대로 실행 중인 CLIProxyAPI를 재시작한다.
- API Key 추가·삭제도 설정과 collector 대상이 바뀌므로 기존 proxy configuration restart 경로를 사용한다.
- Usage 표시를 끄면 다음 config 생성에서 usage statistics를 제거하고 management key도 기존 정책대로 정리한다.
- API usage ledger는 Usage 표시를 꺼도 삭제하지 않는다.
- 다시 켤 때 비활성 구간에 proxy 요청이 발생할 수 있었다면 해당 Day/Mon을 partial로 표시한다.

### 설정 copy

```text
Show subscription usage
→ Show usage
```

```text
Show Claude and Codex account usage beneath connected accounts in the menu bar.
→ Show subscription usage or estimated API cost beneath connected accounts in the menu bar.
```

Footer에는 다음 의미를 포함한다.

```text
Usage data is collected while either usage display is enabled.
API cost estimates include only requests observed through CLIProxyAPI.
```

기존 persisted JSON의 `subscriptionUsage` key는 compatibility를 위해 이름을 바꾸지 않는다. UI copy와 코드의 계산 property만 더 넓은 의미의 `Usage`로 전환한다.

## 3. 수집 구조

### 데이터 흐름

```text
CLIProxyAPI /v0/management/usage-queue
        ↓
CLIProxyAPIUsageQueueClient
        ↓
APIUsageCollector
        ↓
record validation + profile mapping
        ↓
APIUsageLedgerStore
        ↓
APICostEstimator + APIPriceCatalog
        ↓
ProviderUsageState
        ↓
메뉴바 · 확장형 HUD · 미니 HUD
```

### `CLIProxyAPIUsageQueueClient`

책임:

- local Management API에 `GET /v0/management/usage-queue?count=200` 요청
- response array decode
- HTTP·authorization·schema 오류를 typed error로 변환
- raw response body 또는 decode 실패 payload를 로그에 남기지 않음

수집은 batch 단위로 동작한다.

1. `count=200`으로 요청한다.
2. 200개가 반환되면 즉시 다음 batch를 요청한다.
3. 200개보다 적으면 현재 drain을 종료한다.
4. 한 번의 pass가 과도하게 길어지지 않도록 최대 처리량을 두고, 남은 queue는 즉시 다음 pass에서 계속 소비한다.

`usage-queue`는 응답 전에 이미 레코드를 pop하므로 client-side acknowledgement가 없다. 이 기능은 exactly-once를 보장할 수 없으며 공식 billing source가 될 수 없다.

### 좁은 decode model

CLIProxyAPI 레코드의 `api_key`, request ID, `auth_index` 원문, failure body, response headers는 Swift model의 stored `String` property로 선언하지 않는다. `JSONDecoder`가 unknown key를 건너뛰도록 하여 API key를 `String`으로 materialize하지 않으며, `auth_index`는 custom decode scope에서 non-empty 여부만 `hasAuthIndex: Bool`로 파생한 뒤 원문을 즉시 폐기한다.

수집에 필요한 필드만 decode한다.

```text
timestamp
provider
executor_type
model
alias
auth_type
auth_index의 non-empty 여부를 나타내는 `hasAuthIndex` Boolean
failed
accounting_version
token_breakdown
service_tier
response_service_tier
```

HTTP response `Data`에는 upstream JSON 특성상 API key bytes가 잠시 존재하므로 다음 원칙을 적용한다.

- response body를 debug log에 출력하지 않음
- error description에 body를 포함하지 않음
- request 처리 scope 밖으로 raw `Data`를 보관하지 않음
- disk cache, diagnostics, crash breadcrumb에 raw payload를 전달하지 않음

### `APIUsageCollector`

actor 또는 동등한 serialized component로 구현한다.

- 동시에 두 drain이 실행되지 않게 한다.
- Usage 활성화·proxy ready·API Key 존재 조건을 확인한다.
- 활성 상태에서 30초마다 local queue를 drain한다.
- 앱 시작, proxy ready 전환, API Key 변경, `Reload usage`에서 즉시 drain한다.
- transient failure는 backoff하되 1시간 retention 안에 재시도한다.
- collector가 정상 중지될 때 pending ledger write를 flush한다.

30초 주기는 local HTTP 요청만 발생시키며, UI를 거의 실시간으로 갱신하면서 1시간 retention보다 충분히 짧다. 구현 계획 단계에서 테스트 가능하도록 sleep과 clock을 주입한다.

### 허용하는 레코드

비용 ledger에 반영하려면 다음을 모두 만족해야 한다.

- `auth_type`을 정규화했을 때 API key credential임. CLIProxyAPI `v7.2.97`의 실제 값은 `"apikey"`이며, forward compatibility를 위해 `"api_key"`와 `"api-key"`도 같은 값으로 허용한다.
- app-managed Claude API Key 또는 OpenAI/Codex API Key provider와 매칭
- `accounting_version == 2`
- `token_breakdown.schema_version == 2`
- 모든 token 값이 음수가 아님
- input/output/total 합계 invariant가 맞음

OAuth 레코드는 비용 ledger에서 제외한다.

`token_breakdown.quality` 처리:

- `complete`: token ledger에 반영
- `unclassified`: 금액에는 반영하지 않고 issue count 기록
- `inconsistent`: 금액에는 반영하지 않고 issue count 기록

`failed == true`여도 complete token이 있으면 provider에서 과금될 수 있으므로 token 비용에 포함한다. `failedRequestCount`는 별도 누적한다.

### profile 매핑

현재 앱의 API Key는 provider별 singleton profile이다.

- Claude API Key → stable profile ID `claude-api`
- OpenAI/Codex API Key → stable profile ID `codex-api`

`provider`, `executor_type`, app-managed prefix와 `hasAuthIndex == true`를 함께 검증하여 잘못된 provider 레코드가 다른 profile에 섞이지 않게 한다. `auth_index` 원문과 원본 credential은 queue decode scope 밖에 보관하지 않으며 ledger에도 저장하지 않는다.

API key를 교체해도 같은 provider profile의 연속된 사용량으로 취급한다. 초기 버전은 credential별 비용 분리를 제공하지 않는다.

### 중복 방지 경계

queue가 destructive pop이므로 collector가 같은 HTTP response를 ledger에 두 번 merge하지 않도록 한 drain pass를 serialized 처리한다. 원본 `request_id`의 장기 집합은 저장하지 않는다.

- 동시 drain 금지
- batch decode 후 ledger merge를 한 번만 호출
- ledger merge 성공 전후의 task cancellation 경계를 명확히 함
- 정상 종료 시 pending write flush

프로세스가 queue pop 직후 ledger persist 전에 비정상 종료하면 마지막 짧은 debounce 구간의 요청은 손실될 수 있다. UI가 `Estimated cost`이고 queue에 ack protocol이 없다는 점을 문서화하며, debounce는 1–2초 수준으로 제한한다.

## 4. Ledger 저장 모델

### 경로

`ManagedPaths`에 다음 경로를 추가한다.

```text
~/.cliproxy-manager/api-usage/metadata.json
~/.cliproxy-manager/api-usage/YYYY-MM.json
```

DEBUG build는 기존 `ManagedPaths.defaultRootDirectory()` 정책에 따라 `~/.cliproxy-manager/dev/api-usage/`를 사용한다.

### metadata

```swift
struct APIUsageTrackingMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var reportingTimeZoneID: String
    var trackingStartedAt: Date
    var lastSuccessfulDrainAt: Date?
    var lastObservedRequestAt: Date?
    var collectorPausedAt: Date?
    var partialIntervals: [APIUsagePartialInterval]
}
```

`partialIntervals`는 다음 원인을 구분한다.

- tracking started mid-period
- usage display disabled while proxy could serve requests
- collector gap exceeded queue retention
- ledger persistence failure
- damaged ledger recovery

완료된 오래된 interval은 해당 month file과 함께 정리할 수 있지만, 현재 Day/Mon의 completeness 판단에 필요한 범위는 유지한다.

### 월별 파일

```swift
struct APIUsageMonthlyLedger: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let month: String
    let reportingTimeZoneID: String
    var buckets: [APIUsageLedgerBucket]
    var issues: [APIUsageLedgerIssueBucket]
}
```

bucket key:

```text
local date
+ profile ID
+ provider
+ model
+ effective service tier
+ pricing variant
+ price epoch start (`effectiveFrom`)
```

저장 값:

```text
uncached input tokens
cache read tokens
cache write tokens
non-reasoning output tokens
reasoning output tokens
total tokens
request count
failed request count
first observed timestamp
last observed timestamp
```

`effective service tier`는 `response_service_tier`가 있으면 우선 사용하고, 없으면 `service_tier`를 사용한다.

`pricing variant`는 token 단가를 바꾸는 요청 속성을 표현한다. 초기 지원값은 standard, OpenAI/Codex priority, 272,000 input token을 초과한 standard long-context 계열이다. queue에서 확실히 식별할 수 없는 variant는 known standard로 추정하지 않고 issue로 남긴다.

`price epoch start`는 request timestamp에 매칭된 catalog entry의 `effectiveFrom`이다. 같은 local date 안에서 가격이나 프로모션이 바뀌어도 서로 다른 bucket에 누적되게 한다.

### issue bucket

완전한 token bucket으로 저장할 수 없는 레코드는 raw event 대신 날짜·profile·원인별 count만 누적한다.

```text
unsupported accounting version
unclassified token accounting
inconsistent token accounting
unknown provider mapping
unknown model
unsupported service tier
unknown pricing variant
price epoch unavailable
```

unknown model, service tier, pricing variant와 price epoch unavailable은 token bucket 자체는 보존할 수 있으므로 가격표 조회 시 issue로 계산한다. `priceEpochUnavailable`은 model·tier·variant entry는 존재하지만 request timestamp에 `effectiveFrom <= timestamp < effectiveUntil`을 만족하는 entry가 없는 경우다. accounting이 불완전하여 상호 배타적인 token bucket을 신뢰할 수 없는 경우에만 count-only issue bucket을 사용한다.

### 저장 원칙

- 요청별 원본 event를 저장하지 않는다.
- API key, auth index, request ID, endpoint, failure body, response headers를 저장하지 않는다.
- token은 정수로 저장한다.
- 금액은 ledger에 저장하지 않고 조회 시 계산한다.
- batch merge 후 1–2초 debounce하여 atomic replacement한다.
- 임시 파일을 같은 directory에 쓴 뒤 replace한다.
- directory는 owner-only, file은 owner read/write 권한으로 생성한다.
- metadata/month write는 owner-only process lock 아래에서 현재 target schema를 다시 확인한 뒤 수행한다. cache 이후 target이 future schema로 교체되었으면 overwrite하지 않는다.
- 손상된 파일은 원문을 log에 출력하지 않고 `RENAME_EXCL` 동등 semantics로 기존 destination을 교체하지 않는 별도 backup 이름으로 이동한 뒤 해당 기간을 partial로 표시한다.
- atomic batch merge가 overflow로 전체 candidate를 폐기하면 commit되지 않은 모든 mutation의 local day를 persistence partial로 표시한다.

금액을 저장하지 않으므로 동일한 price epoch의 rate 오류를 수정하거나 가격표를 보강한 뒤 과거 예상 비용을 다시 계산할 수 있다. 이미 집계한 뒤 price boundary 자체를 변경하는 경우에는 요청별 시각을 보존하지 않으므로 완전한 재분할을 보장하지 않으며, 영향을 받는 기간을 partial로 표시한다.

## 5. 가격표와 비용 계산

### `APIPriceCatalog`

가격표는 app bundle에 포함된 versioned static data로 관리한다.

기본 lookup 차원:

```text
provider
+ exact model ID
+ effective service tier
+ pricing variant
+ effective start timestamp
```

각 entry는 다음 rate를 가질 수 있다.

```text
uncached input USD / 1M tokens
cache read USD / 1M tokens
cache write USD / 1M tokens
output USD / 1M tokens
```

가격 변경과 기간 한정 프로모션을 표현하기 위해 `effectiveFrom`과 선택적 `effectiveUntil`을 지원한다. 예를 들어 특정 모델의 introductory price 종료를 과거 ledger 재계산에도 정확히 적용한다.

모델 family prefix가 비슷하다는 이유로 임의의 단가를 적용하지 않는다. exact model ID 또는 catalog에 명시된 canonical alias 규칙만 허용한다. Queue model 정규화는 provider와 일치하는 app-managed routing prefix(`cpm-claude-api/`, `cpm-codex-api/`)와 `CodexFastMode`가 검증하는 managed `-fast` alias·알려진 reasoning suffix만 제거한다. 알 수 없는 routing prefix, 괄호 suffix 또는 provider와 불일치하는 managed prefix는 원문을 유지해 unknown/unpriced 처리한다.

가격표 source는 release 시점의 공식 provider 문서다.

- Anthropic pricing: `https://platform.claude.com/docs/en/about-claude/pricing`
- OpenAI API pricing: `https://developers.openai.com/api/docs/pricing`

가격표 update는 앱 release 또는 별도 명시적 update 기능으로 수행하며, 초기 버전에는 네트워크에서 가격표를 자동 다운로드하지 않는다.

### 계산식

Claude:

```text
uncached input × uncached input rate
+ cache read × cache read rate
+ cache write × cache write rate
+ output total × output rate
```

OpenAI/Codex:

```text
uncached input × input rate
+ cache read × cached input rate
+ cache write × cache write rate, when the catalog entry defines one
+ output total × output rate
```

GPT-5.6 계열은 공식 가격표에 cache write 단가가 별도로 있으므로 해당 rate를 적용한다. cache write rate가 없는 모델에서 queue가 0보다 큰 cache write token을 보고하면 조용히 input rate를 대신 적용하지 않고 `unknownPricingVariant` issue로 남긴다.

`output total = non-reasoning output + reasoning output`이다. reasoning token은 이미 output total에 포함되므로 별도로 다시 더하지 않는다.

Swift 계산은 binary floating point가 아니라 `Decimal`을 사용한다.

```text
cost = Decimal(tokens) × ratePerMillion / 1,000,000
```

Day/Mon 화면 formatting 직전까지 Decimal precision을 유지한다.

### 요청 시각 기준 가격 적용

현재 가격이 아니라 각 request timestamp에 유효한 catalog entry를 수집 시점에 선택하고, 그 entry의 `effectiveFrom`을 `price epoch start`로 bucket key에 저장한다. 조회 시에는 provider·model·tier·variant·price epoch으로 catalog rate를 다시 찾는다. 같은 날짜 안에서 가격이 변경되어도 epoch별 token 합계가 섞이지 않는다. Legacy 또는 보강 전 bucket처럼 `priceEpochStart == nil`이면 `[firstObservedAt, lastObservedAt]` 전체가 하나의 동일한 active entry에 완전히 포함될 때만 그 entry를 적용한다. 관측 구간이 `effectiveFrom`, `effectiveUntil` 또는 catalog gap을 가로지르면 전체 bucket을 `priceEpochUnavailable`로 unpriced 처리한다.

Persisted ledger를 조회할 때 estimator는 bucket/issue의 local date와 integer 불변식을 다시 방어적으로 검증한다. 음수 counter, `failedRequestCount > requestCount`, token category 합계 불일치, `firstObservedAt > lastObservedAt`, malformed 또는 top-level month 밖의 local date는 해당 항목을 비용·count 합산에서 제외하고 관련 period에 `corruptedLedger`를 표시한다. 여러 정상 bucket의 period 합계도 checked arithmetic을 사용하며 overflow를 일으킨 항목은 제외하고 `corruptedLedger` partial로 유지한다. Output category cost는 각 category를 Decimal로 변환해 더하여 중간 `Int64` 합산 overflow를 만들지 않는다.

### Claude prompt cache TTL 제한

Anthropic API 응답 자체는 `cache_creation.ephemeral_5m_input_tokens`와 `ephemeral_1h_input_tokens`를 구분할 수 있지만, CLIProxyAPI `v7.2.97`의 normalized token breakdown은 이를 하나의 `cache_write_tokens`로 합쳐 TTL별 token을 노출하지 않는다.

초기 버전 정책:

- Claude cache write token은 기본 5분 TTL rate로 계산한다.
- cache write token이 0보다 크면 snapshot에 `cacheWriteTTLAssumedDefault` issue를 추가한다.
- tooltip에 `Claude cache writes use the 5-minute cache rate because the queue does not expose TTL.`을 표시한다.
- 1시간 cache write를 사용한 요청은 실제 비용보다 낮게 추정될 수 있다.
- CLIProxyAPI가 TTL별 accounting을 제공하기 전에는 이 한계를 숨기지 않는다.

### Claude inference geography 제한

Claude 4.6 이상에서 `inference_geo: "us"`는 모든 token 범주에 1.1배가 적용되지만 CLIProxyAPI `v7.2.97` usage queue는 `inference_geo`를 노출하지 않는다.

초기 버전 정책:

- Claude 4.6 이상 요청은 global 기본 단가로 계산한다.
- 계산된 snapshot에 `inferenceGeoAssumedGlobal` issue를 추가한다.
- tooltip에 `Claude costs use global pricing because the queue does not expose inference geography. US-only inference may cost 10% more.`를 표시한다.
- queue가 inference geography를 제공하기 전에는 global과 US-only request를 조용히 같은 확정 비용으로 표현하지 않는다.

### OpenAI/Codex long-context와 cache write

공식 가격표에서 GPT-5.6 Sol/Terra/Luna, GPT-5.5/5.5 Pro, GPT-5.4/5.4 Pro는 input이 272,000 token을 초과하면 요청 전체에 long-context 단가를 적용한다. GPT-5.4 mini/nano에는 이 variant를 적용하지 않는다. queue의 canonical input total로 이 경계를 판정할 수 있으므로 `pricing variant`에 `standardLongContext`를 포함한다.

- `input.totalTokens > 272_000`이면 long-context catalog entry를 사용한다.
- priority와 long-context가 동시에 나타나지만 공식 catalog에 조합 단가가 없으면 `unknownPricingVariant`로 처리한다.
- GPT-5.6 cache write는 catalog의 별도 cache write rate를 사용한다.
- cache write rate가 없는 OpenAI model에서 cache write token이 0보다 크면 해당 요청을 임의 단가로 계산하지 않는다.

### 별도 과금과 식별 불가능한 variant

다음 항목은 token ledger만으로 확정할 수 없으므로 제외하거나 unpriced issue로 처리한다.

- web search 등 요청별 별도 tool fee
- code execution runtime fee
- Message Batches 할인
- provider credit와 계약 할인
- 세금
- CLIProxyAPI record에 표현되지 않는 Claude fast-mode speed premium
- record에서 확실히 식별할 수 없는 service tier 또는 pricing variant

Claude fast mode를 지원하는 Opus 5/4.8/4.7 request는 queue에서 speed를 확인할 수 없으므로 standard rate로 계산하고 `fastModeAssumedStandard` issue를 표시한다. Tooltip에는 fast mode request라면 실제 비용이 더 높을 수 있음을 명시한다.

OpenAI/Codex priority tier처럼 `response_service_tier`로 확인 가능한 variant는 별도 catalog entry로 계산한다.

## 6. 날짜와 시간대

### 원본 시각

CLIProxyAPI의 `timestamp`를 UTC `Date`로 해석해 bucket의 first/last observed 시각에 사용한다. timestamp가 없는 레코드는 CLIProxyAPI가 queue 적재 시각을 채우므로 앱에서 임의의 과거 시각을 추정하지 않는다.

### reporting time zone

API cost tracking을 처음 활성화할 때 `TimeZone.current.identifier`의 IANA 식별자를 metadata에 저장한다.

예:

```text
Asia/Seoul
America/Los_Angeles
```

이후 macOS 시스템 시간대가 바뀌어도 저장된 시간대를 유지한다. 여행이나 시스템 설정 변경 때문에 과거 요청의 local date bucket이 재분할되지 않게 한다.

### Day와 Mon 경계

저장된 time zone을 적용한 Gregorian `Calendar`를 사용한다.

- Day: `Calendar.startOfDay(for:)`
- Mon: 해당 local date의 year/month 첫날 00:00

24시간을 빼거나 고정 초 수로 날짜 경계를 계산하지 않는다. DST가 있는 지역도 Calendar 경계를 사용한다.

가격표 effective timestamp는 reporting time zone이 아니라 provider 가격표에 정의된 절대 시각 기준으로 비교한다.

### invalid time zone

저장된 IANA 식별자를 복원할 수 없으면 UTC로 fallback하고 snapshot을 partial로 표시한다. 기존 bucket을 현재 시스템 시간대로 조용히 재분할하지 않는다.

## 7. 상태 모델

### Core snapshot

```swift
public struct APICostPeriodSnapshot: Equatable, Sendable {
    public let period: APICostPeriod
    public let estimatedUSD: Decimal
    public let totalTokens: Int64
    public let requestCount: Int64
    public let failedRequestCount: Int64
    public let pricedRequestCount: Int64
    public let unpricedRequestCount: Int64
    public let intervalStart: Date
    public let intervalEnd: Date
    public let issues: [APICostIssue]
}

public struct APICostSnapshot: Equatable, Sendable {
    public let profileID: String
    public let provider: APIUsageProvider
    public let day: APICostPeriodSnapshot
    public let month: APICostPeriodSnapshot
    public let reportingTimeZoneID: String
    public let updatedAt: Date
}
```

### issue

```swift
public enum APICostIssue: String, Codable, CaseIterable, Equatable, Sendable {
    case proxyUnavailable
    case managementKeyNotConfigured
    case managementKeyRejected
    case managementAPINotSupported
    case transientCollectionFailure
    case trackingStartedMidPeriod
    case collectionGap
    case trackingWasDisabled
    case unsupportedAccountingVersion
    case incompleteTokenAccounting
    case unknownProviderMapping
    case unknownModel
    case unsupportedServiceTier
    case unknownPricingVariant
    case priceEpochUnavailable
    case cacheWriteTTLAssumedDefault
    case inferenceGeoAssumedGlobal
    case fastModeAssumedStandard
    case unsupportedLedgerVersion
    case corruptedLedger
    case persistenceFailure
    case invalidReportingTimeZone
}
```

한 snapshot에 여러 issue가 동시에 존재할 수 있으므로 단일 issue가 아니라 ordered set 또는 배열로 전달한다. 각 `APICostPeriodSnapshot.issues`에는 해당 Day 또는 Mon과 실제로 겹치는 issue만 넣는다. 수집·proxy·persistence처럼 snapshot 전체의 freshness에 영향을 주는 issue는 Day/Mon 양쪽에 추가하고, `APICostUsageState.partial`의 issue 배열은 두 period issue의 안정적인 union으로 사용한다.

### state

```swift
public enum APICostUsageState: Equatable, Sendable {
    case disabled
    case loading
    case available(APICostSnapshot)
    case partial(APICostSnapshot, [APICostIssue])
    case unavailable(APICostIssue)
}
```

- 마지막 snapshot이 있는 상태에서 refresh가 실패하면 `partial(lastSnapshot, issues)`를 유지한다.
- snapshot이 전혀 없을 때만 `unavailable`을 사용한다.
- 일시적인 proxy 중지나 Management API 오류 때문에 마지막 성공 비용을 지우지 않는다.
- ledger는 snapshot cache 자체이므로 별도의 금액 cache 파일을 만들지 않는다.

### 0과 알 수 없음

| 상태 | 표시 |
|---|---|
| tracking 중이며 complete period에 사용 없음 | `$0.00` |
| tracking을 시작하지 않음 | `—` |
| snapshot 없이 수집 불가 | `—` + warning |
| 일부 요청만 계산 가능 | 계산된 금액 + warning |
| 수집 공백 가능성 | 마지막 계산 금액 + warning |
| proxy 중지, snapshot 있음 | 저장된 금액 + warning |
| proxy 중지, snapshot 없음 | `—` + warning |

알 수 없는 요청을 조용히 `$0`으로 처리하지 않는다.

## 8. Partial 판정

### 기능을 기간 중간에 처음 활성화

예를 들어 2026-07-25 14:14 `Asia/Seoul`에 처음 켠 경우:

- Day는 다음 local midnight까지 partial
- Mon은 다음 local month 시작까지 partial
- 2026-08-01 00:00 이후 새 Mon은 complete 상태로 시작 가능

표시 예:

```text
Mon    1.8M TOK · 218 REQ       $8.73  ⚠
```

Tooltip:

```text
Estimated from requests observed since Jul 25, 2026, 2:14 PM.
Earlier usage this month is not included.
Time zone: Asia/Seoul.
```

### 추적 비활성 구간

Usage 표시를 끈 동안 proxy가 실행 중이었거나 실행 여부를 확정할 수 없으면 해당 구간을 partial interval로 기록한다. proxy가 전체 구간 동안 중지되어 요청이 발생할 수 없었음이 확인되면 collection gap으로 보지 않는다.

### queue retention 초과

`lastSuccessfulDrainAt` 이후 proxy가 요청을 받을 수 있는 상태에서 1시간을 넘긴 뒤 collector가 복귀하면 queue에서 이미 만료된 요청이 있을 수 있다. 정확한 누락 수는 알 수 없으므로 추측해 보정하지 않고 Day/Mon을 partial로 표시한다.

### 미계산 요청

known request의 비용은 계속 합산하고 `unpricedRequestCount`를 별도 표시한다.

```text
$8.73 estimated from 218 priced requests.
3 requests could not be priced.
```

메뉴바와 미니 HUD에서는 작은 warning icon만 표시하고 세부 이유는 tooltip에서 제공한다.

## 9. App 표시 모델 통합

현재 `ProviderRowState`와 `MenuBarConnectedProvider`는 subscription state와 `showsSubscriptionUsage`를 별도 필드로 가진다. API Key 비용을 추가할 때 두 지표가 동시에 존재할 수 없는 invariant를 sum type으로 표현한다.

```swift
enum ProviderUsageState: Equatable {
    case subscription(AccountSubscriptionUsageState)
    case apiCost(APICostUsageState)
}
```

매핑:

```text
OAuth profile   → .subscription(...)
Claude API Key  → .apiCost(...)
OpenAI API Key  → .apiCost(...)
```

API Key row의 stable ID는 기존 `ProviderRowID.claudeAPI`와 `.codexAPI`를 유지한다.

`showsSubscriptionUsage`는 혼합 지표에 맞춰 `showsUsage`로 전환한다. persisted 설정 key는 유지하고 view model·presentation naming만 점진적으로 일반화한다.

### presentation 분리

- subscription presentation 함수는 기존 percent/progress UI를 유지한다.
- API cost presentation 함수는 Day/Mon cost row를 만든다.
- compact와 expanded view가 Core state를 직접 해석하지 않고 presentation model을 거치게 한다.
- warning icon 배치와 tooltip component는 기존 subscription warning layout을 재사용한다.

## 10. 기존 refresh orchestration과의 통합

`DashboardViewModel`의 기존 subscription polling과 API collector는 lifecycle을 공유하지만 작업 task는 분리한다.

- `prepareUsage()`가 management key, proxy config와 두 tracking path를 준비한다.
- subscription quota polling interval과 API queue drain interval은 독립적이다.
- `reloadUsage()`는 server status를 갱신한 뒤 quota refresh와 queue drain을 순차 또는 안전한 병렬 방식으로 실행한다.
- provider row rebuild는 두 결과 중 하나가 바뀔 때 수행한다.
- `isUsageReloadActionInProgress`는 두 작업 중 하나가 실행 중이면 true다.
- `lastSuccessfulUsageRefreshAt`은 화면에 표시되는 metric의 가장 오래된 성공 시각을 계산한다.

기존 subscription snapshot merge 규칙처럼 API cost도 last-success 값을 유지한다. 단, API ledger는 Usage 표시 disable 시 삭제하지 않는다.

## 11. 오류 처리

### Management API

- 401/403: management key issue, automatic retry 중단, 마지막 snapshot 유지
- 404 또는 unsupported route: bundled CLIProxyAPI contract mismatch, automatic retry 중단
- proxy unavailable: backoff retry, 마지막 snapshot 유지
- schema mismatch: raw body를 남기지 않고 issue 처리
- transient HTTP failure: retention 안에서 retry

### ledger

- decode 실패: 해당 월을 partial로 표시하고 안전한 복구 경로 사용
- atomic write 실패: 메모리 snapshot은 유지하되 persistence issue 표시
- 다음 write 성공 시 issue를 해제할 수 있지만 실패 구간은 partial로 유지
- app restart 후 ledger를 읽을 수 없으면 금액을 0으로 만들지 않고 unavailable/partial 처리

### price catalog

- unknown model: known bucket 금액은 유지하고 warning
- unsupported service tier: 임의로 default tier 적용하지 않음
- unknown pricing variant: model·tier는 known이지만 공식 조합 단가가 없는 경우 unpriced 처리
- effective date gap: model·tier·variant는 known이지만 request timestamp의 active entry가 없으므로 `priceEpochUnavailable`로 unpriced 처리
- catalog data 자체가 invalid하면 해당 provider cost를 unavailable로 처리

## 12. 개인정보와 보안

- 원본 API key를 Swift String model, ledger, cache, log, tooltip, diagnostics에 저장하지 않는다.
- queue raw JSON과 HTTP body를 출력하지 않는다.
- request ID와 auth index를 장기 저장하지 않는다.
- failure body와 response headers를 decode model에서 제외한다.
- ledger에는 local date, stable profile ID, provider, model, pricing dimension과 aggregate token/count만 저장한다.
- 파일은 사용자 전용 permission으로 생성한다.
- corrupted file backup에도 API key가 들어갈 수 없는 aggregate ledger만 포함된다.
- telemetry나 crash report를 추가할 경우에도 aggregate count만 허용한다.

## 13. Compatibility와 migration

- 기존 `config.json`은 새 필드 없이 계속 decode된다.
- 기존 `subscriptionUsage.showInMenuBar`와 `usageOverlay.isVisible`이 Usage 활성화 source of truth로 남는다.
- 기존 OAuth snapshot cache는 현재 경로를 유지한다.
- API usage metadata가 없으면 tracking 미시작 상태로 해석한다.
- API usage directory가 없으면 첫 활성화 시 생성한다.
- future schema version을 읽으면 조용히 downgrade하지 않고 unavailable issue를 표시한다.
- API key가 삭제되어 row가 사라져도 ledger는 보존한다.
- 같은 provider key를 다시 등록하면 기존 provider-level ledger에 이어서 집계하고, 비활성 구간은 partial로 표시한다.

## 14. 테스트 전략

### queue client

- empty queue와 여러 batch drain
- `count=200` 반복과 short batch 종료
- Management API authorization·unsupported route·schema mismatch
- raw API key가 decode model과 error description에 나타나지 않음
- response body가 log에 포함되지 않음

### collector

- serialized drain으로 concurrent double merge 방지
- Usage on/off lifecycle
- proxy ready 전환과 immediate drain
- 30초 polling과 retry backoff
- 1시간 retention 초과 gap 판정
- OAuth 레코드 제외
- Claude/OpenAI singleton profile 매핑
- failed request의 complete token 포함
- cancellation과 pending write flush

### token accounting

- schema version 2와 합계 invariant
- 음수 token 거부
- `complete` 반영
- `unclassified`·`inconsistent` issue count
- reasoning token 이중 합산 방지
- response service tier 우선

### ledger

- metadata와 월별 JSON round trip
- 날짜·profile·model·tier별 merge
- debounce와 atomic replacement
- app restart 후 복원
- corrupted file recovery와 partial issue
- API key·auth index·request ID·failure body가 저장 JSON에 없음
- normal termination flush

### 시간대

- `Asia/Seoul` Day/Mon 경계
- `America/Los_Angeles` DST 전환
- 월말·연말 rollover
- 시스템 시간대 변경 후 stored time zone 유지
- invalid time zone의 UTC fallback과 warning
- tracking을 일·월 중간에 켠 partial 해제 시점

### 가격

- Claude uncached/cache read/cache write/output 계산
- Claude cache write 5분 rate 가정과 issue
- Claude 4.6+ global inference 단가 가정과 `inferenceGeoAssumedGlobal` issue
- Claude Opus 5/4.8/4.7 standard speed 단가 가정과 `fastModeAssumedStandard` issue
- OpenAI cached input과 GPT-5.6 cache write 계산
- reasoning output 이중 합산 방지
- default/priority service tier 구분
- 272,000 input token 경계의 standard/long-context 구분
- priority + long-context 미지원 조합의 unpriced issue
- effective start/end 경계와 프로모션 종료
- unknown model과 unknown tier를 0달러로 처리하지 않음
- Decimal precision과 compact currency formatting

### 상태

- 마지막 성공 snapshot 유지
- snapshot이 있을 때 collection failure가 partial로 merge됨
- snapshot이 없을 때 unavailable
- `$0.00`과 `—` 구분
- known cost + unpriced count warning
- tracking disabled interval과 collector gap warning
- oldest-success 기준 `UPDATED` 시각

### UI

- OAuth row는 기존 progress usage 유지
- API Key row는 Day/Mon cost로 전환
- 메뉴바와 미니 HUD는 비용 2행만 표시
- 확장 HUD 중앙에 token·request 표시
- progress bar가 API cost row에 나타나지 않음
- warning icon alignment와 tooltip
- 긴 nickname·큰 비용·큰 token 수에서도 기존 영역을 과도하게 확장하지 않음
- VoiceOver accessibility label
- 설정 copy와 `Usage` 헤더

## 15. 구현 구성요소

### Core

- `CLIProxyAPIUsageQueueClient`
- `APIUsageQueueRecord` narrow decode model
- `APIUsageCollector`
- `APIUsageLedgerStore`
- `APIUsageTrackingMetadata`
- `APIUsageMonthlyLedger`
- `APIPriceCatalog`
- `APICostEstimator`
- `APICostSnapshot`, `APICostUsageState`, `APICostIssue`
- `ManagedPaths` API usage paths
- `ProxyServiceManager` usage statistics config generation

### App

- `DashboardViewModel` usage lifecycle와 dependency injection
- `ProviderUsageState`와 provider row mapping
- API cost presentation models
- 메뉴바 cost rows
- 확장형 HUD cost rows
- compact HUD cost rows
- 통합 reload/updated 상태
- Usage settings copy

구현 계획에서는 기존 파일의 책임 경계를 확인한 뒤 위 구성요소를 구체적인 파일 단위와 TDD 순서로 나눈다.

## 16. 승인된 결정 요약

- 비용은 전체 합계가 아니라 계정별로 표시한다.
- 메뉴바, 확장형 HUD, 미니 HUD 모두 Day와 Mon을 표시한다.
- OAuth와 API Key는 같은 계정 목록에 둔다.
- API 비용 영역은 기존 subscription usage와 같은 높이와 폭을 사용한다.
- 메뉴바와 미니 HUD는 비용만, 확장형 HUD는 token과 요청 수도 표시한다.
- 확장형 HUD의 progress bar 영역은 비워두지 않고 `TOK · REQ`에 사용한다.
- 원본 시각은 UTC로 받고, 기능 최초 활성화 시 저장한 macOS IANA 시간대로 Day/Mon을 집계한다.
- 시스템 시간대가 바뀌어도 저장된 시간대는 유지한다.
- 요청 원본이 아니라 월별 JSON의 일별 token 합계를 저장한다.
- API key는 저장하지 않고 app profile로만 연결한다.
- 부분 집계도 관측된 금액은 유지하고 warning으로 불완전성을 알린다.
- API cost tracking은 기존 Usage 표시 설정과 연동한다.
- 별도 비용 추적 toggle은 추가하지 않는다.
- 공식 청구액이 아니라 항상 Estimated cost로 표현한다.

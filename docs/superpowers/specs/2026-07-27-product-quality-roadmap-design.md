# CLIProxyManager 2026 H2 제품 품질 로드맵 설계

- 작성일: 2026-07-27
- 기간: 2026-07-27~2027-01-10
- 상태: 승인됨
- 대상 제품: CLIProxyManager v0.1.27 이후
- 핵심 사용자: 여러 Claude/Codex 계정과 quota·routing을 관리하는 macOS AI CLI 파워 유저

## 1. 목적

CLIProxyManager의 향후 6개월 작업을 소비자에게 전달되는 제품 품질을 기준으로 우선순위화한다. 사용자 기능, 코드 품질, 테스트, 배포, 업데이트, 보안, 진단, 성능, 접근성을 하나의 로드맵으로 관리하고, 각 작업을 순서대로 실행할 수 있는 GitHub 이슈로 분해한다.

이 로드맵의 핵심 원칙은 다음과 같다.

> 먼저 “설치해도 안전하다”, “설정한 대로 동작한다”, “지금 무엇으로 실행되는지 안다”, “문제가 나도 복구할 수 있다”를 증명한다. 그다음 사용자가 quota·비용·routing을 더 나은 근거로 판단하도록 돕는다. Provider 확장은 검증된 수요와 안정된 기반이 있을 때만 시작한다.

## 2. 조사 결과

### 2.1 현재 제품 정의

CLIProxyManager는 macOS 메뉴 막대에서 여러 Claude/Codex OAuth 및 API key 계정을 로컬 CLIProxyAPI와 계정별 shell 명령으로 연결하고 다음을 통합 관리하는 앱이다.

- 계정 연결·활성화·정렬
- 계정별 zsh 명령 생성
- Claude/Codex 모델·reasoning·context routing
- provider별 round-robin과 session 고정
- 로컬 proxy 시작·중지·상태·로그
- 구독 quota와 API 예상 비용
- 확장형·compact usage HUD
- `cpm` 기반 headless 관리
- Sparkle 앱 업데이트와 CLIProxyAPI 업데이트

### 2.2 확인된 강점

- 설정·auth·shell 변경 중 실패에 대비한 rollback 경로가 존재한다.
- 파일 기반 secret 저장은 owner·mode·symlink·atomic write를 방어한다.
- 앱 업데이트 artifact와 CLIProxyAPI archive의 signature·checksum·version을 검증한다.
- 기존 proxy process 채택, orphan 정리, health check 등 runtime 방어가 강하다.
- 사용량의 stale 상태를 보존하고 마지막 성공 값을 유지한다.
- 메뉴 막대, HUD, CLI가 같은 제품 영역을 서로 다른 사용 환경에서 제공한다.
- 기준 worktree에서 `swift test`를 실행한 결과 1,254개 테스트가 실패 없이 통과했다.

### 2.3 우선 해결할 제품 위험

1. Bind address와 Log level처럼 활성 UI와 실제 runtime 효과가 일치하지 않는 설정이 있다.
2. DMG가 self-signed·non-notarized여서 Gatekeeper 우회가 필요하다.
3. 번들 CLIProxyAPI가 arm64 전용이지만 Apple Silicon 요구사항이 명확하지 않다.
4. `Makefile`, source `Info.plist`, local release script의 version/build source가 다르다.
5. PR/push required CI와 main branch protection이 없어 release가 최초 통합 gate가 될 수 있다.
6. 앱·proxy 교체 후 새 버전이 실행되지 않을 때 health-validated automatic rollback이 부족하다.
7. API key용 Keychain 구현이 있지만 기본 runtime은 owner-only 평문 파일 저장을 사용한다.
8. `cpm secret get`이 전체 secret을 출력하는 legacy surface가 존재한다.
9. diagnostics folder와 raw logs는 있지만 redacted support bundle과 stable error code가 없다.
10. `DashboardViewModel`에 account, shell, proxy, usage, update, migration 책임이 집중돼 있다.
11. 실제 앱 launch·sheet·menu bar·OAuth callback을 검증하는 end-to-end UI 자동화가 제한적이다.
12. API 가격표가 앱에 하드코딩돼 가격 변경 시 추정값이 늦게 갱신될 수 있다.

### 2.4 제품 기회

- Guided readiness setup과 command preflight
- Credential health와 설정을 보존하는 재인증
- `cpm doctor`와 reversible repair
- 설정 변경 preview·영향 표시·undo
- Quota reset·threshold와 API budget 알림
- Menu bar account quick action
- Effective route 설명과 routing preset
- Local usage history·forecast
- Config export/import와 추가 shell 지원
- Localization과 Homebrew 배포
- 수요 검증 이후의 provider 확장

## 3. 제품 전략

### 3.1 포지셔닝

CLIProxyManager는 범용 AI gateway나 최대 provider 수를 목표로 하지 않는다.

> 여러 AI CLI 계정의 연결·routing·사용량·장애·업데이트를 안전하게 운영하는 macOS 로컬 컨트롤 센터

차별점은 CLIProxyAPI와의 깊은 통합, 계정별 명령, session 고정 routing, local runtime 상태, usage와 업데이트를 하나의 native 경험으로 제공하는 데 있다.

### 3.2 로드맵 접근법

**품질 게이트 기반 사용자 여정형**을 사용한다.

- 각 단계는 다음 단계가 의존하는 제품 기반을 먼저 완성한다.
- 내부 품질 작업마다 사용자에게 전달되는 결과를 명시한다.
- 각 마일스톤에 최소 하나 이상의 직접적인 사용자 체감 개선을 포함한다.
- 선행 gate가 완료되기 전에는 후속 기능의 production 구현을 시작하지 않는다.
- 조사·prototype은 병렬로 진행할 수 있지만, 불완전한 기반에 production 상태를 쌓지 않는다.

## 4. 최상위 성공 지표

### 4.1 TTFC — Time to First Command

설치 시작부터 의도한 계정으로 첫 정상 명령을 실행하기까지 걸린 시간이다.

6개월 목표:

- p50 8분 이하
- p90 15분 이하
- fresh environment setup completion 80% 이상
- Gatekeeper 우회가 필요한 설치 0%

측정 단계:

1. 앱 설치
2. prerequisite 검사
3. provider 연결
4. command 생성
5. shell 반영
6. command preflight
7. 첫 정상 실행

### 4.2 MTTR — Mean Time to Recovery

인증·proxy·shell·config·update 장애 발생부터 정상 상태로 복귀하기까지 걸린 시간이다.

6개월 목표:

- 진단 가능한 장애의 원인 식별률 90% 이상
- `doctor`와 repair만으로 해결되는 장애 70% 이상
- proxy 복구 후 usage 정상화 p95 60초 이하
- fault injection 기준 update rollback 성공률 100%
- 복구 후 config·auth·shell 불일치 0건

### 4.3 릴리스 품질 목표

| 지표 | 목표 |
|---|---:|
| PR 자동 품질 gate 적용률 | 100% |
| Release workflow가 처음 발견한 테스트 실패 | 0건 |
| 최근 10회 release의 재실행 필요율 | 5% 미만 |
| App update 적용 성공률 | 99% 이상 |
| Proxy update 적용 성공률 | 99% 이상 |
| Fault injection rollback 성공률 | 100% |
| 지원하지 않는 환경의 사전 차단·안내 | 100% |
| 활성 UI와 runtime 동작 불일치 | 0건 |

## 5. 공통 제품 품질 계약

### 5.1 상태 표현

주요 상태를 다음 다섯 가지로 구분한다.

- `loading`
- `healthy`
- `degraded`
- `stale`
- `unavailable`

가능한 모든 계정·usage·runtime 상태는 다음을 함께 제공한다.

- 데이터 출처
- 마지막 성공 시각
- 데이터 age
- stale/unavailable 원인
- 사용자 영향
- recovery action

최신 갱신이 실패해도 마지막 성공 값을 0이나 빈 값으로 교체하지 않는다.

### 5.2 안전한 변경

Config, shell, auth, app, proxy 변경은 다음 transaction을 따른다.

```text
Preview → Backup → Atomic Apply → Health Verify → Commit
                                      ↓ 실패
                                   Rollback
```

각 변경은 다음을 보장한다.

- 변경할 파일과 runtime 영향 사전 표시
- 기존 정상 상태 backup
- atomic apply
- 실제 실행 가능성 health check
- 실패 시 이전 상태 복원
- 복구 결과와 다음 행동 표시
- rollback도 실패하면 diagnostics 경로 제공

Signature·checksum 검증만으로 update 성공을 확정하지 않는다. 새 버전의 launch, helper, proxy, command compatibility까지 확인한다.

### 5.3 개인정보와 보안

기본 원칙:

- Prompt·response 내용은 수집하지 않는다.
- Secret·email·management key·local path는 log, diagnostics, fixture에서 제거한다.
- Diagnostics export 전에 redaction 결과를 검증한다.
- LAN binding은 노출 범위와 인증 상태를 명시한다.
- Secret migration은 rollback과 downgrade를 포함한다.
- Public test·document fixture는 `example.com` 기반 식별자를 사용한다.

### 5.4 접근성

다음 핵심 여정은 VoiceOver와 Full Keyboard Access만으로 완료할 수 있어야 한다.

- Onboarding
- Account 연결·재인증·삭제
- Server start·stop·repair
- App·proxy update
- Usage HUD와 account action
- Routing preset과 change preview

Reduce Motion을 존중하며, drag-only action에는 keyboard 대안을 제공한다.

## 6. GitHub 로드맵 구조

총 35개 항목으로 관리한다.

- Roadmap tracking issue: 1개
- 6개월 실행 항목: 30개
- 6개월 이후 opportunity validation: 4개
- 기존 Issue #18은 중복 생성하지 않고 범위와 acceptance criteria를 보완한다.
- 따라서 새로 생성하는 이슈는 34개이며, 기존 Issue #18을 포함한 전체 추적 항목은 35개다.

### 6.1 마일스톤

| Milestone | 목표일 | 결과 |
|---|---:|---|
| M1 — Release Truth & Safety | 2026-08-23 | 설정과 runtime 일치, CI·version·supply-chain 기준 |
| M2 — Trusted Install & First Command | 2026-10-04 | 공증 설치, readiness, 첫 command 성공 |
| M3 — Diagnosis, Recovery & Safe Change | 2026-11-22 | doctor, diagnostics, credential recovery, rollback |
| M4 — Daily Confidence & Decision Support | 2027-01-10 | 알림, 비용, quick action, routing, 성능·접근성 |
| Opportunity Validation | 기한 없음 | 6개월 이후 후보의 수요와 진입 조건 검증 |

## 7. 이슈 목록과 실행 순서

### 7.1 Roadmap tracking

#### R01. `[Roadmap] CLIProxyManager Product Quality Roadmap — 2026 H2`

다음을 하나의 checklist로 추적한다.

- 제품 포지셔닝과 핵심 사용자
- TTFC·MTTR 목표
- 마일스톤별 진입·종료 조건
- 전체 이슈 순서와 의존성
- Opportunity validation 진입 조건
- 릴리스별 품질 지표

### 7.2 M1 — Release Truth & Safety

#### R02. Bind address를 실제 proxy runtime에 반영

사용자가 선택한 listening interface와 실제 proxy YAML·process binding이 일치해야 한다. 안전하게 연결할 수 없다면 준비 전까지 UI를 제거한다.

#### R03. Log level을 app·proxy logging에 연결

저장된 log level이 실제 logger와 proxy runtime에 적용되어야 한다. 연결되지 않은 legacy setting과 dormant API는 제거하거나 deprecate한다.

#### R04. Version/build number의 단일 진실 공급원 확립

`Makefile`, `Info.plist`, local release, GitHub Actions, appcast가 동일한 resolver를 사용한다. Build number가 역행하면 release가 실패해야 한다.

#### R05. PR/push CI와 main required checks 구성

필수 검사:

- `swift build`
- `swift test`
- Shell script tests
- Release package structural validation
- Compiler warning 기준

Branch rule 또는 ruleset으로 우회되지 않도록 한다.

#### R06. Test fixture 격리와 flaky test budget 도입

Clock, screen, home directory, config fixture를 격리하고 parallel-safe 상태로 만든다. 반복 CI 실행에서 flaky failure 0을 목표로 한다.

#### R07. 지원 환경과 architecture compatibility 명시

Apple Silicon, macOS, shell, CLIProxyAPI, Claude/Codex의 지원·last-verified 범위를 README, release note, runtime preflight에 표시한다.

#### R08. GitHub Actions·dependency supply-chain 기준 강화

Action SHA pinning, dependency update automation, checksum, provenance 또는 SBOM 기준을 도입한다.

M1 종료 조건:

- 활성 setting/runtime 불일치 0건
- 모든 PR에 동일한 quality gate 적용
- Local/CI release version resolution 일치
- 지원하지 않는 환경을 설치 또는 실행 전에 명확히 안내

### 7.3 M2 — Trusted Install & First Command

#### R09. Developer ID 서명·공증·stapling 도입

Fresh macOS에서 `Open Anyway` 없이 설치·실행되며 `spctl` 검증을 통과해야 한다.

#### R10. Packaging·install·update smoke test 자동화

DMG mount, bundle metadata, codesign, notarization, helper, proxy, appcast, install/update 경로를 검증한다.

#### R11. 기존 Issue #18 — account profile lifecycle과 설정 소유권 정리

기존 이슈를 다음 범위로 보완한다.

- Account-owned setting과 app preference 분리
- Profile 삭제·재인증·이름 변경 정합성
- 기본 command name 생성
- Schema migration과 rollback
- Provider 확장 기반

#### R12. Guided readiness onboarding 구현

Claude/Codex CLI, provider, shell, helper, proxy, command 상태를 5단계 이하의 checklist로 검사하고 누락 항목에 해결 action을 제공한다.

#### R13. 기본 command 추천·preflight·새 Terminal 열기

충돌 없는 command를 추천하고 API 요청 없이 shell function, helper path, effective route를 검증한다.

#### R14. 인증·model loading 실패 복구 UX 완성

다음을 하나의 account connection quality 범위로 다룬다.

- OAuth timeout·cancel·retry
- Duplicate profile 방지
- Model refresh 실패와 retry
- API key profile 삭제 확인
- 실패 후 기존 account setting 보존

M2 종료 조건:

- Gatekeeper 우회 설치 0%
- Fresh setup completion 80% 이상
- TTFC p50 8분 이하, p90 15분 이하
- 계정 연결 실패가 빈 목록·무반응으로 표시되는 경우 0건

### 7.4 M3 — Diagnosis, Recovery & Safe Change

#### R15. Structured logging과 stable error code 도입

App, proxy, helper, shell, auth, update error에 일관된 domain과 식별자를 부여하고 log rotation을 제공한다.

#### R16. Redacted diagnostics bundle 제공

Version, environment, runtime state, recent error를 묶되 secret, email, prompt, raw local path를 제거한다.

#### R17. `cpm doctor` 진단 엔진 구현

다음을 검사하고 human-readable output, JSON output, stable exit code를 제공한다.

- App/proxy/helper compatibility
- Port·process·health
- Auth·credential permission
- Shell managed block
- Config schema
- Update state

GUI와 CLI가 같은 Core diagnostic API를 사용한다.

#### R18. Reversible repair와 one-click recovery 제공

Doctor 결과를 입력으로 사용해 reversible repair를 수행한다. Repair는 변경 전 backup, preview, result, rollback을 제공한다.

#### R19. Credential health와 설정 보존 재인증

`healthy`, `expired`, `relogin-required`, `missing`을 구분하고 재인증 후 nickname, command, routing을 보존한다.

#### R20. Keychain 기본 저장과 secret migration

기존 FileSecretStore 값을 Keychain으로 원자적으로 이전하고 migration failure와 downgrade를 검증한다.

동시에 다음을 처리한다.

- `cpm secret get` 기본 redaction
- 전체 값은 명시적 `--reveal`과 TTY 확인 필요
- Diagnostics·log의 secret masking test

#### R21. 설정 변경 preview·영향 표시·undo

변경될 file, effective route, restart 여부를 저장 전에 보여주고 마지막 성공 변경을 되돌릴 수 있게 한다.

#### R22. CLIProxyAPI update health check·automatic rollback

새 binary readiness가 확인될 때까지 이전 binary를 보존하고 실패 시 자동 복구한다.

#### R23. App update health check·automatic rollback·result history

새 app launch와 helper/proxy compatibility를 확인한 뒤 성공을 확정한다. 실패 시 이전 app을 복구하고 update 결과를 기록한다.

M3 종료 조건:

- Doctor에서 unknown cause 10% 미만
- Doctor·repair만으로 해결되는 장애 70% 이상
- Fault injection rollback 성공률 100%
- Apply 실패 후 config·shell·auth 불일치 0건
- Secret이 기본 CLI output·diagnostics·log에 노출되는 경우 0건

### 7.5 M4 — Daily Confidence & Decision Support

#### R24. Usage 데이터 freshness·source·incomplete 상태 계약 통일

Menu bar, HUD, settings에서 동일한 상태, updated age, stale reason, recovery action을 제공한다.

#### R25. Quota reset·usage threshold·API budget 알림

하나의 notification 기반 위에서 다음을 제공한다.

- Account·period별 quota threshold
- Reset 알림
- 일·월 API budget 50/80/100%
- Quiet hours
- Duplicate suppression
- 추정값과 누락 구간 안내

#### R26. Menu bar account quick action

Account별 Copy Command, Open Terminal, Refresh Usage, Re-authenticate를 제공한다. Unhealthy account는 이유와 해결 경로를 표시한다.

#### R27. Effective route 설명과 routing preset

`Balanced`, `Fast`, `Deep`, `Cost-conscious` preset을 제공하되 최종 account, model, reasoning을 저장 전에 보여준다.

#### R28. App performance budget과 regression 측정

Launch time, idle CPU, memory, refresh latency의 기준을 정하고 release마다 추적한다.

초기 목표:

- Idle CPU p95 1% 이하
- Idle memory p95 150MB 이하

실제 baseline을 측정한 뒤 수치를 재조정할 수 있다.

#### R29. Accessibility release gate

Onboarding, account setting, server, update, HUD를 VoiceOver와 Full Keyboard Access로 완료할 수 있어야 한다.

#### R30. 7/30일 usage history·forecast beta

현재 사용 속도로 quota가 언제 소진될지 보여주되 data gap, freshness, timezone을 명시한다.

#### R31. 핵심 coordinator 책임 분리 완료

`DashboardViewModel`에서 다음 책임을 독립 경계로 이동한다.

- Account profile
- Shell command
- Server runtime
- Usage
- Update
- App preferences

완료 기준은 파일 line 수가 아니라 UI 없이 각 상태 머신을 테스트할 수 있는지 여부다.

M4 종료 조건:

- 모든 usage 숫자에 source·age·stale reason 제공
- Route 설정 완료 시간 p50 2분 이하
- 예상과 다른 account/model 실행 사례 0건
- Performance budget 추적
- Keyboard·VoiceOver 핵심 여정 완료율 100%

### 7.6 Opportunity Validation

#### R32. 설정 이동성과 shell 확장 기회 검증

- Secret 없는 config export/import
- Backup·restore
- Bash/fish shell 지원

#### R33. 고급 usage·account 의사결정 기능 검증

- 다음 account 추천
- Command/session별 usage attribution
- Account group/workspace

Silent automatic account rotation은 기본 범위에서 제외하고 명시적 선택을 유지한다.

#### R34. Localization과 배포 접근성 검증

- 한국어·영어 app localization
- Homebrew cask
- 사용자 중심 release note

#### R35. Provider 확장 진입 조건 검증

후보:

- Gemini
- Generic OpenAI-compatible profile
- Qwen
- Provider incident status overlay

진입 조건 중 하나 이상의 사용자 수요와 모든 foundation 조건을 충족해야 한다.

수요 조건:

- Active beta 사용자의 20% 이상 요청, 또는
- 검증된 사용자 interview 10건 이상에서 공통 JTBD 확인

Foundation 조건:

- 핵심 provider의 8주 retention 안정
- App·proxy update rollback 완료
- Compatibility contract test 완료
- Account profile lifecycle 완료

## 8. 의존성과 병렬 실행

### 8.1 M1

```text
설정 진실성
├─ R02 Bind address
└─ R03 Log level

릴리스 검증
├─ R04 Version/build 단일화
├─ R05 PR CI·script tests
└─ R06 Fixture isolation

배포 기반
├─ R07 Compatibility disclosure
└─ R08 Supply-chain baseline
```

R04와 R05는 R09·R10보다 먼저 완료한다.

### 8.2 M2

```text
R11 Profile lifecycle
├─ R12 Guided readiness
├─ R13 Command recommendation/preflight
└─ R14 Auth/model recovery

R09 Developer ID·공증
└─ R10 Package/install/update smoke test
```

공증 준비는 profile lifecycle과 병렬로 진행한다.

### 8.3 M3

```text
R15 Structured logs/error codes
├─ R16 Diagnostics bundle
├─ R17 cpm doctor
│  └─ R18 Reversible repair
└─ R23 Update result history

R11 Profile lifecycle
├─ R19 Credential health/reauth
└─ R20 Keychain migration/redaction

Update contract
├─ R22 Proxy rollback
└─ R23 App rollback

Change transaction
└─ R21 Preview/impact/undo
```

Doctor는 진단만 수행하고 repair가 doctor result를 소비한다. 진단과 복구의 책임을 분리한다.

### 8.4 M4

```text
R24 Usage state contract
├─ R25 Notifications
└─ R30 History/forecast

R19 Account health
└─ R26 Menu quick actions

R21 Change preview
└─ R27 Effective route/presets

Release budgets
├─ R28 Performance
└─ R29 Accessibility

Characterization tests
└─ R31 Coordinator split
```

## 9. 테스트와 검증

### 9.1 모든 PR

- Core·App unit tests
- Config migration tests
- Shell renderer·installer tests
- Auth·secret permission tests
- Update state machine tests
- Script tests
- `swift build`
- Packaged artifact structural validation

### 9.2 Main·release candidate

- Clean temporary home에서 shell install/remove
- Fake OAuth callback account 연결
- Fake proxy start/stop/health
- App/proxy update와 rollback fault injection
- Config preview/apply/undo
- Keychain migration/downgrade
- Diagnostics redaction

### 9.3 Release

- Clean macOS install
- Gatekeeper·`spctl`
- Notarization ticket·stapling
- 첫 account 연결과 command preflight
- 새 Terminal에서 첫 command
- Sparkle app update
- CLIProxyAPI update
- 이전 version rollback
- VoiceOver·keyboard 핵심 여정
- Idle CPU·memory

자동 검증은 development build까지 수행하고 앱 실행·수동 UI 확인은 release checklist에 따라 사용자가 담당한다.

## 10. 측정 방식

초기에는 10~20명의 beta cohort를 통해 TTFC·MTTR baseline을 수집한다. Product telemetry를 도입한다면 명시적 opt-in으로 제한한다.

수집 가능:

- App version
- macOS major version
- Provider 종류
- Onboarding step
- Duration bucket
- Stable error code
- Repair action 결과

수집 금지:

- Email·account ID
- API key·OAuth token
- User command name
- Prompt·response
- Raw log
- Local file path
- Session content

Telemetry가 없어도 beta 기록과 GitHub issue template으로 baseline을 측정할 수 있다.

## 11. GitHub 운영 규칙

### 11.1 Label

작업 성격:

- `type: product`
- `type: foundation`
- `type: security`
- `type: discovery`

제품 영역:

- `area: onboarding`
- `area: account`
- `area: proxy`
- `area: shell`
- `area: usage`
- `area: routing`
- `area: update`
- `area: release`
- `area: diagnostics`
- `area: accessibility`
- `area: architecture`

우선순위:

- `priority: P0`
- `priority: P1`
- `priority: P2`
- `priority: validation`

영향:

- `impact: TTFC`
- `impact: MTTR`
- `impact: reliability`
- `impact: privacy`

기본적으로 작업 성격 1개, 영역 1~2개, 우선순위 1개, 영향 1개를 사용한다.

### 11.2 Definition of Ready

- 사용자 문제와 대상 사용자가 명확함
- 현재 동작 또는 근거 코드가 연결됨
- 선행 이슈가 완료됐거나 병렬 진행 가능함
- 사용자 결과 중심 acceptance criteria가 있음
- Migration·rollback 필요성이 정의됨
- Secret·log·개인정보 영향이 검토됨
- 자동·수동 검증 범위가 구분됨

조건을 만족하지 못하면 `type: discovery`로 유지한다.

### 11.3 Definition of Done

- Acceptance criteria 충족
- 필요한 unit·integration·script test 추가
- Development build 성공
- 관련 regression test 통과
- Failure·rollback 경로 검증
- User-facing error에 recovery action 제공
- 문서·troubleshooting·release note 갱신
- 접근성 영향 검토
- Secret·email·prompt가 log·fixture에 노출되지 않음
- TTFC·MTTR 또는 reliability 영향 기록
- 앱 실행·수동 UI 검증이 필요하면 사용자 checklist 제공

### 11.4 공통 이슈 템플릿

각 이슈는 다음을 포함한다.

1. 사용자 문제
2. 대상 사용자와 JTBD
3. 현재 근거와 관련 코드
4. 기대하는 사용자 결과
5. 명시적 비목표
6. Acceptance criteria
7. 실패·rollback 동작
8. 개인정보·보안 고려사항
9. 접근성 요구사항
10. 테스트·검증 방법
11. 성공 지표
12. 선행·후속 이슈

## 12. 명시적 비목표

6개월 실행 범위에서는 다음을 구현하지 않는다.

- Windows/Linux desktop app
- 다수 provider의 빠른 추가
- Silent automatic quota avoidance·account rotation
- Cloud sync·team dashboard·RBAC
- Prompt/session 내용 분석
- MCP·skills·plugin marketplace
- 자체 hosted billing gateway

이 항목들은 현재 macOS local account operations라는 제품 경계를 흐리거나 별도의 backend·보안·운영 제품을 요구한다.

## 13. 외부 근거

- Apple — Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple — Distributing software on macOS: https://developer.apple.com/macos/distribution/
- Apple HIG — Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility/
- Apple HIG — Keyboards: https://developer.apple.com/design/human-interface-guidelines/keyboards/
- Homebrew Cask Cookbook: https://docs.brew.sh/Cask-Cookbook
- CLIProxyAPI: https://github.com/router-for-me/CLIProxyAPI
- CodexBar: https://github.com/steipete/CodexBar
- CC Switch: https://github.com/farion1231/cc-switch
- Claude Code Router: https://github.com/musistudio/claude-code-router
- ccusage: https://github.com/ryoppippi/ccusage
- LiteLLM reliability: https://docs.litellm.ai/docs/proxy/reliability

## 14. 결론

CLIProxyManager의 다음 성장은 기능 수보다 신뢰 가능한 운영 경험에서 나와야 한다. 6개월 동안 설정 진실성, 배포 신뢰, 첫 성공, 진단·복구, 안전한 변경을 먼저 완성하고 그 기반 위에서 quota·비용·routing 의사결정을 개선한다.

Provider 확장은 현재 핵심 기능의 retention, profile lifecycle, compatibility contract, automatic rollback, 사용자 수요가 검증된 뒤 시작한다. 이 순서는 사용자 신뢰를 높이는 동시에 향후 기능 개발의 회귀 위험과 유지보수 비용을 줄인다.

# Canonical Provider Config Migration 설계

**작성일:** 2026-07-26
**상태:** 설계 승인

## 배경

현재 `AppConfig`에는 과거 단일 계정 시절의 예시 command 이름에서 유래한 약어 기반 필드가 canonical schema로 남아 있다.

- `commands.cc`
- `commands.ccapi`
- `commands.ccodex`
- `commands.ccodexapi`
- `ccapi`
- `ccodex`
- `nicknames.cc`
- `nicknames.ccodex`
- `accountPrivacy`
- `includeDangerouslySkipPermissions`

지금은 실제 계정별 설정이 `oauthCommandProfiles`에 존재함에도 위 필드가 mirror source로 함께 저장된다. 그 결과 auth 파일이 사라진 command profile이 config에서 제거되지 않으면 화면에는 보이지 않지만 command 함수와 legacy Codex routing이 계속 남을 수 있다. API Key settings도 command가 `commands`에, routing과 nickname이 별도 provider 설정에 나뉘어 source of truth가 분산되어 있다.

이 설계는 비공식 약어 기반 property와 JSON key를 제거하고 provider/profile 중심 canonical schema로 한 번 migration한다.

## 목표

- `AppConfig` model과 새 `config.json`에서 비공식 약어 기반 legacy field를 제거한다.
- OAuth 설정은 각 `oauthCommandProfiles` 항목에만 저장한다.
- Claude/Codex API Key 설정은 명시적인 `claudeAPI`, `codexAPI`에 각각 저장한다.
- 이전 config는 사용자 개입 없이 한 번 읽고 canonical version으로 즉시 저장한다.
- auth 파일이 없는 stale OAuth command profile과 generated function을 자동 정리한다.
- Codex OAuth profile이 없으면 별도 top-level Codex OAuth command/model 설정을 남기지 않는다.
- 신규 Codex API Key 등록의 nickname은 빈 값으로 시작한다.

## 비목표

- 복수 API Key 등록은 이번 범위에 포함하지 않는다.
- OAuth와 API Key를 하나의 공통 profile 배열로 합치지 않는다.
- provider 종류를 추가하지 않는다.
- command 문자열 자체로 사용자가 `ccodex` 등을 입력하는 것을 금지하지 않는다. 비공식 약어는 source identifier, JSON key, 기본값, UI 명칭에서만 제거한다.
- `roundRobinProfiles`, HUD, appearance, server 설정을 재설계하지 않는다.

## Canonical schema

새 문서는 `schemaVersion: 2`를 저장한다.

```json
{
  "schemaVersion": 2,
  "port": 18317,
  "claudeAPI": {
    "commandName": "claude-api-work",
    "nickname": "",
    "claude": {
      "mode": "automatic"
    },
    "dangerousPermissionsEnabled": false
  },
  "codexAPI": {
    "commandName": "codex-api-work",
    "nickname": "",
    "codex": {
      "opus": { "model": "gpt-5.6-terra", "reasoning": "xhigh" },
      "sonnet": { "model": "gpt-5.6-terra", "reasoning": "medium" },
      "haiku": { "model": "gpt-5.6-terra", "reasoning": "low" }
    },
    "dangerousPermissionsEnabled": false
  },
  "oauthCommandProfiles": [
    {
      "id": "provider-profile-id",
      "provider": "codex",
      "authProfileID": "auth-profile-id",
      "commandName": "codex-work",
      "nickname": "Work",
      "accountDetailHidden": true,
      "dangerousPermissionsEnabled": false,
      "codex": {
        "opus": { "model": "gpt-5.6-terra", "reasoning": "xhigh" },
        "sonnet": { "model": "gpt-5.6-terra", "reasoning": "medium" },
        "haiku": { "model": "gpt-5.6-terra", "reasoning": "low" }
      },
      "modelPrefix": "codex-work",
      "connectionMode": "proxy",
      "isEnabled": true
    }
  ]
}
```

실제 문서에는 기존 canonical general settings와 `roundRobinProfiles`도 함께 저장한다. 예시는 provider 설정의 소유권만 보여 준다.

## Canonical model

### OAuth

OAuth 계정 설정은 `AppConfig.OAuthCommandProfile`이 유일한 source of truth다.

- command name
- nickname
- detail privacy
- dangerous permission
- Claude/Codex routing
- model prefix
- connection mode
- enabled state

### Claude API Key

`AppConfig.ClaudeAPI`는 다음을 소유한다.

- `commandName`
- `nickname`
- `claude`
- `dangerousPermissionsEnabled`

### Codex API Key

`AppConfig.CodexAPI`는 다음을 소유한다.

- `commandName`
- `nickname`
- `codex`
- `dangerousPermissionsEnabled`

### Codex default routing

Codex 기본 routing은 저장되는 top-level 사용자 설정이 아니다. `AppConfig.Codex.default` 같은 명시적인 code default로 제공한다.

`AppConfig`에서 다음 model을 제거한다.

- `Commands`와 `commands`
- `Nicknames`와 `nicknames`
- `ccapi`
- `ccodex`
- `accountPrivacy`
- `includeDangerouslySkipPermissions`

## Legacy decode adapter

비공식 약어는 `LegacyAppConfigDecoder`의 private coding key에만 남는다. runtime model과 canonical encode에는 노출하지 않는다.

legacy mapping은 다음과 같다.

- `commands.ccapi` + `ccapi` → `claudeAPI`
- `commands.ccodexapi` + 기존 `codexAPI` → canonical `codexAPI`
- `commands.cc`, `commands.ccodex`, `nicknames`, `accountPrivacy`, `includeDangerouslySkipPermissions`, `ccodex` → migration 전용 OAuth defaults

legacy OAuth defaults는 auth profile ID를 알 수 없으므로 decode 단계에서 canonical profile로 임의 변환하지 않는다. migration result에 transient payload로 보관하고, app startup에서 auth profile 목록을 성공적으로 읽은 뒤 실제 첫 Claude/Codex auth profile과 연결한다.

## Startup migration

1. config document를 decode한다.
2. version 2이면 canonical config를 그대로 사용한다.
3. legacy document이면 API Key 설정을 즉시 canonical provider 설정으로 변환하고 OAuth defaults를 transient migration payload로 보관한다.
4. auth profile 목록을 읽는다.
5. auth profile load가 성공한 경우에만 다음 reconciliation을 실행한다.
   - existing `oauthCommandProfiles` 중 실제 auth profile이 없는 항목 제거
   - legacy OAuth defaults를 provider별 첫 auth profile에 연결하되, 이미 canonical profile이 있으면 중복 생성하지 않음
   - 새 auth profile에는 빈 command와 provider 기본 routing으로 canonical profile 생성
6. migration 또는 prune으로 config가 달라졌으면 `schemaVersion: 2` canonical JSON을 atomic save한다.
7. canonical config로 shell functions를 다시 생성한다.

### Auth profile load 실패

auth profile 목록을 읽지 못한 경우에는 계정이 없다고 간주하지 않는다.

- OAuth profile prune 금지
- migration finalization 금지
- config rewrite 금지
- 기존 파일 보존

다음 성공적인 실행 또는 refresh에서 migration을 재시도한다.

### Migration save 실패

- atomic save 실패 시 기존 config 파일 유지
- app은 변환된 in-memory config로 동작
- stale shell function은 in-memory canonical config를 기준으로 제거
- 사용자에게 migration save 실패 message 표시
- 다음 설정 저장 또는 앱 실행에서 재시도

## 삭제와 stale 정리

앱에서 OAuth account를 삭제할 때 선택된 row의 command profile은 auth 파일 삭제 결과와 독립적으로 제거한다.

- auth 파일 삭제 성공: auth 파일과 command profile 모두 제거
- auth 파일이 이미 없음: stale command profile은 제거하고 사용자에게 이미 사라진 auth file임을 알림
- config 저장 실패: 기존 rollback 규칙으로 config와 shell functions를 보존

startup reconciliation은 앱 외부에서 auth 파일이 삭제된 기존 stale 상태도 정리한다. 제거된 profile은 provider row, shell function, round-robin eligibility, model prefix sync의 입력에서 사라진다.

OAuth profile이 하나도 없으면 OAuth command 또는 Codex model routing을 저장하는 top-level field 자체가 없으므로 잔여 설정이 생기지 않는다.

## API Key nickname 초기값

- 기존 API Key 편집(`isConfigured == true`): 저장된 nickname 표시
- 신규 API Key 등록(`isConfigured == false`): nickname은 항상 빈 문자열

이번 규칙은 우선 사용자에게서 확인된 Codex API Key sheet에 적용한다. canonical provider settings 구조는 향후 Claude API Key sheet에도 같은 정책을 적용할 수 있는 명확한 경계를 제공한다.

## 복수 API Key 확장 경계

이번 범위는 provider별 API Key 하나를 유지한다. 향후 복수 API Key를 지원할 때는 다음 별도 migration으로 확장한다.

- `claudeAPI`, `codexAPI` → `apiKeyProfiles[]`
- 각 profile에 stable ID와 secret reference 추가
- account ordering, command uniqueness, UI 추가/삭제, secret storage migration 포함

현재 typed provider 설정은 API Key 관련 필드를 한 위치에 모으므로 향후 배열 migration의 입력이 명확하다.

## 코드 구조

- `AppConfig.swift`
  - canonical model과 version 2 encode/decode
  - `Codex.default`
- 신규 `LegacyAppConfigDecoder.swift`
  - version 1/private legacy key decode
  - migration payload 생성
- 신규 `AppConfigMigration.swift`
  - auth profiles와 migration payload를 canonical config로 reconcile
  - stale profile prune
  - rewrite 필요 여부 반환
- `AppConfigStore.swift`
  - document decode 결과 제공
  - canonical atomic save
- `DashboardViewModel.swift`
  - startup migration finalization
  - successful auth load에서만 prune
  - shell regeneration
  - legacy mirror/reset helper 제거
- `ProviderSettingsSheets.swift`
  - canonical API provider 설정 사용
  - 신규 Codex API Key nickname 빈 값
- renderer, CLI, automatic installer, Fast mode, diagnostics
  - canonical profile/provider 설정만 사용

## 오류와 사용자 메시지

- decode 실패: 기존 invalid config 오류 경로 유지, overwrite 금지
- auth load 실패: migration 보류, data loss 금지
- migration save 실패: 기존 파일 유지, in-memory canonical config 사용, 설정 message 표시
- shell regeneration 실패: canonical config 저장 상태를 유지하되 기존 shell install 오류 message 표시

오류 message와 source identifier에는 provider의 정식 명칭을 사용한다.

## 테스트

### Core config tests

1. legacy version 1 JSON decode
2. API Key command/routing/nickname canonical mapping
3. legacy OAuth defaults migration payload
4. version 2 round-trip
5. canonical encode에 다음 key가 없음을 확인
   - `commands`
   - `ccapi`
   - `ccodex`
   - `nicknames`
   - `accountPrivacy`
   - `includeDangerouslySkipPermissions`
6. `Codex.default` 사용

### Migration tests

1. 실제 auth profile이 없는 stale command profile 제거
2. legacy defaults를 provider별 첫 auth profile에 연결
3. canonical profile이 이미 있으면 legacy default로 덮어쓰지 않음
4. auth profile이 없으면 legacy OAuth defaults 폐기
5. auth load 실패 시 prune/rewrite 안 함
6. migration result가 달라졌을 때만 canonical save

### App tests

1. startup에서 stale command profile 제거·config 저장·generated function 제거
2. auth 파일이 이미 없어도 remove action이 command profile 제거
3. OAuth profile이 없을 때 top-level OAuth command/routing이 존재하지 않음
4. 신규 Codex API Key nickname 빈 값
5. 기존 Codex API Key 편집 nickname 유지
6. provider rows와 settings가 canonical API command를 사용

### Regression

- CLI command rendering
- automatic shell install
- round robin
- Fast mode
- provider settings
- menu bar와 dashboard
- 전체 `swift test`
- `CONFIGURATION=debug` development bundle 및 codesign verification

## 개인정보 fixture

공개 코드, 테스트, 문서에는 실제 이메일이나 계정 식별자를 사용하지 않는다. 이메일은 `user@example.com`, `account@example.net` 같은 예약 예시를 사용하고 file/profile ID도 `codex-work.json` 같은 비식별 fixture를 사용한다.

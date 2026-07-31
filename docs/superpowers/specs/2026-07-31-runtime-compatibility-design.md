# Runtime Compatibility Preflight 설계

- 작성일: 2026-07-31
- 상태: 승인됨
- 관련 이슈: #100 — 지원 환경과 architecture compatibility 명시

## 목적

CLIProxyManager는 macOS 15 이상과 Apple Silicon(`arm64`)용 CLIProxyAPI artifact를 전제로 하지만, 현재 지원 범위가 README·manifest·실행 경로에 일관되게 표현되지 않는다. 이 설계는 지원하지 않는 환경이나 target이 불명확한 artifact가 proxy 실행 또는 binary 교체를 시작하기 전에 안전하게 중단되도록 한다.

정책은 다음 기준을 단일 Core source에서 유지한다.

- 최소 OS: macOS 15.0
- 지원 host architecture: `arm64`
- generated shell functions 대상 shell: `zsh`
- Claude Code last-verified: `2.1.220`, verified on 2026-07-31
- CLIProxyAPI artifact target: `darwin` / `arm64`

Codex는 독립 CLI version probe를 추가하지 않는다. 현재 Codex 연결은 CLIProxyAPI를 통해 관리되므로 artifact·runtime compatibility 정책의 적용을 받는다.

## 결정

Core의 구조화된 호환성 정책, side-effect-free preflight, 실제 실행·파일 변경 경계의 재검사를 분리한다. Dashboard의 버튼 상태나 toast는 안내 역할만 하며 실행 권한의 근거가 아니다.

대안으로 UI만 차단하거나 서비스별로 조건문을 흩어놓는 방식은 `cpm`, OAuth preparation, model loading, 직접 update 경로를 우회하게 하므로 채택하지 않는다.

## Core 모델

`Sources/CLIProxyManagerCore/Compatibility/`에 다음 모델을 둔다.

- `CompatibilityAction`: status/diagnostics, stop, start/restart, OAuth preparation, model-server preparation, update stage/apply/schedule, shell-function install, artifact recovery를 구분한다.
- `RuntimeEnvironmentSnapshot`: OS version, native host architecture, 번역 실행 여부, login shell을 표현한다.
- `CLIProxyAPIArtifactTarget`: `operatingSystem`과 `architecture`를 분리해 `darwin/arm64`를 정규화한다.
- `ClaudeCodeObservation`: installed version, unavailable, version-unreadable을 구분한다. 원본 command output은 보관하지 않는다.
- `CompatibilityFinding`: unsupported OS/architecture/shell, artifact target mismatch/unknown/legacy inference, Claude unavailable/unverified를 구조화한다.
- `CompatibilityDecision`: `allowed`, `allowedWithWarnings`, `blocked`와 action별 sanitized recovery message를 제공한다.
- `RuntimeCompatibilityPolicy`: 위 기준과 action별 허용 규칙을 보유하는 순수 함수다.

기존 `DiagnosticStatus`는 proxy health 및 화면 표시 모델로 유지한다. 호환성 모델로 확장하지 않고 `CompatibilityFinding`을 UI/CLI에서 `DiagnosticStatus` 또는 concise status text로 투영한다.

## Preflight와 권한 확인

`RuntimeCompatibilityPreflight`는 host environment, manifest, Claude Code 설치·version만 읽고 report를 만든다. 다음 부수 효과는 금지한다.

- proxy launch, stop, restart
- binary download, save, apply, delete, reconciliation
- config·shell profile·secret write
- OAuth login 또는 auth state 변경

lock 안의 proxy 실행 경로는 `await`할 수 없으므로, preflight를 두 층으로 나눈다.

1. 동기 `staticSnapshot`은 OS, architecture, login shell, active/bundled/pending manifest를 읽어 host·artifact hard blocker를 만든다.
2. 비동기 full report는 위 snapshot에 `claude --version` 관찰을 더해 UI와 CLI status에 warning을 제공한다.

`RuntimeCompatibilityAuthorizer`는 action 바로 전에 새 static snapshot을 받아 권한을 다시 결정한다. Claude version 불일치는 soft warning이므로 host/artifact 실행 gate를 비동기 결과에 의존시키지 않는다. shell function install은 async full preflight를 수행해 Claude executable 부재를 확인한 뒤 write를 허용한다.

## Action 정책

| Action | 차단 조건 | 허용 조건 |
|---|---|---|
| status, logs, diagnostics | 없음 | 항상 허용 |
| stop | 없음 | 항상 허용 |
| proxy start/restart, OAuth preparation, model-server preparation | macOS 15 미만, non-arm64, active/bundled artifact target mismatch 또는 unknown | Claude version mismatch는 warning만 표시 |
| proxy update stage/apply/schedule | macOS 15 미만, non-arm64, candidate artifact target mismatch 또는 unknown | remote update check와 pending 상태 조회는 허용 |
| generated shell function install | login shell이 zsh가 아님, Claude Code executable 없음 | Claude version mismatch는 warning만 표시 |
| artifact recovery | recovery candidate target mismatch 또는 unknown | 손상된 active artifact 상태 조회와 stop은 허용 |
| rollback | 없음 | 이미 허용된 변경이 실패한 경우 이전 artifact/process 복구를 우선 |

restart는 start 목적의 action이다. 차단 판단은 기존 process를 stop하기 전에 수행해, 지원하지 않는 환경에서 이미 실행 중인 proxy를 불필요하게 종료하지 않는다.

## CLIProxyAPI artifact metadata와 legacy 처리

`CLIProxyAPIBinaryManifest`에 다음 nested target을 추가한다.

```json
"target": {
  "operatingSystem": "darwin",
  "architecture": "arm64"
}
```

`CLIProxyAPIReleaseClient`, `CLIProxyAPIArchiveVerifier`, `scripts/vendor-cliproxyapi.sh`, bundled manifest, update test fixture는 동일한 `CLIProxyAPIArtifactTarget`을 생산·전달한다. asset filename의 `darwin_aarch64`는 release naming 전용이고, policy는 정규화된 target만 사용한다.

기존 manifest에는 target이 없으므로 다음의 제한된 migration 규칙을 적용한다.

- `upstreamAsset`가 정확히 기존 production 형식 `CLIProxyAPI_<version>_darwin_aarch64.tar.gz`이면 `darwin/arm64`를 legacy-inferred finding으로 읽는다. arm64 host에서는 warning을 남기되 기존 artifact를 즉시 파기하지 않는다.
- 이 형식을 만족하지 않는 target-less manifest는 target unknown이다. proxy 실행, update stage/apply/schedule, 새 binary 저장을 fail-closed로 차단한다.
- preflight는 legacy manifest를 읽기만 한다. checksum 검증을 통과한 artifact를 이미 허용된 store mutation으로 교체·reconcile할 때만 explicit target metadata로 backfill한다.

## Enforcement 경계

### Proxy 실행

`ProxyServiceManager`가 GUI, `cpm`, OAuth, model loading의 공통 실행 경계다.

- `prepareLocked(port:)`: configuration staging과 bundled binary install 전에 authorization한다.
- `reconcileConfigurationLocked(port:forceRestart:)`: configuration staging과 managed process stop 전에 start/restart authorization한다.
- `stopLocked()`과 `restore(snapshot:relaunchPort:)`에는 gate를 두지 않아 정지와 rollback을 보존한다.

차단 오류는 typed compatibility blocker로 Core에서 보존하고, CLI는 기존 prerequisite 오류/exit path로 변환한다. GUI는 같은 blocker를 action별 recovery message로 표시한다.

### Binary mutation과 update

`ProxyUpdateService` 및 GUI의 `CLIProxyAPIUpdateService`는 download/stage/apply/schedule 전에 action authorization을 호출한다. 실제 shared mutation boundary인 `CLIProxyAPIBinaryStore`도 아래 모든 path에서 target을 재검증한다.

- `savePending`
- `schedulePendingForNextStart`
- `applyPending`
- `prepareActiveBinary`
- `reconcileBundledBinary`
- scheduled pending promotion과 bundled install

target mismatch가 있으면 active/pending binary, backup, marker, config, process state를 변경하지 않는다.

### Shell functions

`AutomaticShellInstallService.apply`를 async preflight/write boundary로 전환한다. explicit install과 automatic reconciliation 모두 여기에서 zsh와 Claude executable을 재확인한다.

- explicit install은 blocker를 반환하고 `.zshrc` 또는 functions file을 변경하지 않는다.
- automatic reconciliation은 blocker면 config 저장을 rollback하지 않고 shell write만 skip하며 compatibility 상태를 남긴다.
- app initialization은 preflight가 끝나기 전 shell file을 쓰지 않는다. 허용된 뒤에 reconciliation을 예약한다.
- compatibility failure를 이유로 기존 managed shell block을 삭제하거나 빈 script로 덮어쓰지 않는다.

## 표시와 문서

`DashboardViewModel`은 `compatibilityReport`를 publish한다. proxy health를 나타내는 `serverStatus`와 분리해, server가 정상인데 compatibility 때문에 stopped/error처럼 보이지 않게 한다.

- Dashboard: hard blocker 또는 unverified warning banner와 action·영향·recovery를 표시한다. proxy가 실행 중이면 Stop control은 계속 사용 가능하다.
- Settings: shell function과 proxy update 영역에서 blocker/warning을 action button의 disabled reason과 함께 표시한다.
- `cpm status`: text와 JSON에 sanitized compatibility summary를 포함한다. blocked start/restart/update는 prerequisite 오류로 종료하고, stop/status/logs는 계속 동작한다.

`README.md`와 `README.en.md`에는 같은 순서의 support matrix를 둔다. macOS, arm64, zsh functions, CLIProxyAPI target, Claude Code last-verified version/date, unverified warning 의미, blocked action과 recovery semantics를 문서화한다. README parity static test는 Core policy 상수와 양 언어 문서가 같은 값을 쓰는지 확인한다.

모든 메시지와 JSON은 raw Claude command output, account, email, secret, prompt, absolute home path를 포함하지 않는다.

## 테스트와 검증

### 자동 테스트

- compatibility policy action matrix: OS, architecture, shell, explicit/legacy/unknown/mismatched artifact target, Claude observation 조합
- preflight side-effect test: environment/manifest/Claude version read 외 shell installer, binary store mutation, config write, process launch/termination, OAuth 호출이 없음을 spy로 확인
- manifest encode/decode, legacy inference/backfill, release asset target propagation, vendor script 및 bundled manifest target 검증
- `CLIProxyAPIBinaryStore`: mismatch/unknown candidate가 active/pending/backup/marker를 바꾸지 않는지 검증
- `ProxyServiceManager`: blocked start/restart가 staging, activation, launch, 기존 proxy stop보다 먼저 끝나는지 검증; stop과 rollback이 계속 가능한지 검증
- update service: stage blocker가 downloader를 호출하지 않고, apply/schedule blocker가 store mutation을 만들지 않는지 검증
- shell install: non-zsh/Claude unavailable에서 explicit write가 없고 automatic reconciliation이 config/기존 shell content를 보존하는지 검증
- Dashboard/Settings/Menu bar/cpm status: shared report projection, start-disabled/stop-enabled, JSON sanitization, prerequisite 오류를 검증
- Korean/English README support matrix와 policy constants parity

### 전체 검증

- focused Core/App/script suites
- `bash scripts/run-script-tests.sh`
- `make ci-build`
- `make verify-bundle-structure`
- `swift test`
- `git diff --check`

### 수동 검증

사용자가 development app에서 support matrix 문구, Dashboard/Settings/Menu bar blocker·warning, Stop 유지, VoiceOver reading order를 확인한다. 자동화는 실제 OS/architecture/action matrix와 accessibility label을 검증하지만 앱 launch 자체를 대신하지 않는다.

## 비목표

- Intel/x86_64 artifact, universal binary, Rosetta 지원
- macOS 14 이하 지원
- bash/fish shell integration
- Codex CLI 별도 version probe
- telemetry 수집

# Legacy artifact target 경고 숨김 설계

**날짜:** 2026-08-03

## 목표

이전 `CLIProxyAPI` manifest에 명시적 `target` metadata가 없는 정상 production artifact가 `legacyArtifactTargetInferred` 경고로 Dashboard, Settings, CLI 상태 출력에 노출되지 않게 한다.

실제 호환성 차단과 artifact migration 안전성은 유지한다.

## 배경

runtime compatibility preflight는 legacy manifest의 정확한 production asset 이름 `CLIProxyAPI_<version>_darwin_aarch64.tar.gz`를 Apple Silicon용 artifact로 제한적으로 추론한다. 이 상태는 실행과 업데이트를 차단하지 않지만 `allowedWithWarnings` finding으로 만들어져 사용자 화면에 표시된다.

이 finding은 사용자 조치가 필요하지 않은 metadata migration 상태다. 검증된 artifact replacement 또는 reconciliation 시 `target` metadata가 backfill된다.

## 선택한 접근법

사용자-facing compatibility presentation에서 `legacyArtifactTargetInferred` finding만 필터링한다.

- compatibility policy는 legacy artifact를 계속 식별한다.
- binary store의 legacy target 추론 및 backfill 조건은 변경하지 않는다.
- Dashboard, Settings, CLI status는 필터링된 findings만 사용한다.
- 실제 target mismatch, 지원하지 않는 OS/아키텍처, Rosetta 실행 같은 차단 finding과 다른 actionable warning은 계속 표시한다.

finding 자체를 삭제하거나 status 조회 중 manifest를 수정하지 않는다. 전자는 내부 migration 상태의 검증 가능성을 잃고, 후자는 preflight의 read-only 보장을 깨기 때문이다.

## 구성 요소와 데이터 흐름

1. `RuntimeCompatibilityPolicy`가 전체 report를 생성한다. 여기에는 legacy finding이 계속 포함될 수 있다.
2. 사용자 상태 변환 계층이 report를 CLI/UI presentation으로 만들 때 `legacyArtifactTargetInferred`를 제외한다.
3. 필터 결과 finding이 없으면 Dashboard와 Settings는 compatibility warning을 렌더링하지 않고 CLI status도 빈 findings를 반환한다.
4. compatibility action decision은 원 report를 사용하므로 legacy artifact에 대한 허용 정책과 실제 blocker의 차단 정책은 변하지 않는다.

## 오류 처리

- legacy finding만 있는 경우 사용자에게 경고를 표시하지 않는다.
- legacy finding과 blocker가 함께 있으면 legacy finding만 숨기고 blocker의 code 및 recovery를 표시한다.
- legacy finding과 다른 non-blocking warning이 함께 있으면 그 warning은 유지한다.
- target-less manifest가 legacy production asset 규칙을 충족하지 않아 `unsupportedArtifactTarget`이 된 경우에는 계속 차단·표시한다.

## 테스트

- legacy finding만 든 report는 Dashboard와 Settings compatibility presentation을 만들지 않는지 검증한다.
- CLI status의 compatibility findings에서 legacy finding이 제외되는지 검증한다.
- legacy finding과 `unsupportedArtifactTarget`을 함께 제공했을 때 blocker가 계속 노출되고 start/restart가 차단되는지 검증한다.
- 기존 binary store 테스트로 legacy target 추론과 explicit metadata backfill이 계속 동작함을 보존한다.

## 범위 제외

- legacy manifest를 즉시 변경하거나 target metadata를 사후 일괄 수정하지 않는다.
- compatibility policy의 지원 플랫폼, architecture, Rosetta, Claude Code, shell 검사 정책을 바꾸지 않는다.
- update artifact 형식이나 release manifest 구조를 변경하지 않는다.

# Codex 역할별 Fast mode 개발 현황

## 현재 상태

Codex의 Opus·Sonnet·Haiku 역할별 Fast mode 기능은 핵심 구현까지 완료됐으며, proxy restart 동시성 보강 작업 중 일시 중단했다.

## 완료된 작업

- `CodexRole.fastModeEnabled` 저장 및 기존 JSON 하위 호환 decode
- 앱 관리 Fast alias `-cpm-fast`와 reasoning suffix 조합
- Codex model metadata의 Fast capability 조회
- fallback allowlist 및 관리 alias 필터링
- OAuth, OpenAI API Key, round-robin, legacy 설정 화면의 역할별 Fast toggle
- 미지원 모델의 Fast 값 저장 전 정규화
- OAuth/API Key alias와 `service_tier: priority` payload YAML 생성
- Fast 미사용 시 기존 YAML의 바이트 단위 호환성 유지
- legacy, OAuth, API Key, round-robin shell routing 테스트
- Fast 설정 변경 시 proxy restart의 기본 동작

## 마지막 안정 검증

커밋 `46cfad7` 기준:

- `swift test`: 746 tests, 0 failures
- `git diff --check`: 통과

## 현재 WIP

`DashboardViewModel`의 proxy restart coordinator를 보강하는 미완료 변경이 포함돼 있다.

대상:

- restart 진행 중 추가 Fast/API Key 변경을 다음 generation에서 drain
- `prepareModelServer()` 중 발생한 pending restart 처리
- 실제 API Key 변경이 없을 때 불필요한 restart 방지
- restart 실패 및 readiness 실패 시 status와 Fast 전용 메시지 일치
- 기존 invalid Fast alias 설정을 UI에서 복구할 수 있도록 old snapshot 비교 완화
- restart suspension을 제어하는 test double 및 회귀 테스트 추가

현재 WIP 변경은 중단 시점 그대로 보존했으며 전체 테스트를 완료하지 않았다.

## 남은 작업

1. WIP restart coordinator 구현과 새 회귀 테스트를 정리한다.
2. `DashboardViewModelRefreshTests` 및 전체 `swift test`를 실행한다.
3. Task 6 focused code review를 다시 수행한다.
4. `README.md`, `README.en.md`에 Fast mode 사용법을 추가한다.
5. development build를 생성한다.
6. 최종 branch review를 수행한다.

앱 실행, 스크린샷, 수동 UI 검증은 사용자가 직접 수행한다.

## 재개 위치

- 설계: `docs/superpowers/specs/2026-07-12-codex-fast-mode-design.md`
- 구현 계획: `docs/superpowers/plans/2026-07-12-codex-fast-mode.md`
- 현재 현황: 이 문서
- 브랜치: `feature/codex-fast-mode`

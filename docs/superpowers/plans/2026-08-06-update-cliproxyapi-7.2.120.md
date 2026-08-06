# CLIProxyAPI v7.2.120 update review

## 결정

번들 CLIProxyAPI를 v7.2.97에서 v7.2.120으로 갱신하고, 새 upstream option 중 `codex-api-key[].models[].max-context-length`만 채택한다.

이 값은 요청의 context 크기를 제한하는 설정이 아니다. CLIProxyAPI가 Codex client에 제공하는 model catalog의 `context_window` 및 `max_context_window` metadata를 지정한다. CLIProxyManager가 이미 role별로 관리하는 `detectedContextWindow`와 `CodexContextWindowPolicy.effectiveContextWindow`를 API-key profile의 model mapping에 전달한다.

## 채택

- `max-context-length`
  - 앱의 기존 context-window 인식, `[1m]` identifier, auto-compaction export와 의미가 일치한다.
  - CLIProxyAPI v7.2.115 이상에서만 YAML key를 생성한다.
  - OAuth alias schema는 이 key를 지원하지 않으므로 API-key model mapping만 대상으로 한다.

## 이번에 채택하지 않는 option

- `thinking.levels`: 앱이 관리하는 provider/model 범위에 별도 capability declaration이 필요하지 않다.
- credential `weight`, `routing.strategy: weighted-round-robin`: 앱의 session 단위 round-robin과 의미가 달라 routing 동작을 바꾼다.
- Claude/Codex cloaking option, `optimize-multi-agent-v2`: protocol compatibility 범위를 넓히므로 별도 기능·검증 작업이 필요하다.
- Codex Live media relay, Alpha Search, Kimi `support-prompt-cache-key`, xAI/Antigravity option: 현재 제품 provider/네트워크 범위 밖이다.
- `transient-error-cooldown-seconds`: 신규 option이 아니며, 현재 재현되지 않는 장애를 근거로 기본값을 변경하지 않는다.

## 호환성 확인

- v7.2.106부터 Codex API-key catalog는 config에 명시된 `models:`만 노출한다. Fast on/off API-key profile의 catalog와 실제 request를 smoke test한다.
- v7.2.116~120에는 Claude OAuth wire/header/thinking 관련 변경이 포함된다. Claude OAuth proxy와 thinking disabled request를 smoke test한다.
- Codex OAuth request, Responses/streaming과 Fast mode도 smoke test한다.

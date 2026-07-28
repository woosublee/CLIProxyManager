# Codex Context Window 정확한 인식 설계

## 배경

`AppConfig.CodexRole.contextWindow`(`CodexContextWindow` enum: `auto`/`200k`/`400k`/`1m`)는 설정 화면에 노출되고 저장은 되지만, `CodexRole.modelIdentifier` 생성에 전혀 반영되지 않는다. `CodexFastMode.modelIdentifier`는 model·reasoning·fastModeEnabled만 조합하고 contextWindow는 참조하지 않는다.

그 결과 Claude Code는 Codex 역할에 매핑된 GPT 모델(서드파티/게이트웨이 모델)을 항상 기본값인 200K로 인식한다. 실제로는 모델마다 실제 context window가 다르다(CLIProxyAPI가 `/v1/models?client_version=...` 응답에서 보고하는 실측값 기준):

| 모델 | context_window |
| --- | --- |
| gpt-5.6-sol / terra / luna | 372,000 |
| gpt-5.5 / codex-auto-review | 272,000 |
| gpt-image-1.5 / gpt-image-2 | 272,000 |
| gpt-5.4 | 1,050,000 (scoped registry 기준) |
| gpt-5.4-mini | 400,000 |
| gpt-5.3-codex-spark | 128,000 |

이 불일치 때문에 Claude Code의 auto-compact가 실제 모델 한계보다 훨씬 이르게(200K 기준) 발생해 가용 컨텍스트를 낭비하거나, 향후 `[1m]` suffix만 붙이는 경우 1M 기준으로 늦게 발생해 실제 provider 한계를 넘겨 잘림/오류가 날 수 있다.

Fast mode(2026-07-12 설계)는 이미 `codex-personal/gpt-5.6-sol-fast(xhigh)[1m]` 형태의 최종 표기를 언급했지만, `[1m]` 부착 로직은 구현되지 않았다.

## 목표

- Codex 역할별 실제 context window를 CLIProxyManager가 CLIProxyAPI capability metadata로부터 자동 감지한다.
- 사용자가 값을 임의로 입력·제한하지 않는다. 감지·적용은 앱이 전담한다(Fast mode capability 검증과 동일한 신뢰 수준).
- 감지된 값을 Claude Code가 인식하도록 모델 식별자와 셸 환경변수에 반영해 auto-compact가 실제 모델 한계에 맞게 동작하게 한다.

## 비목표

- Context window 크기를 사용자가 직접 선택·제한하는 UI(기존 Auto/200k/400k/1m picker는 제거)
- Claude OAuth·Claude API Key 경로(네이티브 Anthropic 모델로 Claude Code가 이미 정확히 인식함)
- CLIProxyAPI 자체 동작·파싱 로직 변경
- Claude Code 상태줄(status line)의 사용률(%) 표시를 실제 값 기준으로 보정하는 것 — 공식 문서상 상태줄은 항상 Claude Code가 인식하는 "전체" context window(`[1m]` 유무로 결정되는 200K/1M) 기준으로 계산되며, 이를 실제 값으로 바꾸는 공식 메커니즘이 없다. 이번 설계는 **compact가 일어나는 시점**의 정확성만 다루며, 상태줄 표시는 `[1m]` 부착 여부에 따라 1M 기준으로 표시될 수 있음을 알려진 한계로 받아들인다(사용자 확인 완료).

## 핵심 메커니즘 (Claude Code 공식 문서 근거)

1. **`[1m]` model-ID suffix** — Claude Code가 서드파티/게이트웨이 모델을 200K가 아닌 1M으로 가정하게 하는 유일한 스위치. Claude Code가 요청을 실제 provider에 보내기 전 클라이언트 측에서 이 suffix를 제거하므로, CLIProxyAPI가 수신하는 모델 문자열에는 영향이 없다. `CodexFastMode.canonicalModel` 등 기존 파싱 로직 변경 불필요.
2. **`CLAUDE_CODE_AUTO_COMPACT_WINDOW`(토큰 수, 환경변수)** — auto-compact 임계값을 지정한다. 공식 동작: "The value is capped at the model's actual context window"(Claude Code가 인식하는 200K/1M 기준으로 clamp됨). `[1m]`이 없는 역할에 이 값을 설정해도 200K로 안전하게 clamp되므로 역할별로 모델이 달라도 부작용이 없다.

이 두 값은 순수 로컬 `claude` CLI 프로세스 환경변수이며 CLIProxyAPI로 전달되지 않는다. 따라서 이번 변경은 앱 내부 계층(모델 옵션 파싱 → 정규화 → 식별자 생성 → 셸/YAML 생성)에 한정된다.

## 아키텍처

```
CLIProxyAPI /v1/models (context_window metadata)
        │
        ▼
ProxyModelClient → CodexModelOption.contextWindow (신규 필드, Int?)
        │
        ▼
CodexRoleRoutingOptions.normalizedRole  ← 자동 감지·정규화 (사용자 조작 없음)
        │
        ▼
AppConfig.CodexRole.detectedContextWindow (Int?, 기존 CodexContextWindow enum 대체)
        │
        ▼
CodexContextWindowPolicy (metadata 우선 → bundled registry fallback → nil)
        │
        ├─→ CodexRole.modelIdentifier → ">200_000이면 [1m]" 자동 추가
        └─→ ShellFunctionRenderer / RoundRobinSelectionService
              → 실제 최대 값 기준 CLAUDE_CODE_AUTO_COMPACT_WINDOW export
```

## 데이터 모델

### `CodexModelOption`

```swift
public struct CodexModelOption: Equatable, Sendable {
    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?
    public var supportsFastMode: Bool
    public var contextWindow: Int?   // 신규: CLIProxyAPI metadata의 context_window
}
```

`ProxyModelClient`가 이미 파싱하는 `CodexClientModelsResponse.Model`에 `context_window` 필드를 추가로 디코드해 채운다. metadata에 필드가 없거나 요청이 실패하면 option의 값은 `nil`(미확인)로 유지한다. 최종 출력에서는 이 raw metadata만 직접 사용하지 않고 아래의 공통 effective-context 정책을 적용한다.

### `AppConfig.CodexRole`

```swift
public struct CodexRole: Codable, Equatable, Sendable {
    public var model: String
    public var reasoning: CodexReasoning
    public var detectedContextWindow: Int?   // 기존 contextWindow: CodexContextWindow 필드 대체
    public var fastModeEnabled: Bool
}
```

- `CodexContextWindow` enum(`auto`/`context200k`/`context400k`/`context1m`)은 완전히 삭제한다.
- 과거 JSON의 `contextWindow` 키(문자열)는 디코드 시 그냥 무시한다. 원래도 아무 효과가 없었으므로 마이그레이션 손실이 없다.
- `>200_000`이면 확장 context로 판단한다(정확히 200,000은 표준 취급 — Claude Code 기본 200K와 동일하므로 override 불필요).

### Effective context 정책

`CodexContextWindowPolicy`가 model identifier, auto-compact export, 설정 UI에서 공통으로 사용할 값을 결정한다.

1. CLIProxyAPI metadata에서 성공적으로 감지한 `detectedContextWindow`가 있으면 해당 값을 **모델의 실제 최대 context**로 우선 사용한다.
2. metadata가 없을 때만 현재 번들 CLIProxyAPI의 scoped Codex registry와 일치하는 fallback을 사용한다.
3. registry에 없는 미래 모델·custom model은 추측하지 않고 `nil`로 유지한다.

| 모델 | 안전 fallback |
| --- | ---: |
| gpt-5.6-sol / terra / luna | 372,000 |
| gpt-5.5 / codex-auto-review | 272,000 |
| gpt-image-1.5 / gpt-image-2 | 272,000 |
| gpt-5.4 | 1,050,000 |
| gpt-5.4-mini | 400,000 |
| gpt-5.3-codex-spark | 128,000 |

Fallback은 metadata 장애나 아직 저장되지 않은 기존 설정을 복구하기 위한 안전망이지 registry를 대체하는 값이 아니다. metadata가 fallback과 다르면 metadata가 항상 우선한다. model lookup 시 routing prefix, reasoning suffix, managed `-fast` alias, `[1m]` suffix를 제거해 동일한 canonical model로 해석한다.

## 정규화

`CodexRoleRoutingOptions.normalizedRole`(기존 model/reasoning/fastModeEnabled 정규화와 같은 호출 지점, 같은 타이밍)에 추가:

```swift
let modelChanged = updated.model != previousModel
if let detected = matchingOption?.contextWindow {
    updated.detectedContextWindow = detected
} else if modelChanged {
    updated.detectedContextWindow = nil
}
```

- 사용자가 조작할 수 있는 토글이 없다. capability가 확인되면 즉시, 조용히 반영된다.
- 같은 모델에서 metadata 조회가 일시적으로 실패하면 **직전 성공 값을 유지**한다. 네트워크 오류로 `[1m]`과 auto-compact 값이 요동치지 않는다.
- 다른 모델로 변경했는데 새 metadata가 없으면 이전 모델의 값을 승계하지 않고 raw detected 값을 `nil`로 초기화한다. 알려진 새 모델은 공통 fallback으로만 해석한다.
- round-robin 공통 옵션은 모든 provider가 context 값을 보고한 경우에만 그 최솟값을 authoritative intersection으로 저장한다. 하나라도 누락되면 `nil`로 두며, 알려진 모델에만 공통 fallback이 적용된다.
- 이 정규화는 기존에 model/reasoning/fastMode 정규화가 이미 일어나는 모든 지점(모델 변경 시, `.task(id: availableModels)`, 모델 새로고침 버튼, 초기 기본값 적용 시)에서 자동으로 함께 일어난다. 별도의 config schema migration은 추가하지 않는다.

## 모델 식별자 생성

`AppConfig.CodexRole.modelIdentifier`:

```swift
public var effectiveContextWindow: Int? {
    CodexContextWindowPolicy.effectiveContextWindow(
        model: model,
        detectedContextWindow: detectedContextWindow
    )
}

public var modelIdentifier: String {
    let base = CodexFastMode.modelIdentifier(model: model, reasoning: reasoning, fastModeEnabled: fastModeEnabled)
    guard let effectiveContextWindow, effectiveContextWindow > 200_000 else { return base }
    return base + "[1m]"
}
```

결과 예시: `gpt-5.6-sol-fast(xhigh)[1m]` — Fast mode 설계 문서가 원래 의도했던 표기와 동일한 순서(모델 → fast alias → reasoning → context suffix)다.

`CodexFastMode` 자체는 변경하지 않는다(fast alias/reasoning 조합만 책임). Context suffix는 `CodexRole.modelIdentifier`에서 한 단계 더 얹는다.

## `CLAUDE_CODE_AUTO_COMPACT_WINDOW` 계산

신규 헬퍼(`CLIProxyManagerCore` 내 적절한 파일, 예: `Routing/CodexContextWindowExport.swift`):

```swift
enum CodexContextWindowExport {
    static func autoCompactWindow(for codex: AppConfig.Codex) -> Int? {
        [codex.opus, codex.sonnet, codex.haiku]
            .compactMap { $0.effectiveContextWindow }
            .filter { $0 > 200_000 }
            .min()
    }
}
```

- 세 역할 모두 확장 context가 없으면 `nil` → export 생략, Claude Code 기본값(200K) 그대로 사용.
- 각 역할에는 metadata 또는 fallback으로 확인한 **모델의 실제 최대 context 값**을 사용한다.
- 하나 이상 있으면 그중 **최솟값**을 사용한다. `CLAUDE_CODE_AUTO_COMPACT_WINDOW`는 명령 하나에 공통으로 적용되므로, 세션 중 역할을 전환해도 어느 모델의 실제 최대 한계도 넘지 않게 한다.
- `[1m]`은 Claude Code가 custom model을 200K로 제한하지 않게 할 뿐이고, auto-compact 값은 1M이 아니라 위에서 계산한 실제 provider 한계로 유지한다.

### 적용 지점

- `ShellFunctionRenderer`
  - `renderLegacyOAuthFunctions`(ccodex 레거시 함수)
  - `renderOAuthFunction`의 Codex 분기(OAuth command profile별 함수)
  - `renderCodexAPIFunction`(OpenAI API Key 함수)

  각각 정적으로 알고 있는 `AppConfig.Codex` 값에서 `CodexContextWindowExport.autoCompactWindow(for:)`를 호출해, 기존 `ANTHROPIC_DEFAULT_*_MODEL` export들과 같은 자리에 `CLAUDE_CODE_AUTO_COMPACT_WINDOW='<value>'` 한 줄을 조건부로 추가한다. 값이 `nil`이면 해당 줄을 생성하지 않는다.

- `RoundRobinSelectionService.shellEnvironmentAssignments`(Codex 분기)
  이미 `codex.opus.modelIdentifier` 등을 호출하므로 `[1m]`은 별도 수정 없이 자동으로 따라온다. 반환하는 shell assignment 목록에 `CLAUDE_CODE_AUTO_COMPACT_WINDOW` 줄만 조건부로 추가한다.

## UI 변경

`CodexRoleRoutingFields`의 "Context" 열:

- 기존 `Picker(auto/200k/400k/1m)`를 제거하고 읽기 전용 라벨로 교체한다.
- metadata 또는 안전 fallback으로 확인한 effective context 값을 축약 표기(예: `372K`, `1.05M`)로 표시한다.
- 미확인이거나 200K 이하면 `—`로 표시한다.
- 헤더 텍스트("Context")와 컬럼 폭은 기존 그대로 재사용한다(레이아웃 변경 없음).
- `CodexProviderSettingsSheet`·`CodexAPIProviderSettingsSheet` 양쪽에 공용 컴포넌트를 통해 자동 반영된다. 별도 작업 불필요.
- 사용자가 조작할 수 있는 컨트롤은 두지 않는다(사용자 요구사항: "임의로 조정하거나 제한하는 것은 아니다").

## 오류 처리

- CLIProxyAPI metadata 조회 실패 → 같은 모델의 `detectedContextWindow`는 직전 성공 값을 유지하고, 저장값이 없는 알려진 모델은 bundled registry fallback을 사용한다. `[1m]`/`AUTO_COMPACT_WINDOW` 상태가 네트워크 오류로 요동치지 않는다.
- 기존 저장 파일의 `contextWindow` 키(문자열: auto/200k/400k/1m) → 디코드 시 조용히 무시한다. 원래 효과가 없었으므로 사용자에게 손실을 알릴 필요가 없다.
- 모델을 변경하면 이전 모델의 raw detected 값은 승계하지 않는다. 새 모델이 200,000 이하로 감지되거나 fallback도 200,000 이하이면 `[1m]`이 자동으로 제거되고, `AUTO_COMPACT_WINDOW` export도 재계산되어 자동으로 빠진다.
- unknown/custom model은 metadata가 없는 한 확장 context로 추측하지 않는다.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW`를 붙이는 순간 Claude Code의 상태줄 사용률(%) 표시는 `[1m]`이 붙은 만큼 1M 분모로 계산되어 실제보다 낮게 보일 수 있다(§비목표에서 다룬 알려진 한계). 이는 버그가 아니라 Claude Code 자체의 설계이며, 이번 변경으로 해결하지 않는다.

## 번들 CLIProxyAPI 바이너리 업데이트

- 현재 번들 버전 7.2.91 → 최신 7.2.97로 업데이트한다(`scripts/vendor-cliproxyapi.sh 7.2.97`).
- 7.2.91→7.2.97 사이 `context_window`/fast mode 관련 registry나 API 응답 포맷의 breaking change는 없음을 확인했다(diff 비교 완료). 순수 버전 bump이며 기존 `ProxyServiceManagerTests` 등 회귀 없이 통과해야 한다.
- `Sources/CLIProxyManagerApp/Resources/cliproxyapi/{cliproxyapi, cliproxyapi.manifest.json}` 갱신.

## 테스트 전략

### `ProxyModelClientTests`
- metadata 응답의 `context_window` 필드 파싱.
- 필드가 없는 경우 `contextWindow == nil`.

### `AppConfigTests` / `CodexContextWindowPolicyTests`
- `detectedContextWindow`의 encode/decode round-trip.
- 구버전 JSON의 `contextWindow`(문자열) 키가 존재해도 디코드가 성공하고 `detectedContextWindow == nil`로 시작하는지.
- 전체 fallback model matrix와 routing prefix·fast alias·reasoning·`[1m]` canonicalization.
- metadata가 fallback과 다르면 metadata가 우선하는지.
- nil metadata인 알려진 272K·372K·400K·1.05M 모델에 `[1m]`이 붙고, 128K 및 unknown/custom model에는 붙지 않는지.

### `CodexRoleRoutingOptionsTests`
- 모델 변경 시 `detectedContextWindow`가 새 옵션의 `contextWindow`로 정규화되는지.
- 같은 모델의 metadata가 일시적으로 `nil`이면 직전 성공 값을 유지하는지.
- 다른 모델로 변경할 때 이전 모델의 stale 값을 제거하는지.
- UI Context 표시가 effective context를 사용하는지.

### `ShellFunctionRendererTests`
- 세 역할 중 하나 이상 확장 context가 있으면 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`가 실제 최대 값들의 최솟값으로 생성되는지.
- 세 역할 모두 확장 context가 없으면 해당 줄이 전혀 생성되지 않는지.
- metadata가 없는 legacy Codex, OAuth command profile, Codex API Key 각 경로에서도 fallback `[1m]`과 실제 최대 context가 동일하게 생성되는지.

### `RoundRobinSelectionServiceTests` / `DashboardViewModelTests`
- round-robin codex 프로필에서도 `[1m]`과 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`가 동일하게 반영되는지.
- 모든 provider가 context를 보고하면 최솟값으로 병합하고, 하나라도 누락된 custom model은 authoritative context로 오인하지 않는지.

## 실제 검증(개발 빌드)

프로젝트 기준에 따라 자동 검증은 개발 빌드까지 수행하고, 앱 실행과 Claude Code 실제 동작 확인은 사용자가 담당한다.

1. 기존 설정 파일(구버전 `contextWindow` 키 포함)로 앱을 열고 정상 기동하는지 확인.
2. Codex 역할에 gpt-5.6-sol(372K) 등 확장 context 모델을 지정하고 저장 → 생성된 `functions.zsh`에 `[1m]`과 `CLAUDE_CODE_AUTO_COMPACT_WINDOW='372000'`이 반영되는지 확인.
3. 역할을 gpt-5.4-mini(400K) 등 다른 확장 모델로 변경 → 값이 재계산되는지 확인.
4. 모든 역할을 200K 이하 모델로 변경 → `[1m]`과 `AUTO_COMPACT_WINDOW` export가 사라지는지 확인.
5. round-robin codex 프로필에서도 동일하게 반영되는지 확인.
6. (사용자 수행) 실제 Claude Code로 해당 함수를 실행해 `/status`에서 컨텍스트 사용률·compact 동작을 확인.

## 성공 기준

- Codex 역할에 매핑된 GPT 모델의 실제 context window가 CLIProxyManager에 의해 자동으로 감지되고, 사용자 개입 없이 Claude Code 셸 함수에 반영된다.
- 확장 context 모델에서 `[1m]` suffix와 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`가 metadata 또는 안전 fallback으로 확인한 실제 최대 값으로 설정되어, auto-compact가 실제 모델 한계에 맞게 동작한다.
- 확장 context가 없는 모델에서는 기존 Claude Code 기본 동작(200K)이 그대로 유지된다.
- 기존 설정 파일 decode와 개발 빌드 검증이 모두 통과한다.
- 번들 CLIProxyAPI가 7.2.97로 갱신되어도 기존 테스트가 회귀 없이 통과한다.

# Codex Fast Visible Alias Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code의 모델 선택 화면과 status-line에 Fast 모델을 `codex-personal/gpt-5.6-sol-fast(xhigh)[1m]`처럼 표시한다.

**Architecture:** Fast 요청 구분에 사용 중인 CLIProxyManager 관리 alias suffix만 `-cpm-fast`에서 `-fast`로 단순화한다. CLIProxyAPI의 alias mapping과 `service_tier: priority` payload override는 그대로 유지하고, 효과가 없었던 `ANTHROPIC_DEFAULT_*_MODEL_NAME` 및 별도 표시명 코드는 제거한다.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, zsh shell function rendering, CLIProxyAPI YAML

## Global Constraints

- Fast가 꺼진 모델 식별자는 기존 canonical 형식을 유지한다.
- Fast가 켜진 모델 식별자는 reasoning 앞에 `-fast`를 붙인다: `gpt-5.6-sol-fast(xhigh)`.
- Claude Code status-line command, settings 또는 stdin JSON을 수정하지 않는다.
- CLIProxyAPI의 OAuth/API Key alias mapping과 `service_tier: priority` 주입 구조는 유지한다.
- `ANTHROPIC_DEFAULT_*_MODEL_NAME`은 생성하지 않는다.
- `-fast`로 끝나는 입력 모델은 관리 alias 충돌로 취급한다.
- 사용자가 요청하지 않았으므로 commit, push, PR 생성은 하지 않는다.

---

### Task 1: Fast alias 계약을 `-fast`로 변경

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Routing/CodexFastMode.swift:3-68`
- Test: `Tests/CLIProxyManagerCoreTests/CodexFastModeTests.swift`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:108-123`
- Test: `Tests/CLIProxyManagerCoreTests/ProxyModelClientTests.swift:245-275`
- Test: `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift:1930-2050`
- Test: `Tests/CLIProxyManagerAppTests/ProviderSettingsSheetMetricsTests.swift:70-80`

**Interfaces:**
- Consumes: `CodexFastMode.alias(for:)`, `isManagedAlias(_:)`, `canonicalModel(from:)`, `modelIdentifier(model:reasoning:fastModeEnabled:)`
- Produces: Fast 요청 ID `gpt-5.6-sol-fast(xhigh)`와 canonical 복원 `gpt-5.6-sol`

- [ ] **Step 1: 테스트 기대값을 새 alias 계약으로 변경**

대표 기대값을 다음처럼 바꾸고, 테스트 fixture의 모든 관리 alias를 동일하게 갱신한다.

```swift
XCTAssertEqual(CodexFastMode.alias(for: "gpt-5.6-sol"), "gpt-5.6-sol-fast")
XCTAssertTrue(CodexFastMode.isManagedAlias("gpt-5.6-sol-fast"))
XCTAssertEqual(CodexFastMode.canonicalModel(from: "gpt-5.6-sol-fast(xhigh)"), "gpt-5.6-sol")
XCTAssertEqual(
    CodexFastMode.modelIdentifier(model: "gpt-5.6-sol", reasoning: .xhigh, fastModeEnabled: true),
    "gpt-5.6-sol-fast(xhigh)"
)
```

충돌 fixture도 `upstream-fast` 및 `gpt-5.6-sol-fast`로 바꾼다.

- [ ] **Step 2: 선택 테스트를 실행해 새 계약이 실패하는지 확인**

Run:

```bash
swift test --filter CodexFastModeTests
```

Expected: 기존 `-cpm-fast` 구현 때문에 `-fast` 기대값이 FAIL.

- [ ] **Step 3: 관리 alias suffix를 최소 변경**

`CodexFastMode.swift`에서 다음 상수만 변경하고 alias 생성·복원 알고리즘은 유지한다.

```swift
public static let managedAliasSuffix = "-fast"
```

표시명 우회 코드인 `displayIdentifier(...)`와 이를 위해 분리한 private `modelIdentifier(model:reasoning:)`는 제거하고, 요청 식별자 생성을 다음처럼 원래의 단일 경로로 복원한다.

```swift
public static func modelIdentifier(
    model: String,
    reasoning: AppConfig.CodexReasoning,
    fastModeEnabled: Bool
) -> String {
    let base = baseModel(from: model)
    let requestedModel = fastModeEnabled ? alias(for: base) : base
    return reasoning == .auto ? requestedModel : "\(requestedModel)(\(reasoning.rawValue))"
}
```

- [ ] **Step 4: alias 및 config 테스트를 실행**

Run:

```bash
swift test --filter CodexFastModeTests
swift test --filter AppConfigTests
swift test --filter ProxyModelClientTests
swift test --filter DashboardViewModelTests
swift test --filter ProviderSettingsSheetMetricsTests
```

Expected: 모두 PASS, 관리 alias 관련 기대값은 `-fast`만 사용.

---

### Task 2: 효과 없는 모델 표시명 환경 변수 제거

**Files:**
- Modify: `Sources/CLIProxyManagerCore/Config/AppConfig.swift:126-147`
- Modify: `Sources/CLIProxyManagerCore/Routing/RoundRobinSelectionService.swift:86-124`
- Modify: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift:150-335`
- Test: `Tests/CLIProxyManagerCoreTests/AppConfigTests.swift:108-123`
- Test: `Tests/CLIProxyManagerCoreTests/RoundRobinSelectionServiceTests.swift:60-82`
- Test: `Tests/CLIProxyManagerCoreTests/ShellFunctionRendererTests.swift`

**Interfaces:**
- Consumes: `AppConfig.CodexRole.modelIdentifier`
- Produces: 실제 routing ID만 설정하는 shell function과 round-robin assignment

- [ ] **Step 1: 회귀 테스트를 routing ID 중심으로 정리**

`modelDisplayName` assertion을 제거하고 shell output에 picker 전용 변수가 없음을 검증한다.

```swift
XCTAssertEqual(role.modelIdentifier, "gpt-5.6-sol-fast(max)")
```

```swift
XCTAssertTrue(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='codex-b/gpt-5.6-sol-fast(xhigh)'"))
XCTAssertFalse(output.contains("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"))
XCTAssertFalse(output.contains("ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"))
XCTAssertFalse(output.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"))
```

`ShellFunctionRendererTests`의 Fast 기대값도 다음 형식으로 바꾸고 `_MODEL_NAME` 기대 assertion은 제거한다.

```swift
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.6-sol-fast(xhigh)'"))
XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='gpt-5.5-fast'"))
XCTAssertFalse(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"))
```

- [ ] **Step 2: 선택 테스트를 실행해 현재 표시명 변수가 노출되는지 확인**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter RoundRobinSelectionServiceTests
swift test --filter ShellFunctionRendererTests
```

Expected: `_MODEL_NAME` 부재 assertion이 현재 구현에서 FAIL하거나 `modelDisplayName` 제거 전 계약과 불일치.

- [ ] **Step 3: 표시명 관련 소스 변경을 제거**

`AppConfig.CodexRole`에서 다음 property를 삭제한다.

```swift
public var modelDisplayName: String { ... }
```

`RoundRobinSelectionService`는 세 routing assignment와 profile assignment만 반환하도록 복원한다.

```swift
return [
    shellAssignment(name: "ANTHROPIC_DEFAULT_OPUS_MODEL", value: models.opus),
    shellAssignment(name: "ANTHROPIC_DEFAULT_SONNET_MODEL", value: models.sonnet),
    shellAssignment(name: "ANTHROPIC_DEFAULT_HAIKU_MODEL", value: models.haiku),
    shellAssignment(name: "CLIPROXY_ROUND_ROBIN_PROFILE", value: selected.authProfileID)
].joined(separator: "\n")
```

`ShellFunctionRenderer`에서 다음을 모두 제거한다.

- `ANTHROPIC_DEFAULT_OPUS_MODEL_NAME`
- `ANTHROPIC_DEFAULT_SONNET_MODEL_NAME`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME`
- direct auth command의 대응 `env -u` 항목
- round-robin의 `modelNameEnvironment`

실제 `ANTHROPIC_DEFAULT_*_MODEL`과 Claude 실행 명령은 변경하지 않는다.

- [ ] **Step 4: shell 및 round-robin 테스트 실행**

Run:

```bash
swift test --filter AppConfigTests
swift test --filter RoundRobinSelectionServiceTests
swift test --filter ShellFunctionRendererTests
```

Expected: 모두 PASS, 생성 결과에 `MODEL_NAME`이 없고 Fast routing ID는 `-fast` 형식.

---

### Task 3: CLIProxyAPI YAML과 전체 회귀 검증

**Files:**
- Test: `Tests/CLIProxyManagerCoreTests/ProxyServiceManagerTests.swift:75-180`
- Modify: `docs/superpowers/plans/2026-07-13-codex-fast-mode-progress.md`

**Interfaces:**
- Consumes: `CodexFastConfiguration.allAliases`, `ProxyServiceManager.config(for:)`
- Produces: canonical-to-`-fast` alias mapping과 `service_tier: priority` payload override

- [ ] **Step 1: YAML 테스트 기대값과 진행 문서를 `-fast`로 갱신**

대표 YAML assertion은 다음을 검증한다.

```swift
XCTAssertTrue(yaml.contains("alias: \"gpt-5.6-sol-fast\""))
XCTAssertTrue(yaml.contains("service_tier: priority"))
XCTAssertFalse(yaml.contains("-cpm-fast"))
```

진행 문서의 관리 alias 및 shell function 예시도 `-fast(reasoning)`으로 변경한다.

- [ ] **Step 2: Core와 App 전체 테스트 실행**

Run:

```bash
swift test
```

Expected: 0 failures.

- [ ] **Step 3: 잔여 우회 코드와 구 suffix를 검사**

Run:

```bash
rg -n -- '-cpm-fast|modelDisplayName|displayIdentifier|ANTHROPIC_DEFAULT_.*_MODEL_NAME' Sources Tests docs/superpowers/specs/2026-07-12-codex-fast-mode-design.md docs/superpowers/plans/2026-07-13-codex-fast-mode-progress.md
git diff --check
```

Expected: 검색 결과 없음, `git diff --check` exit 0.

- [ ] **Step 4: development app bundle 빌드와 서명 검증**

Run:

```bash
make verify CONFIGURATION=debug BUILD_DIR=build/development
```

Expected: Swift build 성공, app bundle 생성, `codesign verification passed`.

- [ ] **Step 5: 사용자 shell 설정을 보호한 상태로 앱 실행 확인**

실제 앱 실행 전 다음 두 파일을 임시 디렉터리에 백업한다.

```bash
VERIFY_BACKUP="$(mktemp -d /tmp/CLIProxyManager.issue73.shell.XXXXXX)"
cp "$HOME/.zshrc" "$VERIFY_BACKUP/zshrc" 2>/dev/null || true
cp "$HOME/.cliproxy-manager/functions.zsh" "$VERIFY_BACKUP/functions.zsh" 2>/dev/null || true
open "build/development/CLIProxyManager.app"
```

프로세스 실행을 확인한 후 원본 설정을 복원한다.

```bash
pgrep -f 'build/development/CLIProxyManager.app/Contents/MacOS/CLIProxyManager'
cp "$VERIFY_BACKUP/zshrc" "$HOME/.zshrc" 2>/dev/null || true
cp "$VERIFY_BACKUP/functions.zsh" "$HOME/.cliproxy-manager/functions.zsh" 2>/dev/null || true
```

Expected: app process PID 출력, 백업이 존재한 각 shell 설정 파일이 원래 내용과 일치.

- [ ] **Step 6: 생성 shell function의 사용자-facing 모델 ID 확인**

앱이 생성한 `functions.zsh`에서 Fast 역할이 다음 형태인지 확인한다.

```text
ANTHROPIC_DEFAULT_OPUS_MODEL='codex-personal/gpt-5.6-sol-fast(xhigh)'
```

Claude Code가 1M context로 실행되는 환경에서는 status-line의 최종 표기가 다음 형태가 된다.

```text
codex-personal/gpt-5.6-sol-fast(xhigh)[1m]
```

Expected: `-cpm-fast`와 `ANTHROPIC_DEFAULT_*_MODEL_NAME`이 생성되지 않음.

# Provider Settings and Menu Bar Design

## Goal

CLIProxyManager를 macOS Settings 앱과 menu bar companion으로 구성해, Claude/Claude API/Codex provider의 연결 상태, 실행 함수, 모델 설정, permission 설정, app-managed CLIProxyAPI 서버 상태를 한 곳에서 관리한다.

## Product Shape

앱 이름은 `CLIProxyManager`로 유지한다. 앱은 Dock에 표시되는 일반 macOS 앱으로 실행된다. 동시에 menu bar item도 제공한다. 사용자는 `Command + ,`로 열리는 설정 창에서 provider를 관리하고, menu bar에서는 현재 provider 상태와 함수명을 빠르게 확인하며 서버를 시작/중지할 수 있다.

설정 창은 앱의 설정 UI라는 개념으로 동작한다. 앱 자체의 이름이나 menu bar item 이름은 `CLIProxyManager`다. 기존 Dashboard라는 명칭은 사용하지 않는다.

## Scope

MVP 범위는 다음이다.

- Settings 창을 `Providers`, `General`, `Licenses` 탭으로 구성한다.
- `Providers` 탭은 Claude, Claude API, Codex provider 목록을 보여준다.
- Provider 목록 상단에는 `+` 버튼을 둔다.
- `+` 버튼은 MVP에서 “추가 provider는 추후 지원” 안내만 표시한다.
- 각 provider row는 연결 상태, 실행 함수명, `Connect`, `Disconnect`, `Settings` 액션을 제공한다.
- 연결된 provider는 Settings sheet에서 함수명, 모델, reasoning, context window, permission을 설정할 수 있다.
- `General` 탭은 port, start at login, server ON/OFF, shell install 상태, Dock/menu bar 표시 옵션을 제공한다.
- `Licenses` 탭은 CLIProxyAPI MIT license와 provider 약관 고지를 보여준다.
- 앱 실행 시 기본 shell functions를 자동 설치한다.
- provider 설정이 변경될 때마다 `functions.zsh`를 즉시 재생성하고 `.zshrc` managed block을 유지한다.
- 오른쪽 상단에 app-managed server ON/OFF 토글을 제공한다.
- menu bar에서도 server start/stop을 제공한다.
- menu bar에는 현재 연결된 provider와 실행 함수명을 요약해 표시한다.
- `Command + W`는 창만 닫는다.
- `Command + Q`는 종료 확인 dialog를 띄우고, 확인 시 app-managed server를 종료한 뒤 앱을 종료한다.

## Non-goals

- MVP에서 custom provider 추가를 구현하지 않는다.
- MVP에서 OpenRouter 같은 추가 preset provider를 구현하지 않는다.
- 외부 `8317` CLIProxyAPI 서버, Homebrew service, 현재 사용 중인 Claude Code proxy를 종료하지 않는다.
- OpenAI/Codex OAuth 로그인 플로우 자체를 앱 안에서 완성하지 않는다. Codex 연결은 CLIProxyAPI 상태와 사용 가능성 확인 중심으로 처리한다.
- 실제 1M context 지원을 보장하지 않는다. 앱은 context window 요청값만 설정한다.
- `sk-dummy` local API key 사용자 편집은 이번 범위에 포함하지 않는다.

## Defaults

```text
port: 18317

providers:
  claude:
    enabled: true
    functionName: ccm
    permissionMode: safe
  claudeAPI:
    enabled: true
    functionName: ccmapi
    model: claude-opus-4-7
    permissionMode: safe
  codex:
    enabled: true
    functionName: ccmcodex
    opus:
      model: gpt-5.5
      reasoning: xhigh
      contextWindow: auto
    sonnet:
      model: gpt-5.5
      reasoning: medium
      contextWindow: auto
    haiku:
      model: gpt-5.5
      reasoning: low
      contextWindow: auto
    permissionMode: safe

startAtLogin: false
showDockIcon: true
showMenuBarIcon: true
```

`showDockIcon`가 off이면 앱은 menu bar 중심으로 동작하고 Dock 아이콘을 숨긴다. 이 변경은 macOS activation policy 특성상 앱 재시작 후 반영될 수 있다. `showMenuBarIcon`은 기본적으로 on이다. 사용자가 Dock과 menu bar를 둘 다 끄려 하면 저장하지 않고 최소 하나는 켜야 한다고 안내한다.

## Provider Model

기존 `AppConfig`를 확장해 provider 중심 구조로 이동한다. 기존 `commands.cc`, `commands.ccapi`, `commands.ccodex`는 구현 전환 중 호환용 computed property 또는 migration으로 처리할 수 있지만, UI와 shell rendering의 기준은 provider config다.

```swift
struct AppConfig {
    var port: Int
    var providers: ProviderConfig
    var startAtLogin: Bool
    var showDockIcon: Bool
    var showMenuBarIcon: Bool
}

struct ProviderConfig {
    var claude: ClaudeProviderConfig
    var claudeAPI: ClaudeAPIProviderConfig
    var codex: CodexProviderConfig
}

struct ClaudeProviderConfig {
    var functionName: String
    var permissionMode: PermissionMode
}

struct ClaudeAPIProviderConfig {
    var functionName: String
    var model: String
    var permissionMode: PermissionMode
}

struct CodexProviderConfig {
    var functionName: String
    var opus: CodexRole
    var sonnet: CodexRole
    var haiku: CodexRole
    var permissionMode: PermissionMode
}
```

MVP 구현에서 schema migration 비용이 크면 현재 `AppConfig.Commands`, `ClaudeAPI`, `Codex` 구조를 내부 저장 구조로 유지하되, `ProviderRow` ViewModel을 통해 provider 중심으로 표현한다. 단, UI는 반드시 provider 목록을 기준으로 한다.

## Settings Window

설정 창은 macOS 설정 창 역할을 한다. 창의 UI 역할은 settings지만 앱 이름은 계속 `CLIProxyManager`로 표시한다.

### Providers 탭

상단:

```text
Providers                                      +
```

`+` 버튼 클릭 시:

```text
추가 provider는 추후 지원됩니다.
현재 MVP에서는 Claude, Claude API, Codex를 설정할 수 있습니다.
```

Provider rows:

```text
Claude        Connected / Not connected       function: ccm       Connect / Disconnect / Settings
Claude API    API key set / Missing key        function: ccmapi    Connect / Disconnect / Settings
Codex         Ready / Needs setup / Stopped    function: ccmcodex  Connect / Disconnect / Settings
```

연결 상태 기준:

- Claude: `claude auth status` 또는 기존 `ClaudeConnector.status()` 결과.
- Claude API: Keychain에 `claude-api-key`가 있으면 connected.
- Codex: app-managed server의 인증 헤더 포함 `/v1/models` 결과가 200이면 ready. 401이면 auth mismatch. 연결 실패면 stopped.

Actions:

- `Connect`
  - Claude: `claude auth login` 안내 또는 실행 액션.
  - Claude API: API key 입력 sheet를 열고 Keychain에 저장.
  - Codex: app-managed server start와 CLIProxyAPI/OAuth setup 안내.
- `Disconnect`
  - Claude: `claude auth logout` 안내 또는 실행 액션.
  - Claude API: Keychain API key 삭제.
  - Codex: app-managed server stop만 수행한다. 외부 `8317` 서버는 건드리지 않는다.
- `Settings`
  - Provider별 설정 sheet를 연다.

### Provider Settings Sheets

Claude settings:

- Function name
- Permission mode

Claude API settings:

- Function name
- Claude API model
- Permission mode

Codex settings:

- Function name
- 모델 목록 새로고침
- Opus role: model, reasoning, context window
- Sonnet role: model, reasoning, context window
- Haiku role: model, reasoning, context window
- Permission mode

Codex model 목록은 app-managed proxy의 `/v1/models`에서 `Authorization: Bearer sk-dummy`를 붙여 가져온다. 실패하면 직접 입력 fallback을 제공한다.

Reasoning options:

- auto
- low
- medium
- high
- xhigh

Context window options:

- auto
- 200k
- 400k
- 1m

`1m` 선택 시 UI에 다음 문구를 표시한다.

```text
1M context 요청값을 전달합니다. 실제 사용 가능 여부는 Codex 계정, 모델, OAuth 세션, CLIProxyAPI 지원 여부에 따라 달라집니다.
```

### General 탭

General tab fields:

- App-managed server port
- Server ON/OFF toggle
- Start at login toggle
- Show Dock icon toggle
- Show menu bar icon toggle
- Shell install status
- Reinstall shell functions button

Rules:

- Port는 `1024...65535` 범위를 권장한다.
- Server toggle은 app-managed process만 시작/중지한다.
- Start at login은 macOS login item 설정으로 연결한다.
- Show Dock icon off는 menu bar mode로 전환한다.
- Dock icon과 menu bar icon을 동시에 off로 저장할 수 없다.
- Shell install은 기본적으로 자동이지만, 수동 reinstall도 가능하다.

### Licenses 탭

- CLIProxyAPI MIT license
- OpenAI/Codex, Anthropic/Claude 등 provider 약관 확인 안내
- 공개 배포 시 upstream license와 provider terms를 사용자가 확인해야 한다는 고지

## Menu Bar

앱은 menu bar item을 제공한다.

표시 내용:

```text
CLIProxyManager
Server: Running / Stopped

Connected Providers
✓ Claude      ccm
✓ Claude API  ccmapi
✓ Codex       ccmcodex

Start Server / Stop Server
Open Settings
Quit...
```

Start/Stop은 app-managed server만 제어한다. Quit은 Settings 창에서의 `Command + Q`와 동일하게 종료 확인 후 app-managed server를 종료하고 앱을 종료한다.

## Shell Install Policy

앱 첫 실행 시 기본 설정으로 shell functions를 자동 설치한다.

자동 설치 범위:

- `~/.cliproxy-manager/functions.zsh` 생성/갱신
- `.zshrc`의 CLIProxyAPI Manager managed block 추가/갱신

Provider 설정 변경 시:

- config 저장
- shell function renderer 실행
- shell installer 실행
- 충돌이 있으면 설정은 저장하되 shell 적용 실패 메시지를 보여준다. 또는 저장 전 충돌 검사를 먼저 수행해 저장을 중단한다. MVP에서는 저장 전 충돌 검사 후 저장 중단을 기본으로 한다.

사용자가 만든 alias/function은 수정하지 않는다.

## Lifecycle and Shortcuts

- `Command + ,`: Settings 창 열기
- `Command + W`: 현재 Settings 창 닫기
- `Command + Q`: 종료 확인 dialog 표시

Quit confirmation:

```text
CLIProxyManager를 종료할까요?
앱이 시작한 CLIProxyAPI 서버도 함께 종료됩니다.
[취소] [서버 종료 후 앱 종료]
```

확인 시:

1. app-managed server stop
2. 앱 종료

취소 시 아무 것도 하지 않는다.

## Acceptance Criteria

- 앱은 Dock에 표시되고 menu bar item도 표시된다.
- Settings 창은 `Providers`, `General`, `Licenses` 탭을 가진다.
- `Command + ,`로 Settings 창을 열 수 있다.
- Provider 목록에는 Claude, Claude API, Codex가 표시된다.
- Provider 목록 상단 `+` 버튼은 추후 지원 안내를 보여준다.
- Provider row는 연결 상태, 함수명, Connect/Disconnect/Settings 액션을 보여준다.
- Codex settings는 model, reasoning, context window를 role별로 분리 설정한다.
- General tab에서 port, start at login, Dock/menu bar 표시 옵션, server ON/OFF를 설정한다.
- 설정 변경 시 shell functions가 즉시 재생성된다.
- 첫 실행 시 기본 shell functions가 자동 설치된다.
- Menu bar에서 connected providers와 function names를 확인할 수 있다.
- Menu bar에서 server start/stop을 할 수 있다.
- `Command + W`는 창만 닫는다.
- `Command + Q`는 확인 dialog 후 app-managed server를 종료하고 앱을 종료한다.
- 외부 `8317` 서버나 Homebrew service는 종료하지 않는다.

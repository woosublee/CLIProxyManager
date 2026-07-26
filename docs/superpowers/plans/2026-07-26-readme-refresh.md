# README v0.1.27 Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자 제공 expanded·compact Usage HUD 이미지를 README의 두 번째·세 번째 이미지로 배치하고, 국·영문 README를 CLIProxyManager v0.1.27의 주요 사용자 기능에 맞게 최신화한다.

**Architecture:** 기존 README의 설치·시작·Usage HUD·CLI·업데이트·보안 흐름은 유지한다. PNG 원본은 수정 없이 repository asset으로 복사하고, 국·영문 문서는 같은 이미지 순서·섹션 순서·명령 범위를 공유하면서 각 언어에 자연스럽게 작성한다.

**Tech Stack:** GitHub Flavored Markdown, inline HTML `<table>`/`<img>`, PNG, zsh/bash validation

## Global Constraints

- 기존 `docs/assets/readme-main-window.png`의 binary content를 변경하지 않는다.
- 사용자 제공 expanded·compact PNG를 crop, rescale, recompress 또는 보정하지 않는다.
- 상단 이미지 순서는 메인 대시보드, expanded Usage HUD, compact Usage HUD다.
- 국문과 영문은 동일한 이미지 파일, 섹션 순서, 기능 범위, shell command, link를 사용한다.
- `OAuth`, `API Key`, `Usage HUD`, `Fast mode`, `round-robin`, `CLIProxyAPI`, `cpm` 제품 용어를 유지한다.
- README는 주요 사용자 기능을 설명하되 release history나 내부 구현 changelog로 확장하지 않는다.
- `macOS 15 이상` / `macOS 15 or later` 요구 사항을 유지한다.
- 앱 코드, 설정 schema, release workflow를 변경하지 않는다.
- 문서와 PNG 자산만 변경하며 runtime build와 전체 앱 test suite는 실행하지 않는다.
- subagent는 사용자가 명시적으로 동의한 경우에만 사용한다.
- 구현 commit은 사용자가 실행 방식을 승인하면서 단계별 commit을 허용한 경우에만 생성한다.

---

## File Structure

- Preserve: `docs/assets/readme-main-window.png`
  - 기존 메인 대시보드 이미지다. 해시가 변경되지 않아야 한다.
- Replace: `docs/assets/readme-usage-hud.png`
  - mixed OAuth subscription/API Key usage가 보이는 expanded HUD 원본을 저장한다.
- Create: `docs/assets/readme-usage-hud-compact.png`
  - 같은 계정 집합을 보여 주는 compact HUD 원본을 저장한다.
- Modify: `README.md`
  - 한국어 소개, 주요 기능, 계정과 라우팅, Usage HUD, `cpm`, 업데이트 설명을 갱신한다.
- Modify: `README.en.md`
  - 한국어 README와 동일한 기능 범위를 자연스러운 영어로 갱신한다.

---

### Task 1: Expanded·compact Usage HUD 이미지 자산 추가

**Files:**
- Preserve: `docs/assets/readme-main-window.png`
- Replace: `docs/assets/readme-usage-hud.png`
- Create: `docs/assets/readme-usage-hud-compact.png`
- Source only: `/Users/woosublee/Downloads/스크린샷 2026-07-26 오후 8.55.22.png`
- Source only: `/Users/woosublee/Downloads/스크린샷 2026-07-26 오후 8.55.34.png`

**Interfaces:**
- Consumes: 사용자 제공 PNG 원본 두 개
- Produces: README가 참조할 `readme-usage-hud.png`와 `readme-usage-hud-compact.png`
- Expanded SHA-256: `949fd2701cf6169d254628e5942b8445ce521ed39092baa056d9842bd290ef06`
- Compact SHA-256: `6eaf4cdeaa3b35e48d663b5dda4cad17f21f26764b5419702ba11249511abc94`
- Preserved main SHA-256: `05c18d7d0028e8a331320416455eee5f79a54d857b1c7cbf1b5691fda22ad290`

- [ ] **Step 1: 새 이미지 계약이 현재 자산에서 실패하는지 확인**

Run:

```bash
test "$(shasum -a 256 docs/assets/readme-usage-hud.png | cut -d' ' -f1)" = \
  "949fd2701cf6169d254628e5942b8445ce521ed39092baa056d9842bd290ef06"
test -f docs/assets/readme-usage-hud-compact.png
```

Expected: FAIL. 기존 expanded HUD의 SHA-256은 `6c6f99ea5dad0080a51f30ccf1f2c62ff110083226705965dbfa2e5ba528cdeb`이고 compact asset은 아직 없다.

- [ ] **Step 2: 사용자 제공 PNG를 repository asset으로 복사**

Run:

```bash
cp '/Users/woosublee/Downloads/스크린샷 2026-07-26 오후 8.55.22.png' \
  docs/assets/readme-usage-hud.png
cp '/Users/woosublee/Downloads/스크린샷 2026-07-26 오후 8.55.34.png' \
  docs/assets/readme-usage-hud-compact.png
```

파일 변환 명령은 실행하지 않는다.

- [ ] **Step 3: 이미지 해시·형식·dimensions와 기존 main asset 보존 확인**

Run:

```bash
test "$(shasum -a 256 docs/assets/readme-main-window.png | cut -d' ' -f1)" = \
  "05c18d7d0028e8a331320416455eee5f79a54d857b1c7cbf1b5691fda22ad290"
test "$(shasum -a 256 docs/assets/readme-usage-hud.png | cut -d' ' -f1)" = \
  "949fd2701cf6169d254628e5942b8445ce521ed39092baa056d9842bd290ef06"
test "$(shasum -a 256 docs/assets/readme-usage-hud-compact.png | cut -d' ' -f1)" = \
  "6eaf4cdeaa3b35e48d663b5dda4cad17f21f26764b5419702ba11249511abc94"
file docs/assets/readme-usage-hud.png docs/assets/readme-usage-hud-compact.png | grep -F 'PNG image data'
sips -g pixelWidth -g pixelHeight \
  docs/assets/readme-usage-hud.png \
  docs/assets/readme-usage-hud-compact.png
```

Expected:

```text
readme-usage-hud.png: pixelWidth 692, pixelHeight 1014
readme-usage-hud-compact.png: pixelWidth 308, pixelHeight 1274
```

- [ ] **Step 4: 이미지 asset commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add docs/assets/readme-main-window.png \
  docs/assets/readme-usage-hud.png \
  docs/assets/readme-usage-hud-compact.png
git commit -m "docs: refresh Usage HUD screenshots" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

`readme-main-window.png`는 `git add` 대상에 포함해도 content가 동일하므로 commit diff에는 나타나지 않아야 한다.

---

### Task 2: 한국어 README를 v0.1.27 기능에 맞게 최신화

**Files:**
- Modify: `README.md:5-135`
- Consume: Task 1의 PNG asset 경로

**Interfaces:**
- Consumes: `docs/assets/readme-main-window.png`, `docs/assets/readme-usage-hud.png`, `docs/assets/readme-usage-hud-compact.png`
- Produces: 한국어 사용자 문서와 영어 README가 따라야 할 섹션·기능 기준

- [ ] **Step 1: 한국어 README 기능·이미지 계약이 현재 문서에서 실패하는지 확인**

Run:

```bash
rg -q 'readme-usage-hud-compact\.png' README.md
rg -q '^## 계정과 라우팅$' README.md
rg -q 'Day/Mon' README.md
rg -q 'cpm quota key set --stdin' README.md
rg -q 'cpm update apply all --yes' README.md
```

Expected: FAIL. compact image, 계정과 라우팅 섹션, API Key Day/Mon 설명, quota key와 target-aware update 예시가 아직 없다.

- [ ] **Step 2: 상단 이미지와 소개·주요 기능 교체**

`README.md`의 기존 `<table>`부터 `## 요구 사항` 직전까지를 다음 내용으로 교체한다.

```markdown
<table>
  <tr>
    <td><img src="docs/assets/readme-main-window.png" alt="CLIProxyManager 다중 계정 대시보드" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud.png" alt="OAuth 구독 사용률과 API Key 예상 비용을 함께 보여 주는 expanded Usage HUD" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud-compact.png" alt="계정별 사용률과 API 예상 비용을 세로로 보여 주는 compact Usage HUD" width="100"></td>
  </tr>
</table>

CLIProxyManager는 여러 Claude·Codex OAuth 구독, Claude·OpenAI API Key, 로컬 CLIProxyAPI 서버를 macOS 메뉴바에서 관리하는 앱입니다. 계정마다 전용 명령어를 만들고 모델 라우팅과 round-robin을 설정하며, 구독 사용률과 API 예상 비용을 하나의 Usage HUD에서 확인할 수 있습니다.

## 주요 기능

- Claude·Codex OAuth 계정과 Claude·OpenAI API Key를 한곳에서 추가하고 관리
- 계정별 명령어·별칭·활성화 상태·순서·상세정보 공개 여부·Usage HUD 표시 여부 설정
- Claude OAuth의 Direct/CLIProxyAPI 연결 선택과 계정별 Claude model mapping
- Codex OAuth와 OpenAI API Key의 Opus·Sonnet·Haiku 역할별 GPT model, reasoning, 감지된 context window, Fast mode 설정
- 선택한 OAuth 계정을 새 CLI session마다 순환하고 session 안에서는 계정을 고정하는 round-robin 명령어
- 로컬 CLIProxyAPI 서버 시작·중지·상태·로그 확인
- 메뉴바, expanded HUD, compact HUD에서 OAuth 구독 사용률과 API Key token·request·예상 비용 확인
- **cpm Command Line Tool**로 터미널이나 SSH에서 proxy·앱·quota·업데이트 관리

```

- [ ] **Step 3: 요구 사항과 시작하기를 현재 provider 범위에 맞게 교체**

`## 요구 사항`부터 `## 사용량 HUD` 직전까지를 다음 내용으로 교체한다.

````markdown
## 요구 사항

- macOS 15 이상
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 설치
- Claude/Codex OAuth 계정 또는 Claude/OpenAI API Key
- 생성된 터미널 명령어를 사용할 경우 zsh

## 설치 및 macOS 보안 경고

배포본은 자체 서명되어 있지만 Apple 공증을 받지 않았습니다. 따라서 처음 실행할 때 macOS 보안 경고가 나타날 수 있습니다.

1. [Releases](https://github.com/woosublee/CLIProxyManager/releases/latest)에서 최신 DMG를 내려받아 앱을 설치합니다.
2. 경고가 나타나면 Finder에서 앱을 Control-클릭한 뒤 **열기**를 선택하거나, **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다.

GitHub Releases에서 직접 내려받은 배포본만 사용하세요.

## 시작하기

1. 앱에서 **Add Provider**를 눌러 Claude/Codex OAuth subscription 또는 Claude/OpenAI API Key를 추가합니다.
2. 계정별 Settings에서 nickname과 전용 명령어를 지정합니다. 예: `claude-work`, `codex-personal`
3. 새 터미널을 열거나 다음 명령을 실행합니다.

   ```zsh
   source ~/.zshrc
   ```

4. 지정한 명령어로 실행합니다.

   ```zsh
   claude-work
   codex-personal
   ```

## 계정과 라우팅

- 메인 화면에서 drag handle이나 더보기 메뉴를 사용해 계정 순서를 바꿀 수 있습니다. 같은 순서가 메뉴바와 Usage HUD에도 적용됩니다.
- OAuth 계정은 비활성화했다가 다시 활성화할 수 있고, 계정 상세정보를 흐리거나 Usage HUD 표시 대상에서 제외할 수 있습니다.
- Claude OAuth는 **Direct** 또는 **CLIProxyAPI** 연결을 선택할 수 있습니다. Direct는 Claude Code의 현재 model policy를 사용하고, CLIProxyAPI 연결은 계정별 model mapping을 사용합니다.
- Codex OAuth와 OpenAI API Key는 Opus·Sonnet·Haiku 역할마다 GPT model과 reasoning을 선택할 수 있습니다. 지원 모델에서는 Fast mode를 켤 수 있으며, 감지된 context window는 Claude Code auto-compaction에 반영됩니다.
- **Settings → General → Routing**에서 provider별 round-robin 명령어를 만들 수 있습니다. 최소 2개 계정을 선택하면 새 CLI session마다 다음 계정으로 순환하고, 선택된 계정은 해당 session 동안 고정됩니다.

````

- [ ] **Step 4: Usage HUD 섹션을 mixed usage 기준으로 교체**

`## 사용량 HUD`부터 `## 터미널과 SSH에서 사용하기` 직전까지를 다음 내용으로 교체한다.

```markdown
## 사용량 HUD

**Settings → Usage**에서 메뉴바 사용량과 별도 Usage HUD 표시를 각각 설정할 수 있습니다.

- 창의 투명도와 항상 위 표시 여부를 설정하고, 메뉴바에서 HUD를 다시 표시하거나 숨길 수 있습니다.
- 메인 화면의 각 계정 카드에서 Usage HUD 버튼을 눌러 HUD에 표시할 계정을 선택할 수 있습니다. 선택은 expanded·compact 보기에 함께 적용되고 앱 재실행 후에도 유지됩니다.
- OAuth 계정은 API가 보고한 `5h`, `7d`, `1mo` 기간의 사용률과 reset 시각을 표시합니다.
- Claude·OpenAI API Key는 로컬 CLIProxyAPI usage record를 집계해 Day/Mon token, request, 예상 비용을 표시합니다. 비용은 수집된 usage와 앱의 price catalog를 바탕으로 한 추정치이며 provider 청구서가 아닙니다.
- HUD 우측 상단의 축소·확장 버튼으로 300pt 폭의 expanded 보기와 108pt 폭의 compact 보기를 전환할 수 있습니다.
- compact 보기는 account avatar·이름과 기간별 사용률 또는 Day/Mon 예상 비용을 세로로 표시합니다. loading·unavailable·disabled·stale 상태에서는 `—`와 상태 indicator를 표시합니다.
- 선택한 HUD mode와 account 목록은 앱 재실행 후에도 유지됩니다.

```

- [ ] **Step 5: Terminal/SSH와 업데이트 섹션을 실제 `cpm` usage에 맞게 교체**

`## 터미널과 SSH에서 사용하기`부터 `## 문제 해결` 직전까지를 다음 내용으로 교체한다.

````markdown
## 터미널과 SSH에서 사용하기

**cpm Command Line Tool**은 터미널과 SSH에서 CLIProxyManager를 제어하는 `cpm` 명령어입니다. 앱의 **Settings → General → Command Line**에서 **Install cpm Command Line Tool**을 선택해 설치할 수 있습니다. 앱에 더 최신 버전이 포함된 경우에만 Update 버튼이 나타납니다.

```zsh
# 상태와 proxy 제어
cpm status [--json]
cpm start
cpm stop
cpm restart
cpm logs --lines 100
cpm logs -f

# 앱 제어
cpm app status
cpm app start
cpm app stop
cpm app restart

# OAuth 구독 사용량과 quota access key
cpm quota
cpm quota --json
cpm quota key status --json
printf '%s\n' "$MANAGEMENT_KEY" | cpm quota key set --stdin
cpm quota key delete

# 앱·CLIProxyAPI 업데이트
cpm update check [app | proxy | all]
cpm update stage [app | proxy | all]
cpm update apply [app | proxy | all] [--yes]
```

## 업데이트

CLIProxyManager는 실행 중 새 앱 버전을 확인하고 Sparkle 안내를 통해 업데이트합니다.

앱 업데이트와 CLIProxyAPI 바이너리 업데이트는 서로 독립적입니다. 앱 시작 시 bundled CLIProxyAPI가 설치본보다 새 버전인지 확인하며, 실행 중인 server에 영향을 주는 적용은 사용자 동의를 받은 뒤 진행합니다.

터미널에서는 대상을 `app`, `proxy`, `all` 중에서 선택할 수 있습니다.

```zsh
cpm update check all
cpm update stage all
cpm update apply all --yes
```

````

기존 `## 문제 해결`, `## 보안`, `## 라이선스`는 그대로 유지한다.

- [ ] **Step 6: 한국어 README 계약 통과 확인**

Run:

```bash
rg -q 'readme-main-window\.png.*width="260"' README.md
rg -q 'readme-usage-hud\.png.*width="260"' README.md
rg -q 'readme-usage-hud-compact\.png.*width="100"' README.md
rg -q '^## 계정과 라우팅$' README.md
rg -q 'Day/Mon token, request, 예상 비용' README.md
rg -q 'cpm quota key set --stdin' README.md
rg -q 'cpm update apply all --yes' README.md
rg -q -- '- macOS 15 이상' README.md
```

Expected: 모든 assertion이 exit status 0으로 통과한다.

- [ ] **Step 7: 한국어 README commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add README.md
git commit -m "docs: refresh Korean README for v0.1.27" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: 영어 README를 한국어 기능 범위와 일치시켜 최신화

**Files:**
- Modify: `README.en.md:5-135`
- Consume: Task 1의 PNG assets와 Task 2의 section/function contract

**Interfaces:**
- Consumes: 한국어 README의 이미지·섹션·명령 범위
- Produces: 동일한 정보를 자연스러운 영어로 설명하는 `README.en.md`

- [ ] **Step 1: 영어 README parity 계약이 현재 문서에서 실패하는지 확인**

Run:

```bash
rg -q 'readme-usage-hud-compact\.png' README.en.md
rg -q '^## Accounts and routing$' README.en.md
rg -q 'Day/Mon' README.en.md
rg -q 'cpm quota key set --stdin' README.en.md
rg -q 'cpm update apply all --yes' README.en.md
```

Expected: FAIL for the same missing v0.1.27 documentation surfaces as the Korean README.

- [ ] **Step 2: Replace the image row, introduction, and Highlights**

Replace the existing `<table>` through the line before `## Requirements` with:

```markdown
<table>
  <tr>
    <td><img src="docs/assets/readme-main-window.png" alt="CLIProxyManager multi-account dashboard" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud.png" alt="Expanded Usage HUD combining OAuth subscription usage and API key estimated cost" width="260"></td>
    <td><img src="docs/assets/readme-usage-hud-compact.png" alt="Compact Usage HUD showing per-account usage and estimated API cost" width="100"></td>
  </tr>
</table>

CLIProxyManager is a macOS menu bar app for managing multiple Claude and Codex OAuth subscriptions, Claude and OpenAI API keys, and a local CLIProxyAPI server. Give each account its own command, configure model routing and round-robin selection, and monitor subscription usage and estimated API cost in one Usage HUD.

## Highlights

- Add and manage Claude/Codex OAuth accounts and Claude/OpenAI API keys in one place.
- Configure each account's command, nickname, enabled state, order, detail privacy, and Usage HUD visibility.
- Choose Direct or CLIProxyAPI connections for Claude OAuth and configure per-account Claude model mappings.
- Configure GPT model, reasoning, detected context window, and Fast mode per Opus, Sonnet, and Haiku role for Codex OAuth and OpenAI API keys.
- Create round-robin commands that rotate selected OAuth accounts between new CLI sessions while keeping one account fixed inside each session.
- Start, stop, inspect, and view logs for the local CLIProxyAPI server.
- Monitor OAuth subscription usage and API key tokens, requests, and estimated cost in the menu bar, expanded HUD, or compact HUD.
- Use the **cpm Command Line Tool** to manage the proxy, app, quota, and updates from Terminal or SSH.

```

- [ ] **Step 3: Replace Requirements, Quick start, and add Accounts and routing**

Replace `## Requirements` through the line before `## Usage HUD` with:

````markdown
## Requirements

- macOS 15 or later.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed.
- A Claude/Codex OAuth account or a Claude/OpenAI API key.
- zsh if you want to use the generated terminal commands.

## Installation and macOS security warning

The release app is self-signed but is **not Apple-notarized**, so macOS may show a security warning the first time you launch it.

1. Download the latest DMG from [Releases](https://github.com/woosublee/CLIProxyManager/releases/latest) and install the app.
2. If macOS blocks the app, Control-click it in Finder and select **Open**, or go to **System Settings → Privacy & Security → Open Anyway**.

Only use release builds downloaded directly from GitHub Releases.

## Quick start

1. In the app, select **Add Provider** and add a Claude/Codex OAuth subscription or a Claude/OpenAI API key.
2. In each account's Settings, choose a nickname and command, such as `claude-work` or `codex-personal`.
3. Open a new Terminal window, or run:

   ```zsh
   source ~/.zshrc
   ```

4. Run the command you configured:

   ```zsh
   claude-work
   codex-personal
   ```

## Accounts and routing

- Reorder accounts from the main window with the drag handle or move commands. The same order is used in the menu bar and Usage HUD.
- Disable and re-enable OAuth accounts, blur account details, or exclude individual accounts from the Usage HUD.
- Claude OAuth can use a **Direct** or **CLIProxyAPI** connection. Direct follows Claude Code's current model policy, while CLIProxyAPI uses per-account model mappings.
- Codex OAuth and OpenAI API keys can select a GPT model and reasoning effort for each Opus, Sonnet, and Haiku role. Supported models can enable Fast mode, and the detected context window is applied to Claude Code auto-compaction.
- Create provider-specific round-robin commands under **Settings → General → Routing**. Select at least two accounts to rotate the account used for each new CLI session; the chosen account stays fixed for that session.

````

- [ ] **Step 4: Replace Usage HUD with mixed subscription/API usage documentation**

Replace `## Usage HUD` through the line before `## Terminal and SSH` with:

```markdown
## Usage HUD

Use **Settings → Usage** to configure menu bar usage and the separate Usage HUD independently.

- Adjust window opacity and always-on-top behavior, and show or hide the HUD from the menu bar.
- Use the Usage HUD button on each account card to choose which accounts appear. The selection is shared by expanded and compact views and restored after relaunch.
- OAuth accounts show usage percentages and reset times for the `5h`, `7d`, or `1mo` periods reported by the provider API.
- Claude and OpenAI API keys aggregate local CLIProxyAPI usage records into Day/Mon token counts, request counts, and estimated cost. The cost is an estimate based on collected usage and the app's price catalog, not a provider invoice.
- Use the compact/expand control in the HUD header to switch between the 300pt-wide expanded view and the 108pt-wide compact view.
- Compact view shows each account's avatar, name, and period percentages or Day/Mon estimated cost in a vertical layout. Loading, unavailable, disabled, and stale states show `—` with a status indicator.
- The selected HUD mode and account list are restored after relaunch.

```

- [ ] **Step 5: Replace Terminal/SSH and Updates with actual `cpm` usage**

Replace `## Terminal and SSH` through the line before `## Troubleshooting` with:

````markdown
## Terminal and SSH

The **cpm Command Line Tool** controls CLIProxyManager from Terminal and SSH. Install it from **Settings → General → Command Line** with **Install cpm Command Line Tool**. The Update button appears only when the app includes a newer version.

```zsh
# Status and proxy control
cpm status [--json]
cpm start
cpm stop
cpm restart
cpm logs --lines 100
cpm logs -f

# App control
cpm app status
cpm app start
cpm app stop
cpm app restart

# OAuth subscription usage and the quota access key
cpm quota
cpm quota --json
cpm quota key status --json
printf '%s\n' "$MANAGEMENT_KEY" | cpm quota key set --stdin
cpm quota key delete

# App and CLIProxyAPI updates
cpm update check [app | proxy | all]
cpm update stage [app | proxy | all]
cpm update apply [app | proxy | all] [--yes]
```

## Updates

CLIProxyManager checks for new app versions while it is running and installs them through the Sparkle update prompt.

App updates and CLIProxyAPI binary updates are independent. At startup, the app compares the bundled CLIProxyAPI with the installed version and requests consent before applying an update that affects a running server.

From Terminal, choose `app`, `proxy`, or `all` as the update target.

```zsh
cpm update check all
cpm update stage all
cpm update apply all --yes
```

````

Keep the existing `## Troubleshooting`, `## Security`, and `## License` sections unchanged.

- [ ] **Step 6: Verify English README parity contract**

Run:

```bash
rg -q 'readme-main-window\.png.*width="260"' README.en.md
rg -q 'readme-usage-hud\.png.*width="260"' README.en.md
rg -q 'readme-usage-hud-compact\.png.*width="100"' README.en.md
rg -q '^## Accounts and routing$' README.en.md
rg -q 'Day/Mon token counts, request counts, and estimated cost' README.en.md
rg -q 'cpm quota key set --stdin' README.en.md
rg -q 'cpm update apply all --yes' README.en.md
rg -q -- '- macOS 15 or later\.' README.en.md
```

Expected: all assertions exit with status 0.

- [ ] **Step 7: English README commit**

사용자가 단계별 구현 commit을 승인한 경우에만 실행한다.

```bash
git add README.en.md
git commit -m "docs: refresh English README for v0.1.27" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 국·영문 parity와 Markdown·asset 최종 검증

**Files:**
- Verify: `README.md`
- Verify: `README.en.md`
- Verify: `docs/assets/readme-main-window.png`
- Verify: `docs/assets/readme-usage-hud.png`
- Verify: `docs/assets/readme-usage-hud-compact.png`
- Reference: `Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift:14-27`

**Interfaces:**
- Consumes: Tasks 1-3의 최종 assets와 문서
- Produces: image integrity, section parity, command parity, clean Markdown source의 검증 근거

- [ ] **Step 1: 이미지 순서와 경로 parity 확인**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import re

expected = [
    "docs/assets/readme-main-window.png",
    "docs/assets/readme-usage-hud.png",
    "docs/assets/readme-usage-hud-compact.png",
]
for path in (Path("README.md"), Path("README.en.md")):
    text = path.read_text()
    actual = re.findall(r'<img src="([^"]+)"', text)
    assert actual == expected, (path, actual)
print("README image order matches")
PY
```

Expected: `README image order matches`.

- [ ] **Step 2: 국·영문 section order parity 확인**

Run:

```bash
python3 - <<'PY'
from pathlib import Path

ko = [line for line in Path("README.md").read_text().splitlines() if line.startswith("## ")]
en = [line for line in Path("README.en.md").read_text().splitlines() if line.startswith("## ")]
assert len(ko) == len(en) == 11, (ko, en)
assert ko[4] == "## 계정과 라우팅"
assert en[4] == "## Accounts and routing"
assert ko[-3:] == ["## 문제 해결", "## 보안", "## 라이선스"]
assert en[-3:] == ["## Troubleshooting", "## Security", "## License"]
print("README section order matches")
PY
```

Expected: `README section order matches`.

- [ ] **Step 3: documented `cpm` command families를 실제 CLI usage와 대조**

Run:

```bash
python3 - <<'PY'
from pathlib import Path

usage = Path("Sources/CLIProxyManagerCore/CLI/CLIProxyManagerCommand.swift").read_text()
readmes = Path("README.md").read_text() + Path("README.en.md").read_text()
required = [
    "cpm status [--json]",
    "cpm start | stop | restart",
    "cpm logs [--lines <N>] [-f]",
    "cpm app status | start | stop | restart",
    "cpm update check [app | proxy | all]",
    "cpm update stage [app | proxy | all]",
    "cpm update apply [app | proxy | all] [--yes]",
    "cpm quota [--json]",
    "cpm quota key status [--json] | set --stdin | delete",
]
for command in required:
    assert command in usage, command
for documented in (
    "cpm status [--json]",
    "cpm app restart",
    "cpm update check [app | proxy | all]",
    "cpm update stage [app | proxy | all]",
    "cpm update apply [app | proxy | all] [--yes]",
    "cpm quota key status --json",
    "cpm quota key set --stdin",
    "cpm quota key delete",
):
    assert readmes.count(documented) == 2, (documented, readmes.count(documented))
print("README cpm commands match CLI usage")
PY
```

Expected: `README cpm commands match CLI usage`.

- [ ] **Step 4: Markdown fence, relative link, image integrity, whitespace 확인**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import re

for name in ("README.md", "README.en.md"):
    text = Path(name).read_text()
    assert text.count("```") == text.count("```zsh") * 2
    for target in re.findall(r'\]\(([^)]+)\)', text):
        if "://" not in target and not target.startswith("#"):
            assert Path(target).exists(), (name, target)
print("README fences and relative links are valid")
PY

test "$(shasum -a 256 docs/assets/readme-main-window.png | cut -d' ' -f1)" = \
  "05c18d7d0028e8a331320416455eee5f79a54d857b1c7cbf1b5691fda22ad290"
test "$(shasum -a 256 docs/assets/readme-usage-hud.png | cut -d' ' -f1)" = \
  "949fd2701cf6169d254628e5942b8445ce521ed39092baa056d9842bd290ef06"
test "$(shasum -a 256 docs/assets/readme-usage-hud-compact.png | cut -d' ' -f1)" = \
  "6eaf4cdeaa3b35e48d663b5dda4cad17f21f26764b5419702ba11249511abc94"
git diff --check
```

Expected: fence/link message 출력, image hash assertions와 `git diff --check`가 status 0으로 통과한다.

- [ ] **Step 5: 최종 diff와 repository 상태 확인**

Run:

```bash
git diff --stat main...HEAD
git diff --name-status main...HEAD
git status --short --branch
```

Expected:

- 변경 파일은 design/plan 문서, `README.md`, `README.en.md`, expanded HUD PNG, compact HUD PNG뿐이다.
- 앱 source와 test source는 변경되지 않는다.
- 단계별 commit을 생성했다면 worktree는 clean이다.

- [ ] **Step 6: 사용자 검토 항목 전달**

사용자에게 GitHub README render에서 다음을 확인하도록 전달한다.

1. 상단 이미지가 dashboard → expanded HUD → compact HUD 순서인지
2. compact HUD가 원본 비율을 유지하면서 식별 가능한 크기인지
3. 국·영문 섹션과 command examples가 같은 범위인지
4. README가 주요 기능을 충분히 설명하면서 지나치게 장황하지 않은지

# CLIProxyAPI 업데이트 UI About 이동 설계

## 요약

CLIProxyAPI 바이너리 업데이트 조작 UI를 `Settings > Server`에서 제거하고 `Settings > About > Updates`로 이동한다. 사용자는 앱 업데이트와 CLIProxyAPI 바이너리 업데이트를 같은 업데이트 맥락에서 확인한다. 모든 업데이트 확인·다운로드·적용 문구는 현재 설치된 CLIProxyAPI 버전과 업데이트 대상 버전을 함께 보여준다.

이 설계는 `docs/superpowers/specs/2026-07-01-cliproxyapi-binary-self-update-design.md`의 UI 위치를 개정한다. 업데이트 저장소, checksum 검증, pending/active 적용 정책은 기존 설계를 유지한다.

## 목표

- `Settings > Server`에서 CLIProxyAPI 바이너리 업데이트 row와 적용 dialog를 완전히 제거한다.
- `Settings > About > Updates`에서 CLIProxyManager 앱 업데이트와 CLIProxyAPI 바이너리 업데이트를 함께 보여준다.
- 새 CLIProxyAPI 버전이 있을 때 현재 버전과 업데이트 대상 버전을 한 화면에서 비교해 보여준다.
- pending 업데이트가 있을 때 현재 active 버전과 pending 버전을 함께 보여준다.
- 자동 확인으로 뜨는 Dashboard confirmation dialog도 현재 버전과 대상 버전을 명확히 표시한다.
- 적용 버튼은 대상 버전을 포함하고, 서버가 실행 중이면 restart가 동반된다는 점을 버튼 문구에 포함한다.

## 비목표

- CLIProxyAPI 업데이트의 다운로드, checksum 검증, pending 저장, active 승격 정책을 바꾸지 않는다.
- Sparkle 기반 CLIProxyManager 앱 업데이트 동작을 바꾸지 않는다.
- `Settings > Server`에 CLIProxyAPI 업데이트 읽기 전용 요약을 남기지 않는다.
- CLIProxyAPI 업데이트를 사용자 승인 없이 자동 적용하지 않는다.
- 포트, bind address, autostart 같은 서버 런타임 설정 UI를 재설계하지 않는다.

## 현재 프로젝트 맥락

현재 `SettingsView`는 `SettingsTab`별로 다음 view를 렌더링한다.

- `GeneralSettingsView`
- `ServerSettingsView`
- `AdvancedSettingsView`
- `AboutSettingsView`

`ServerSettingsView`는 `cliProxyAPIUpdateService`를 받아 `CLIProxyAPI binary` row와 apply confirmation dialog를 포함한다. `AboutSettingsView`는 `updaterService`만 받아 기존 `Updates` 그룹에서 Sparkle 앱 업데이트 설정과 `Check now` 버튼을 보여준다.

`DashboardView`는 앱 실행 후 `cliProxyAPIUpdateService.checkAutomaticallyOnLaunch()`를 호출하고, `availableUpdate`와 `pendingUpdate` 변화에 따라 confirmation dialog를 표시한다. 현재 dialog 문구는 업데이트 대상 버전만 중심으로 보여주며, 현재 버전과 대상 버전을 비교하는 문구가 부족하다.

## 사용자 경험

### About > Updates

`AboutSettingsView`의 기존 `Updates` 그룹 안에 CLIProxyAPI 바이너리 업데이트 row를 추가한다. 앱 업데이트와 구분되도록 label을 명확히 한다.

예시 구조:

```text
Updates

Check for updates
Automatically check for new versions on launch.
[Toggle]

Check now
Check GitHub releases for a newer CLIProxyManager version.
[Check now]

CLIProxyAPI binary
Current version: 7.2.41 · Available version: 7.2.50
[Download 7.2.50]
```

pending 상태 예시:

```text
CLIProxyAPI binary
Current version: 7.2.41 · Pending version: 7.2.50
[Apply 7.2.50 now]
```

서버가 실행 중이면 버튼은 다음처럼 표시한다.

```text
Apply 7.2.50 and restart server
```

### Server 탭

`ServerSettingsView`는 서버 런타임 설정만 담당한다.

- Listen port
- Bind address
- Start server on launch
- Round-robin balancing row는 현재처럼 disabled 상태로 유지

CLIProxyAPI 업데이트 조작 row, 진행 indicator, apply confirmation dialog는 Server 탭에서 완전히 제거한다. Server 탭에 About 이동 안내 문구도 남기지 않는다.

### Dashboard 자동 업데이트 prompt

자동 확인에서 새 버전이 발견되면 사용자가 현재/대상 버전을 즉시 비교할 수 있어야 한다.

예시:

```text
Update CLIProxyAPI from 7.2.41 to 7.2.50?
```

버튼:

```text
Download 7.2.50
Later
```

pending 적용 prompt 예시:

```text
Apply CLIProxyAPI 7.2.50?
Current version: 7.2.41
```

버튼:

```text
Apply 7.2.50 now
Apply on next server start
Cancel
```

서버가 실행 중이면 즉시 적용 버튼은 다음 문구를 사용한다.

```text
Apply 7.2.50 and restart server
```

## 컴포넌트 설계

### `SettingsView`

`ServerSettingsView`에서 `cliProxyAPIUpdateService` 의존성을 제거한다.

```swift
case .server:
    ServerSettingsView(viewModel: viewModel)
```

`AboutSettingsView`는 CLIProxyAPI 업데이트 동작과 서버 재시작 여부 판단을 위해 `viewModel`과 `cliProxyAPIUpdateService`를 함께 받는다.

```swift
case .about:
    AboutSettingsView(
        viewModel: viewModel,
        updaterService: updaterService,
        cliProxyAPIUpdateService: cliProxyAPIUpdateService
    )
```

### `ServerSettingsView`

다음 항목을 제거한다.

- `@ObservedObject var cliProxyAPIUpdateService`
- `@State private var showApplyPrompt`
- `CLIProxyAPI binary` `SettingsRow`
- `.confirmationDialog("Apply CLIProxyAPI update now?", ...)`

### `AboutSettingsView`

다음 항목을 추가한다.

- `@ObservedObject var viewModel: DashboardViewModel`
- `@ObservedObject var cliProxyAPIUpdateService: CLIProxyAPIUpdateService`
- CLIProxyAPI binary update row
- pending apply confirmation dialog

row의 action은 기존 Server 탭 동작을 유지한다.

- pending이 있으면 apply dialog를 연다.
- available update가 있으면 다운로드 후 pending이 생겼을 때 apply dialog를 연다.
- available/pending이 없으면 `checkNow()`를 호출한다.

### Copy helper

현재 전역 helper인 `cliproxyAPIUpdateDescription`과 `cliproxyAPIUpdateActionTitle`을 version-aware하게 확장한다. UI에서 같은 문구를 반복 조합하지 않도록 다음 책임을 helper에 둔다.

- 상태별 description 생성
- 상태별 버튼 title 생성
- Dashboard available prompt title 생성
- Dashboard pending prompt title 생성
- apply button title 생성

예시 interface:

```swift
func cliproxyAPIUpdateDescription(
    currentVersion: String,
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String

func cliproxyAPIUpdateActionTitle(
    state: CLIProxyAPIUpdateServiceState,
    availableUpdate: CLIProxyAPIRelease?,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String

func cliProxyAPIAvailableUpdatePromptTitle(
    currentVersion: String,
    availableUpdate: CLIProxyAPIRelease?
) -> String

func cliProxyAPIPendingUpdatePromptTitle(
    currentVersion: String,
    pendingUpdate: CLIProxyAPIBinaryManifest?
) -> String

func cliProxyAPIApplyButtonTitle(
    pendingUpdate: CLIProxyAPIBinaryManifest?,
    isServerRunning: Bool
) -> String
```

## 데이터 흐름

1. 앱 실행 시 `CLIProxyAPIUpdateService`가 현재 active version을 `currentVersionText`에 반영한다.
2. 자동 확인 또는 수동 확인에서 새 릴리스가 있으면 `availableUpdate`가 설정된다.
3. Dashboard와 About row는 `currentVersionText`와 `availableUpdate.version`을 함께 표시한다.
4. 사용자가 다운로드를 선택하면 기존처럼 다운로드와 검증 후 pending manifest를 저장한다.
5. pending이 생기면 Dashboard와 About row는 `currentVersionText`와 `pendingUpdate.version`을 함께 표시한다.
6. 사용자가 즉시 적용을 선택하면 기존처럼 `applyPendingNow()`를 호출하고, 서버가 실행 중이면 `DashboardViewModel.restartServer()`를 호출한다.

## 오류 처리

- 확인 중에는 `Current version: <current> · Checking for updates…`를 표시한다.
- 다운로드 중에는 `Current version: <current> · Downloading and verifying update…`를 표시한다.
- 실패 상태에서는 `Current version: <current> · Last check failed.`를 표시한다.
- 수동 확인/다운로드/적용 실패는 기존처럼 `settingsMessage`에 실패 사유를 표시한다.
- 현재 버전을 알 수 없으면 `Unknown`을 그대로 표시하되 대상 버전은 가능한 경우 계속 표시한다.

## 테스트 전략

### Copy helper 테스트

- available 상태 description에 current version과 available version이 모두 포함된다.
- pending 상태 description에 current version과 pending version이 모두 포함된다.
- available 상태 action title이 `Download <version>`을 반환한다.
- pending 상태 action title이 `Apply <version> now`를 반환한다.
- 서버 실행 중 apply button title이 `Apply <version> and restart server`를 반환한다.
- Dashboard available prompt title이 `Update CLIProxyAPI from <current> to <target>?` 형식이다.
- Dashboard pending prompt title이 current version과 pending version을 포함한다.

### View 구조 테스트

프로젝트의 기존 테스트 수준에 맞춰 가능한 범위에서 다음을 확인한다.

- `SettingsView`의 About branch가 `cliProxyAPIUpdateService`를 전달하는 구조로 컴파일된다.
- `ServerSettingsView`가 `cliProxyAPIUpdateService` 없이 생성된다.
- 기존 Server 설정 테스트가 업데이트 UI 의존성 없이 통과한다.

### 수동 런타임 확인

- 개발 빌드에서 `Settings > Server`에 CLIProxyAPI binary row가 보이지 않는다.
- `Settings > About > Updates`에 CLIProxyAPI binary row가 보인다.
- update available 상태에서 현재 버전과 available 버전이 함께 보인다.
- pending 상태에서 현재 버전과 pending 버전이 함께 보인다.
- 서버 실행 중 즉시 적용 버튼은 restart 포함 문구를 보여준다.

## 수용 기준

- CLIProxyAPI 바이너리 업데이트 조작 UI는 Server 탭에 남아 있지 않다.
- About 탭의 Updates 그룹에서 CLIProxyAPI 바이너리 업데이트를 확인, 다운로드, 적용할 수 있다.
- 새 업데이트가 있을 때 사용자는 현재 버전과 업데이트 대상 버전을 함께 볼 수 있다.
- pending 업데이트가 있을 때 사용자는 현재 버전과 pending 버전을 함께 볼 수 있다.
- Dashboard 자동 prompt도 현재 버전과 대상 버전을 비교해 보여준다.
- 버튼 문구는 가능한 경우 대상 버전을 포함한다.
- 서버 실행 중 즉시 적용 버튼은 restart가 동반됨을 표시한다.
- 기존 CLIProxyAPI 다운로드, 검증, pending, 적용 동작은 바뀌지 않는다.
- 기존 Sparkle 앱 업데이트 UI와 동작은 유지된다.

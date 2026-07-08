# 다중 OAuth 계정 지원 — 진행 상황 스냅샷

작성일: 2026-07-08

`/Users/woosublee/.claude/plans/fluttering-chasing-ritchie.md`의 승인된 계획을 실행 중이며, 이 문서는 세션이 끝난 시점의 상태와 다음 세션에서 이어받는 방법을 정리합니다.

## 현재 상태

- Swift 컴파일: 성공
- `swift test`: 292개 중 26개 실패 (앱 타깃 테스트만 실패, Core 테스트는 통과)
- 앱 실제 실행 검증: 아직 수행하지 않음
- 커밋: 아직 하지 않음 (working tree에 변경만 존재)

## 완료된 작업

### 1. CLIProxyAPI 라우팅 지원 확인

- bundled `cliproxyapi` 7.2.41 검증. 소스는 `/tmp/cliproxyapi-src`에 clone되어 있음
- OAuth auth JSON의 최상위 `prefix` 필드를 지원하고, `applyModelPrefixes` + `rewriteModelForAuth`로 `<prefix>/<model>` 요청을 해당 auth로 route함
- 전략: **command마다 고유 `modelPrefix`를 auth JSON에 기록하고, 셸 함수가 `ANTHROPIC_DEFAULT_*_MODEL`에 `prefix/model` 형태를 주입** → CLIProxyAPI가 요청 모델 이름의 prefix를 보고 계정을 선택
- 참고: `sk-dummy` local API key는 계속 하나만 사용. account selection은 model prefix로만 이뤄짐

### 2. Core 데이터 모델

수정 파일:

- `Sources/CLIProxyManagerCore/Config/AppConfig.swift`
  - `OAuthCommandProfile` 구조체 추가 (`id`, `provider`, `authProfileID`, `commandName`, `nickname`, `accountDetailHidden`, `dangerousPermissionsEnabled`, `codex`, `modelPrefix`, `isEnabled`)
  - `AppConfig.oauthCommandProfiles: [OAuthCommandProfile]` 필드와 CodingKeys, decoder 기본값(빈 배열) 추가
  - 기존 `commands`, `nicknames`, `accountPrivacy`, `ccodex`, `includeDangerouslySkipPermissions`는 legacy로 유지
- `Sources/CLIProxyManagerCore/Auth/AuthProfile.swift`
  - `AuthProfile.prefix: String?` 추가
- `Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift`
  - `profile(id:)`, `delete(id:)`, `setDisabled(_:id:)`, `setPrefix(_:id:)` 추가
  - JSON `prefix` 필드 파싱/저장 (`sanitizedPrefix` 헬퍼로 슬래시 금지 검증)
  - `authFileURL(id:)`가 directory enumeration 결과에서만 매칭하므로 path traversal 방지
  - 기존 `delete(for:)`, `setDisabled(_:for:)`는 legacy path로 유지
- `Sources/CLIProxyManagerCore/Proxy/ProxyModelClient.swift`
  - `codexBaseModels(port:modelPrefix:)` overload 추가 (prefix 있는 경우 필터링 후 prefix 제거)

### 3. ShellFunctionRenderer

수정 파일: `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`

- `oauthCommandProfiles`가 비어 있으면 legacy 렌더링 경로를 그대로 사용
- 비어 있지 않으면 각 command profile마다 함수 렌더링:
  - `ANTHROPIC_DEFAULT_*_MODEL`에 `modelPrefix`가 있으면 `prefix/model` 형식 주입
  - Claude profile은 Claude 기본 모델, Codex profile은 profile의 `codex` 또는 fallback으로 `config.ccodex`
  - `dangerousPermissionsEnabled`가 command profile별로 반영
- `functionNamesToRender`, `oauthCommandProfilesToRender` 분리

### 4. AutomaticShellInstallService

수정 파일: `Sources/CLIProxyManagerApp/Services/AutomaticShellInstallService.swift`

- `shouldIncludeOAuth(provider:config:enabled:)`가 command profile이 있으면 provider별 enabled profile 유무, 없으면 legacy `commands.cc/ccodex` 유무로 판정
- `oauthFunctionNames`가 command profile 목록에서 command name을 수집

### 5. UI 상태 모델

수정 파일:

- `Sources/CLIProxyManagerApp/Models/ProviderRowState.swift`
  - `ProviderRowID`를 struct(`RawRepresentable`, `Hashable`, `ExpressibleByStringLiteral`)로 도입
  - `.claude`, `.codex` static let 유지 → 기존 참조 코드 다수가 그대로 동작
  - `ProviderRowState`에 `providerType`, `authProfileID`, `commandProfileID` 필드 추가
- `Sources/CLIProxyManagerApp/Models/ProviderRowID+Identifiable.swift`
  - `extension ProviderRowState.ID: Identifiable`을 별도 파일로 분리 (`SwiftUI.sheet(item:)` 사용용)
- `Sources/CLIProxyManagerApp/Models/DashboardAccountSnapshot.swift`
  - `providerType: AuthProfileType` 필드 추가

### 6. UI View

수정 파일:

- `Sources/CLIProxyManagerApp/Views/DesignChromeViews.swift`
  - `ProviderAvatar`가 optional `providerType`을 받아 provider 시각화
- `Sources/CLIProxyManagerApp/Views/AddProviderModal.swift`
  - `onPick`이 `AuthProfileType`을 넘기도록 시그니처 변경
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
  - `providerSettingsSheet`가 row의 `providerType`으로 sheet 분기, sheet 각각에 `providerID`와 command profile ID를 전달
- `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
  - `AccountSheetChrome`가 optional `providerType`을 받아 아바타 표시
  - `ClaudeOAuthProviderSettingsSheet`, `CodexProviderSettingsSheet`에 `providerID` 파라미터 추가
  - `oauthSettingsInitialState`, `oauthSettingsInitialCodex`, `oauthSettingsRecommendedFunctionName` 모두 command profile 기반으로 확장 (legacy fallback 포함)
- `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
  - 동일한 dynamic providerType 분기 적용
  - `.sheet(item:)` 대신 `isPresented` binding으로 전환

### 7. DashboardViewModel

수정 파일: `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`

- `AuthProfileManaging` 프로토콜에 새 API 시그니처 추가 + default extension (`setDisabled(_:id:)`, `setPrefix(_:id:)`, `delete(id:)`)
- `ProxyModelListing`에 `codexBaseModels(port:modelPrefix:)` default extension 추가
- 초기화 시 auth profile을 읽어 `reconciledOAuthCommandProfiles(in:authProfiles:)`로 legacy config를 command profile 배열로 마이그레이션
- `mirroredLegacyFields(in:)`이 첫 Claude/Codex command profile 값을 legacy 필드에 mirror
- `commandProfileID(provider:authProfileID:preferLegacyID:usedIDs:)`, `modelPrefix`, `slug` 헬퍼 추가
- `reconcileAuthProfilePrefixes()`가 command profile의 `modelPrefix`를 auth JSON에 기록
- `startOAuthLogin(providerType:)` overload와 `reconcileOAuthLoginCompletion(providerType:beforeProfiles:)` 추가로 로그인 후 새 auth profile 식별
- `removeProvider`, `removeInitialProvider`, `disconnectProvider`가 command profile → auth profile ID를 통해 파일 단위 delete/disable 호출
- `toggleAccountDetailVisibility`가 command profile을 우선 토글하고 없으면 legacy `accountPrivacy` 조작
- `saveClaudeOAuthSettings(provider:...)`, `saveCodexSettings(provider:...)` overload로 command profile 단위 저장
- `resetProviderSettings`가 command profile을 배열에서 제거 (legacy path fallback 포함)
- `enabledShellFunctions(in:)`, `activeFunctionNames(in:)`, `renderableOAuthCommandProfiles(in:)`로 command profile 기반 도우미
- `rebuildProviderRows`가 command profile 목록에서 row 생성 → 같은 provider 여러 계정 지원

## 남은 작업

### A. 실패 중인 테스트 26개 수정 (in_progress)

주요 실패 패턴과 원인:

1. **stub 캡처 안 됨** — `StubAuthProfileStore`가 새 API (`delete(id:)`, `setDisabled(_:id:)`, `setPrefix(_:id:)`)를 별도로 오버라이드하지 않아 default extension만 실행됨 → `deleteInvocations`, `disabledUpdates`가 기록되지 않음. Stub에서 새 시그니처를 구현해 캡처 배열에 기록해야 함
2. **`addProvider` 메시지 변경** — 테스트가 `"Claude API profiles are hidden from the default account list in this version."`를 기대하지만 새 메시지로 바꿈. 원문 유지 필요 (혹은 테스트 갱신)
3. **`removeProvider`가 legacy `accountPrivacy`를 리셋하지 않음** — `testRemoveProviderResetsOnlyRemovedClaudeAccountPrivacy` 등: command profile을 제거하면 mirrored legacy 값에서도 accountPrivacy가 default(hidden=true)로 mirror되어야 하는데 현재는 profile 삭제 후 legacy 값이 그대로 남음. `mirroredLegacyFields`에서 provider profile이 없으면 해당 privacy를 default(true)로 리셋하는 로직 필요
4. **`resetProviderSettings`가 command name/nickname을 클리어하지 못함** — legacy 테스트가 `commands.cc = ""`, `nicknames.cc = ""` 등을 기대. 새 흐름은 command profile을 통째로 제거 → mirror 시 legacy 값이 남을 수 있음. mirrored 필드에서 provider profile이 없으면 legacy commands/nicknames/ccodex를 default로 재설정 필요
5. **`toggleAccountDetailVisibility`가 shell 재설치를 트리거** — `saveConfig`를 부르므로 installer가 재실행됨. `saveAccountPrivacy`(shell install 미호출) 경로처럼 command profile 토글 전용 경로로 분리 필요
6. **`testSaveCodexSettingsKeepsCurrentConfigWhenPersistenceFails`** — 저장 실패 시 config가 이전 상태로 유지되어야 하는데 초기화 시 `reconciledOAuthCommandProfiles`가 config를 갱신해서 profile 배열이 채워짐. save 실패 시 rollback 필요, 또는 테스트가 초기 상태에 command profile을 명시하도록 조정
7. **`testConnectProviderStartsBundledOAuthLoginAndRefreshesProfiles`** — `disabledUpdates`, `deleteInvocations`가 empty. 위 (1)과 같은 원인
8. **`testDisconnectProviderDisablesAuthProfileAndRefreshesRows`** — 위 (1)과 같은 원인 + disconnect 결과가 "not found"로 뜸 → stub이 새 signature 구현 필요

수정할 파일:

- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift` — `StubAuthProfileStore`에 새 API 3개 구현 및 캡처
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift` — 동일
- `Tests/CLIProxyManagerAppTests/AutomaticShellInstallServiceTests.swift` — 동일
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - `addProvider` 메시지 원문 복구 (또는 테스트 조정)
  - `mirroredLegacyFields`에서 provider profile 부재 시 legacy privacy/commands/nicknames/ccodex/includeDangerouslySkipPermissions default로 리셋
  - `toggleAccountDetailVisibility`가 shell function 재설치를 유발하지 않는 경로 사용
  - save 실패 시 config rollback 확인
- `Sources/CLIProxyManagerCore/Auth/AuthProfileStore.swift`에서 `AuthProfileManaging` default extension 제거하고 `AuthProfileStore` 자체에 구현 (default extension은 protocol 확장이므로 stub이 자동 상속받아 캡처를 못 함)

### B. Core/App 단위 테스트 추가 (미착수)

계획 문서에 명시된 새 케이스:

- `AuthProfileStoreTests`: prefix 파싱, `setPrefix(_:id:)`, `setDisabled(_:id:)`, `delete(id:)`, 알 수 없는 필드/토큰 보존
- `AppConfigTests`, `AppConfigStoreTests`: `oauthCommandProfiles` decode/encode, 빈 배열 기본값
- `ShellFunctionRendererTests`: command profile 여러 개 → 여러 함수 렌더, model prefix 삽입, Codex profile별 mapping, legacy fallback 유지
- `DashboardViewModelTests`/`ProviderSettingsViewModelTests`: 같은 provider 계정 두 개, remove/disconnect가 특정 profile만, `commandNameAvailability`가 모든 command profile을 검증

### C. 개발 빌드 앱 검증 (미착수)

메모리 규칙(`memory/development-build-for-app-verification.md`)에 따라 개발 빌드로 다음을 확인:

- 기존 단일 계정 유지 시 command 동작
- Claude/Codex 각각 두 번째 계정 추가 → 다른 command 이름으로 저장
- `~/.cliproxy-manager/functions.zsh`에서 command마다 다른 `ANTHROPIC_DEFAULT_*_MODEL`(prefix 포함) 렌더
- auth JSON에 `prefix`가 기록되는지 확인
- 각 command 실행 시 CLIProxyAPI 로그에서 실제 사용된 auth가 다른지 확인

## 이어받는 방법

1. `swift test 2>&1 | grep -E "^Test Case.*failed"`로 실패 목록 재확인
2. 위 A 섹션 순서대로 수정 → `Tests` 파일의 Stub부터 갱신하는 편이 파급이 큼 (default extension을 `AuthProfileStore` 내부 구현으로 이동하면 컴파일러가 stub의 미구현을 다시 감지)
3. `swift test`가 통과하면 새 테스트(B) 추가
4. `open Package.swift`로 Xcode에서 개발 빌드 후 앱 검증(C)
5. 검증 통과 후 커밋

## 참고 파일

- 승인된 계획: `/Users/woosublee/.claude/plans/fluttering-chasing-ritchie.md`
- 이 문서: `docs/superpowers/plans/2026-07-08-multi-account-oauth-progress.md`
- CLIProxyAPI 소스 참고: `/tmp/cliproxyapi-src` (필요 시 재clone: `git clone --depth 1 https://github.com/router-for-me/CLIProxyAPI.git /tmp/cliproxyapi-src`)

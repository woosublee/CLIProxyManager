# 앱 업데이트 후 번들 CLIProxyAPI 자동 반영 설계

## 요약

CLIProxyManager 앱이 새 버전으로 교체된 뒤 처음 실행될 때, 앱에 포함된 CLIProxyAPI가 현재 활성 바이너리보다 최신이면 서버 autostart 설정과 관계없이 활성 경로에 자동 반영한다. 기존 서버가 실행 중이었다면 교체 직후 자동 재시작해 실행 중 프로세스도 새 바이너리로 전환한다.

앱 번들 업데이트와 사용자가 별도로 다운로드한 pending CLIProxyAPI 업데이트는 구분한다. 앱 번들은 앱 릴리스의 일부이므로 자동 적용하지만, pending 업데이트는 기존 사용자 선택인 `Apply now` 또는 `Apply on next server start`를 유지한다. 다운로드 직후나 confirmation dialog의 `Cancel`만으로는 다음 서버 시작에 적용하지 않으며, `Apply on next server start`를 명시적으로 선택한 경우에만 적용 예약을 기록한다.

## 배경과 원인

v0.1.22 릴리스 DMG와 설치된 앱에는 CLIProxyAPI 7.2.91 binary와 manifest가 정상적으로 포함됐다. 그러나 활성 바이너리를 번들 버전으로 수렴시키는 `CLIProxyAPIBinaryStore.prepareActiveBinary()`는 `ProxyServiceManager.prepare()`에서만 호출된다.

`ProxyServiceManager.prepare()`는 서버 `start` 또는 `restart` 경로에서 실행된다. 앱 시작 시 `DashboardViewModel.startApplication()`은 상태 갱신, subscription usage 준비, 조건부 autostart만 수행한다. 따라서 `autostartServer`가 꺼져 있거나 기존 서버가 이미 실행 중이면 새 앱이 실행돼도 번들 바이너리 조정이 실행되지 않는다.

CLIProxyAPI 설정 화면도 활성 manifest를 우선 표시하므로, 앱 안에 더 최신 번들이 있어도 서버를 재시작하기 전까지 기존 활성 버전이 보인다.

이 문제는 최근 릴리스 패키징 회귀가 아니라 기존 구현의 조건부 적용 공백이다. 이전에는 앱 업데이트 후 서버 start/restart가 함께 발생해 자동 반영된 것처럼 보일 수 있었다.

## 목표

- 새 앱 실행 시 서버 autostart 설정과 무관하게 번들 CLIProxyAPI를 활성 상태와 비교한다.
- 번들 버전이 더 최신이면 활성 바이너리를 자동 교체한다.
- 활성 바이너리가 없거나 손상됐으면 검증된 번들로 복구한다.
- 활성 바이너리가 번들보다 최신이면 유지해 다운그레이드를 방지한다.
- 교체 시 기존 서버가 실행 중이었다면 자동 재시작해 새 프로세스에 즉시 적용한다.
- 사용자가 다운로드만 한 pending 업데이트는 명시적 적용 전까지 보존한다.
- `Apply on next server start`를 선택했을 때만 durable 적용 예약 marker를 생성하고, `Cancel` 후 일반 서버 재시작에서는 pending을 적용하지 않는다.
- 앱 시작 조정 후 CLIProxyAPI 업데이트 UI의 현재 버전과 pending 상태를 다시 읽는다.
- 조정 실패가 앱 전체 시작을 막지 않도록 한다.

## 비목표

- Sparkle의 다운로드, 서명 검증, 앱 설치 방식은 변경하지 않는다.
- CLIProxyAPI GitHub 릴리스 확인 주기와 다운로드 UX는 변경하지 않는다.
- pending 업데이트를 사용자 선택 없이 자동 적용하지 않는다.
- 번들보다 최신인 user-updated 활성 바이너리를 번들 버전으로 되돌리지 않는다.
- 성공 시 확인 modal이나 별도 사용자 입력을 추가하지 않는다.
- Intel macOS 또는 다른 운영체제용 바이너리를 지원하지 않는다.

## 핵심 결정

### 앱 시작 전용 조정 경로

기존 `prepareActiveBinary()`를 앱 시작에서 직접 호출하지 않는다. 이 메서드는 `Apply on next server start`를 위해 유효하고 더 최신인 pending 바이너리를 active로 승격하는 책임도 가진다. 앱 시작에서 그대로 호출하면 사용자가 적용을 승인하지 않은 pending 업데이트가 자동 적용될 수 있다.

대신 앱 번들만 조정하는 별도 경로를 둔다. 앱 계층에는 `BundledProxyReconciliationService`를 추가하고, core의 `CLIProxyAPIBinaryStore`에는 pending을 승격하지 않는 번들 전용 조정 연산을 추가한다.

### 조정 결과 모델

번들 전용 조정 연산은 호출자가 서버 재시작 여부를 결정할 수 있도록 결과를 반환한다.

- `unchanged(version:)`: 유효한 활성 바이너리를 유지했다.
- `installed(previousVersion:newVersion:)`: 더 최신인 번들 바이너리를 설치했다.
- `recoveredInvalidActive(newVersion:)`: 활성 바이너리가 없거나 손상돼 번들로 복구했다.

결과 타입은 변경 여부와 최종 활성 버전을 명확히 제공해야 한다. 문자열 메시지나 파일 존재 여부를 다시 추론하지 않는다.

## 컴포넌트 설계

### `CLIProxyAPIBinaryStore`

파일 시스템 검증과 원자적 교체를 계속 담당한다.

새 번들 전용 조정 연산의 책임:

1. 번들 manifest를 읽고 semantic version을 검증한다.
2. 번들 binary의 SHA-256과 크기를 manifest와 대조한다.
3. 현재 활성 manifest와 binary를 함께 검증한다.
4. 활성 상태가 없거나 손상됐거나 번들보다 오래됐을 때만 번들을 설치한다.
5. 활성 상태가 번들과 같거나 더 최신이면 실행 권한만 보장하고 유지한다.
6. 최종 활성 버전을 기준으로 pending 상태를 정리한다.
7. 조정 결과를 반환한다.

기존 `prepareActiveBinary()`는 서버 start/restart 시 적용 예약 marker가 있는 pending만 승격한다. 다운로드 직후에는 marker가 없고, `Apply on next server start`를 선택하면 `pending/apply-on-next-start` marker를 원자적으로 생성한다. `Apply now`, 새 pending 저장, pending 삭제, 승격 완료 시 marker를 제거한다. 공통 검증·설치 구현은 private helper로 공유해 번들 조정과 서버 prepare의 버전 비교 및 atomic 교체가 달라지지 않게 한다.

### `BundledProxyReconciliationService`

앱 번들 URL 해석과 binary store 호출을 캡슐화한다.

의존성:

- `ManagedPaths`
- `CLIProxyAPIBinaryStore` 또는 이를 추상화한 protocol
- `BundledProxyBinary.url()`
- `BundledProxyBinary.manifestURL()`

서비스는 서버 상태를 직접 읽거나 서버를 재시작하지 않는다. 파일 조정 결과만 반환해 앱 시작 orchestration과 파일 시스템 책임을 분리한다.

### `DashboardViewModel`

앱 시작 orchestration을 담당한다.

`startApplication()` 순서:

1. 서버 상태를 확인해 시작 시점에 실행 중이었는지 기록한다.
2. `BundledProxyReconciliationService`로 번들 조정을 수행한다.
3. 조정 결과가 `installed` 또는 `recoveredInvalidActive`이고 서버가 실행 중이었다면 `ProxyServiceManager.restart()`를 호출한다.
4. 서버 및 provider 상태를 다시 갱신한다.
5. subscription usage를 준비한다.
6. 서버가 꺼져 있고 `autostartServer`가 켜져 있으면 기존 autostart 흐름으로 시작한다.

조정 실패 시 기존 서버를 재시작하지 않고 오류 메시지를 기록한 뒤 나머지 앱 시작을 계속한다.

### `CLIProxyAPIUpdateService`

초기화 시 읽은 활성/pending 상태가 번들 조정 전 값일 수 있으므로, 저장 상태를 다시 읽는 명시적 메서드를 노출한다. 앱 시작 조정이 끝난 뒤 이 메서드를 호출해 다음 값을 갱신한다.

- `currentVersionText`
- `pendingUpdate`
- 활성 버전 이하인 `lastAvailableVersion`
- 활성 버전 이하인 `lastDeferredVersion`

SwiftUI view가 파일 시스템을 직접 읽거나 조정 순서를 관리하지 않게 한다.

### `CLIProxyManagerApp`

`DashboardViewModel`과 `CLIProxyAPIUpdateService`를 생성한 뒤 앱 시작 Task에서 두 객체를 순차적으로 연결한다.

1. `await viewModel.startApplication()`
2. `cliProxyAPIUpdateService.reloadStoredStatus()`

성공과 실패 모두 최종 저장 상태를 다시 읽는다. 조정 서비스의 오류는 `DashboardViewModel.settingsMessage`에 남기고 업데이트 UI는 실제 유지된 활성 상태를 표시한다.

## 버전 및 pending 정책

### 번들보다 활성 버전이 오래된 경우

```text
active 7.2.72
bundled 7.2.91
```

번들 7.2.91을 active로 설치한다.

### 활성 버전이 번들보다 최신인 경우

```text
active 7.2.92
bundled 7.2.91
```

active 7.2.92를 유지한다. source kind가 `user-updated`인지와 무관하게 유효하고 더 최신인 active를 다운그레이드하지 않는다.

### 더 최신인 pending이 있는 경우

```text
active 7.2.72
bundled 7.2.91
pending 7.2.92
```

번들 7.2.91을 active로 설치하고 pending 7.2.92는 보존한다. 사용자가 `Apply now`를 선택하면 즉시 승격하고, `Apply on next server start`를 선택하면 marker를 기록한 뒤 다음 start/restart에서 승격한다. `Cancel`을 선택하거나 아직 적용 방식을 고르지 않았다면 일반 서버 재시작에서도 pending을 승격하지 않는다.

### 오래됐거나 잘못된 pending이 있는 경우

```text
active 7.2.72
bundled 7.2.91
pending 7.2.80
```

번들 7.2.91을 active로 설치하고 pending 7.2.80은 삭제한다. checksum, 크기, manifest가 잘못된 pending도 삭제한다. 이후 오래된 pending을 수동 적용해 다운그레이드할 수 없게 한다.

### pending 적용 예약

`pending/apply-on-next-start`는 사용자가 `Apply on next server start`를 선택했다는 durable marker다.

- 새 pending을 저장하면 이전 marker를 제거한다.
- `Apply on next server start`는 유효한 pending이 있을 때만 marker를 생성한다.
- `Cancel`은 marker를 만들지 않는다.
- 서버 prepare는 marker가 있고 pending이 최종 후보 중 가장 최신일 때만 승격한다.
- pending이 손상됐거나 active/bundled 이하로 오래됐으면 pending 디렉터리와 marker를 함께 제거한다.
- 즉시 적용이나 예약 승격이 성공하면 marker를 제거한다.

기존 버전에서 생성된 pending에는 marker가 없으므로, hotfix 설치 후에는 사용자가 다시 적용 방식을 선택하기 전까지 자동 승격하지 않는다.

### 같은 버전의 번들과 active

버전, checksum, 크기가 유효하면 active를 유지하고 실행 권한만 보장한다. 같은 버전이라는 이유만으로 43MB binary를 매번 복사하지 않는다.

## 서버 재시작 정책

- 조정 결과가 변경 없음이면 서버를 재시작하지 않는다.
- binary가 교체됐고 서버가 실행 중이었다면 즉시 한 번 재시작한다.
- binary가 교체됐지만 서버가 중지 상태면 파일만 교체한다.
- 재시작 성공 후 상태와 subscription usage를 정상 갱신한다.
- 재시작 실패 시 검증된 새 active binary는 유지한다. 서버 상태는 오류로 표시하고 사용자가 기존 재시작 동작을 다시 실행할 수 있게 한다.

실행 중 프로세스가 파일 교체 전 바이너리를 계속 사용하지 않도록 binary 변경과 서버 재시작을 하나의 앱 시작 흐름에서 연결한다.

## 오류 처리

### 번들 검증 실패

번들 binary 또는 manifest가 없거나 checksum, 크기, 버전이 잘못됐으면 active와 pending을 변경하지 않는다. 실행 중 서버도 건드리지 않는다.

### 활성 교체 실패

기존 `replaceFile`의 temporary/backup 전략을 사용한다. 복사 또는 rename 중 실패하면 기존 active를 복구하고 오류를 반환한다.

### pending 정리 실패

active 설치가 성공한 뒤 오래된 pending 삭제만 실패한 경우, active 설치와 필요한 서버 재시작을 막지 않는다. pending 삭제는 best effort로 처리하고, 다음 앱 시작 또는 서버 prepare에서 같은 버전·무결성 검사를 반복해 오래된 pending이 승격되지 않게 한다.

### 서버 재시작 실패

파일 조정을 rollback하지 않는다. 새 binary는 이미 manifest와 일치하도록 검증됐으므로 유지하고 서버 오류를 표시한다. 앱은 종료하지 않는다.

### 사용자 알림

성공 시 modal이나 별도 toast를 강제하지 않는다. 현재 버전과 서버 상태가 자동 갱신되는 것으로 충분하다. 조정 또는 재시작 실패 시에만 기존 `settingsMessage`를 사용해 사람이 이해할 수 있는 오류를 표시한다.

## 테스트 전략

### `CLIProxyAPIBinaryStoreTests`

- active 7.2.72와 bundled 7.2.91에서 bundled를 설치하고 `installed`를 반환한다.
- active 7.2.92와 bundled 7.2.91에서 active를 유지하고 `unchanged`를 반환한다.
- active가 없으면 bundled를 설치하고 `recoveredInvalidActive`를 반환한다.
- active binary 또는 manifest가 손상됐으면 bundled로 복구한다.
- bundled checksum 또는 크기가 잘못됐으면 active를 변경하지 않는다.
- marker 없는 valid pending 7.2.92는 보존하고 일반 prepare에서도 자동 적용하지 않는다.
- marker 있는 valid pending 7.2.92는 다음 prepare에서 적용하고 marker를 제거한다.
- 새 pending 저장은 이전 marker를 제거한다.
- pending 7.2.80은 최종 active 7.2.91보다 오래됐으므로 marker와 함께 삭제한다.
- 잘못된 pending binary 또는 manifest를 marker와 함께 삭제한다.
- 같은 버전의 유효한 active는 다시 복사하지 않고 실행 권한만 복구한다.
- `Apply now`는 marker 유무와 관계없이 즉시 적용하고 marker를 제거한다.

### `DashboardViewModelTests`

- binary 변경 + 서버 실행 중이면 restart를 정확히 한 번 호출한다.
- binary 변경 + 서버 중지이면 restart를 호출하지 않는다.
- 변경 없음이면 실행 중 서버도 restart하지 않는다.
- 조정 실패 시 restart하지 않고 오류 메시지를 남기며 startup 흐름을 계속한다.
- 조정 후 autostart가 필요한 경우 서버를 한 번만 시작한다.
- 조정으로 재시작한 경우 autostart가 중복 start를 실행하지 않는다.

### `CLIProxyAPIUpdateServiceTests`

- reload 후 새 active 버전을 `currentVersionText`에 반영한다.
- 더 최신인 pending을 계속 표시한다.
- active 이하의 available/deferred 상태를 정리한다.
- `Apply on next server start`가 binary store에 적용 예약을 기록한다.
- 예약 실패 시 failed state와 사람이 이해할 수 있는 오류를 남긴다.

### `CLIProxyAPIUpdateUITests`

- Dashboard와 Settings의 `Apply on next server start` 버튼이 메시지만 설정하지 않고 update service 예약 메서드를 호출한다.
- `Cancel`은 pending 예약 메서드를 호출하지 않는다.

### 앱 구성 테스트

- `CLIProxyManagerApp`의 startup Task가 view model 시작 후 update service reload를 호출하는지 검증 가능한 orchestration 경계를 둔다.
- 실제 SwiftUI source 문자열에 의존하는 테스트보다 protocol/test double 기반 동작 테스트를 우선한다.

## 검증

구현 완료 후 다음을 실행한다.

1. 관련 core/app 단위 테스트
2. 전체 `swift test`
3. development configuration build
4. git diff 및 작업 트리 상태 확인

앱 실행과 실제 UI 확인은 프로젝트 방침에 따라 사용자가 수행한다.

## 예상 변경 파일

- `Sources/CLIProxyManagerCore/Config/ManagedPaths.swift`
- `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
- `Sources/CLIProxyManagerApp/BundledProxyBinary.swift`
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
- `Sources/CLIProxyManagerApp/Services/CLIProxyAPIUpdateService.swift`
- `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
- `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`
- `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateServiceTests.swift`
- `Tests/CLIProxyManagerAppTests/CLIProxyAPIUpdateUITests.swift`

새 서비스가 독립 파일로 분리되면 다음 파일도 추가한다.

- `Sources/CLIProxyManagerApp/Services/BundledProxyReconciliationService.swift`
- 대응하는 app test 파일

## 완료 기준

- 앱 업데이트 후 별도 서버 버튼 조작 없이 번들 CLIProxyAPI가 active 경로에 반영된다.
- 서버가 실행 중이었다면 새 binary로 자동 재시작된다.
- 더 최신인 active와 pending은 보존된다.
- pending은 `Apply now` 또는 `Apply on next server start`를 명시적으로 선택한 경우에만 적용되며 `Cancel` 후 재시작에서는 적용되지 않는다.
- pending 업데이트의 사용자 승인 UX는 유지된다.
- 실패 시 기존 active와 실행 중 서버를 가능한 한 보존하고 앱 시작은 계속된다.
- 전체 테스트와 development build가 통과한다.

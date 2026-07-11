# Task 1 Report: Keychain 자동 생성 계약

## 구현

- `SubscriptionUsageManagementKeyConfiguring`에 `createManagementKeyIfNeeded() throws -> Bool` 계약을 추가했습니다.
- `SubscriptionUsageManagementKeyStore`는 기존 키가 있으면 보존하고 `false`를 반환합니다.
- 키가 없으면 Security의 `SecRandomCopyBytes`로 32바이트를 생성하고, URL-safe Base64 형식으로 변환한 뒤 기존 `setManagementKey(_:)`로 Keychain에 저장하고 `true`를 반환합니다.
- 기존 저장 경로를 재사용하여 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 접근성 설정을 유지했습니다.
- 영향받은 테스트 double 두 곳에 결정론적 test 전용 lifecycle 구현을 추가했습니다.

## 변경 파일

- `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageModels.swift`
- `Sources/CLIProxyManagerCore/SubscriptionUsage/SubscriptionUsageManagementKeyStore.swift`
- `Tests/CLIProxyManagerCoreTests/SubscriptionUsageManagementKeyStoreTests.swift`
- `Tests/CLIProxyManagerCoreTests/CLIProxyAPISubscriptionQuotaClientTests.swift`
- `Tests/CLIProxyManagerCoreTests/CLIProxyManagerCommandTests.swift`

## RED 증거

명령:

```sh
swift test --filter SubscriptionUsageManagementKeyStoreTests
```

결과: 실패(예상). 새 lifecycle 테스트가 `SubscriptionUsageManagementKeyStore`에 `createManagementKeyIfNeeded` 멤버가 없다는 컴파일 오류로 실패했습니다. 구현 전 API 부재를 확인했습니다.

## GREEN 증거

명령:

```sh
swift test --filter 'SubscriptionUsageManagementKeyStoreTests|CLIProxyAPISubscriptionQuotaClientTests|CLIProxyManagerCommandTests'
```

결과: 성공. 선택된 20개 테스트가 0 failures로 통과했습니다. 생성된 키나 OAuth 비밀 값은 테스트 출력, stdout, assertion failure에 노출되지 않았습니다.

## 전체 테스트

명령:

```sh
swift test
```

결과: 성공. 527개 테스트, 0 failures, 약 23초.

## Self-review

- 최초 생성, 기존 키 보존, 생성 키 삭제 후 미구성 상태와 읽기 실패를 실제 Keychain 격리 서비스로 검증했습니다.
- 난수 생성 실패는 계정 식별자만 포함하는 기존 `SecretStoreError.writeFailed`로 변환하며 키 내용을 노출하지 않습니다.
- URL-safe Base64 변환은 패딩을 제거해 32바이트에 대해 최소 43자 길이를 만족합니다.
- 모든 protocol conformer를 갱신했고 `git diff --check`를 통과했습니다.

## Concerns

- 전체 테스트 실행에는 기존 Swift 6 concurrency 관련 경고가 남아 있습니다. 이번 변경 범위의 경고가 아니며, 테스트는 모두 성공했습니다.

## Follow-up: Concurrent Creation Race Fix

### 구현

- `createManagementKeyIfNeeded()`의 check-then-create 경로를 원자적인 `SecItemAdd`로 변경했습니다.
- `SecItemAdd`가 `errSecDuplicateItem`을 반환하면 다른 caller가 이미 key를 만든 정상 경쟁 상태로 처리하여 `false`를 반환합니다. 그 외 실패는 기존처럼 `SecretStoreError.writeFailed(account)`으로 처리합니다.
- 생성 경로도 기존과 동일한 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 접근성 속성을 직접 지정합니다.
- 실제 Keychain의 같은 격리 service에 동시에 접근하는 두 store를 사용하는 회귀 테스트를 추가했습니다. 두 caller가 모두 오류 없이 완료하고, 정확히 하나만 `true`를 반환하는지 검증합니다.

### RED/GREEN 증거

RED 명령:

```sh
swift test --filter SubscriptionUsageManagementKeyStoreTests
```

RED 결과: 실패(예상). 두 caller 동시 생성 테스트에서 한 caller가 duplicate Keychain 항목을 `writeFailed`로 처리해 `XCTAssertTrue`가 실패했습니다.

GREEN 명령:

```sh
swift test --filter SubscriptionUsageManagementKeyStoreTests
```

GREEN 결과: 성공. 4개 테스트, 0 failures. 동시 생성 test가 duplicate 경쟁을 오류 없이 완료하고 정확히 한 caller만 생성자로 보고함을 확인했습니다.

### Follow-up Focused Tests

명령:

```sh
swift test --filter 'SubscriptionUsageManagementKeyStoreTests|CLIProxyAPISubscriptionQuotaClientTests|CLIProxyManagerCommandTests'
```

결과: 성공. 21개 테스트, 0 failures. key 또는 OAuth 비밀 값은 출력에 노출되지 않았습니다.

### Follow-up Full Test

명령:

```sh
swift test
```

결과: 성공. 528개 테스트, 0 failures, 약 23초.

### Follow-up Self-review

- 생성 API는 더 이상 기존 값을 갱신하지 않습니다. 사전 존재 검사는 빠른 경로이고, `SecItemAdd`의 duplicate 결과가 생성 여부의 원자적 판정입니다.
- 테스트는 실제 Keychain을 고유 service로 격리해 정확한 duplicate add 경쟁 경로를 재현합니다.
- 오류와 assertion message에 생성된 키 내용은 포함하지 않습니다.

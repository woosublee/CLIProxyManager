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

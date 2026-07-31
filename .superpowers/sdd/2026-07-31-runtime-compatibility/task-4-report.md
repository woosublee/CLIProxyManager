# Task 4 Report: Binary Store Mutation Guard

## Changed files

- `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
  - Injected a synchronous `RuntimeCompatibilityAuthorizing` dependency.
  - Added the sanitized `unsupportedArtifactTarget` store error.
  - Added target authorization before validation and every mutation boundary for pending staging, scheduling, application, active preparation, bundled reconciliation, scheduled promotion, and bundled installation paths.
  - Enforced exact target-less legacy inference only for `CLIProxyAPI_<version>_darwin_aarch64.tar.gz`; unknown target-less assets fail closed.
  - Backfilled the explicit arm64 target only after successful checksum/size validation in an authorized mutation transaction.
- `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`
  - Added no-mutation coverage for mismatched and unknown target candidates across save, schedule, apply, active preparation, bundled reconciliation, and scheduled promotion.
  - Added matching legacy inference and typed sanitized-error coverage.
- `.superpowers/sdd/2026-07-31-runtime-compatibility/task-4-report.md`
  - This required task report.

## RED evidence

1. `swift test --filter CLIProxyAPIBinaryStoreTests`
   - Failed as expected before implementation: target mismatch and unknown target-less candidates were accepted and artifact assertions observed changed pending/active state (31 tests run; 24 assertion failures).
2. `swift test --filter CLIProxyAPIBinaryStoreTests/testReconcileBundledRejectsMismatchedPendingWithoutInstallingBundledBinary`
   - Failed as expected after the initial guard implementation: reconciliation installed the bundled binary before its later pending cleanup detected the incompatible pending target. The regression test observed active data/version changing from `7.2.41` to `7.2.42`.

## GREEN evidence

- `swift test --filter CLIProxyAPIBinaryStoreTests`
  - Passed: 32 tests, 0 failures.
- `git diff --check`
  - Passed with no whitespace errors.

## Commit

- `feat: validate artifact targets before binary mutation`

## Scope and self-review

- Kept the change within the Task 4 binary-store source and focused XCTest suite, plus this required report.
- Confirmed authorization occurs before checksum validation, marker/config writes, backup creation, file moves, scheduled promotion, and bundled installation.
- Confirmed rejection uses the payload-free typed `CLIProxyAPIBinaryStoreError.unsupportedArtifactTarget` error and the tests use `example.com` fixtures only.
- Preserved existing rollback/recovery, runtime/UI/CLI, release API, and CI behavior outside the binary-store mutation guard.

## Residual concerns

- Only the brief-required focused binary-store XCTest suite was run; the full package suite was intentionally not run.

## Fix round 1

### Files

- `Sources/CLIProxyManagerCore/Proxy/CLIProxyAPIBinaryStore.swift`
  - Preserved exact target-less legacy asset provenance as `RuntimeCompatibilityArtifact.legacy` during authorization; unknown target-less assets still fail closed.
- `Tests/CLIProxyManagerCoreTests/CLIProxyAPIBinaryStoreTests.swift`
  - Added injected-authorizer coverage confirming an exact legacy candidate is authorized as pending `.legacy` before its validated manifest is backfilled to explicit arm64.
- `.superpowers/sdd/2026-07-31-runtime-compatibility/task-4-report.md`
  - Appended this fix-round evidence.

### RED

- `swift test --filter CLIProxyAPIBinaryStoreTests/testSavePendingAuthorizesExactLegacyProductionAssetAsLegacyArtifact`
  - Failed as expected: the recorded pending artifact was `.explicit(.darwinArm64)`, not `.legacy`.

### GREEN

- `swift test --filter CLIProxyAPIBinaryStoreTests/testSavePendingAuthorizesExactLegacyProductionAssetAsLegacyArtifact`
  - Passed: 1 test, 0 failures.
- `swift test --filter CLIProxyAPIBinaryStoreTests`
  - Passed: 33 tests, 0 failures.
- `swift test --filter RuntimeCompatibilityTests`
  - Passed: 2 tests, 0 failures.
- `git diff --check`
  - Passed with no whitespace errors.

### Commit

- Fix-round commit SHA is reported in the task completion response after Git creates this commit.

### Residual concerns

- The full package suite was intentionally not run; focused binary-store and runtime-compatibility suites cover this fix.

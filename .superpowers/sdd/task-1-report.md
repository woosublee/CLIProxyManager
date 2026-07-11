# Task 1 Report: Disable/reset config-first transaction

## Status
DONE

## Changes
- Updated `DashboardViewModel.saveSubscriptionUsageEnabled(false)` to persist the disabled subscription-usage configuration before cancelling usage work and deleting the management key.
  - A configuration save failure now leaves the existing enabled configuration, management key, polling, and latest usage snapshot unchanged.
  - A management-key deletion failure leaves the already-persisted disabled configuration in place and is propagated to the caller.
- Updated `DashboardViewModel.resetAllSettings()` to save reset configuration before any management-key cleanup.
  - A reset configuration save failure leaves the enabled configuration and existing management key unchanged.
  - Management-key cleanup remains conditional and, if it fails after the save, the reset configuration remains persisted while the reset failure message is set.
- Added regression coverage for disable config-save failure, reset config-save failure, and disable key-deletion failure.
- Extended `SubscriptionUsageManagementKeyDouble` with injectable deletion failure behavior.

## TDD evidence
- RED: `testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails` failed before implementation because the management key was deleted before configuration saving.
- RED: `testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails` failed before implementation for the same pre-save key deletion.
- RED: `testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails` failed before implementation because disabled configuration was not saved before deletion.
- GREEN: all new and existing transaction tests passed after the config-first ordering change.

## Tests
- `swift test --filter DashboardViewModelRefreshTests.testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails` — expected RED failure observed before implementation.
- `swift test --filter DashboardViewModelRefreshTests.testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails` — expected RED failure observed before implementation.
- `swift test --filter DashboardViewModelRefreshTests.testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails` — expected RED failure observed before implementation.
- `swift test --filter 'DashboardViewModelRefreshTests.(testDisablingSubscriptionUsagePreservesKeyAndEnabledConfigWhenConfigSaveFails|testResetAllSettingsPreservesKeyAndEnabledConfigWhenConfigSaveFails|testDisablingSubscriptionUsageKeepsDisabledConfigWhenKeyDeletionFails|testDisablingSubscriptionUsageDeletesKeyPersistsDisabledConfigAndRestartsProxy|testResetAllSettingsDeletesManagementKeyWhenUsageWasEnabled)'` — 5 tests, 0 failures.
- `swift test --filter DashboardViewModelRefreshTests` — 94 tests, 0 failures.
- `swift test` — 585 tests, 0 failures.

## Commit
- `2355adaac1b0b48adfbf784d8b79816d36c302ef` — `fix: preserve subscription key on config save failure`
- Includes required `Co-Authored-By: Claude <noreply@anthropic.com>` trailer.

## Preserved uncommitted changes
Confirmed after commit via `git diff` and `git status`:
- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`: round-robin active function names continue to use `config.roundRobinProfiles.filter(\.isEnabled)`.
- `Tests/CLIProxyManagerAppTests/DashboardViewModelTests.swift`: forced in-flight subscription usage refresh regression change remains unstaged.
- `Tests/CLIProxyManagerAppTests/ProviderSettingsViewModelTests.swift`: round-robin configuration preservation-for-re-enable regression remains unstaged.
- Untracked design and plan documents remain untracked.

## Concerns
- None.

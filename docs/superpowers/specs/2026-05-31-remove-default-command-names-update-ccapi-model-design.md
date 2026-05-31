# Remove Default Command Names and Update ccapi Default Model Design

## Context

`AppConfig.default` currently leaves OAuth command names blank for `cc` and `ccodex`, but still defaults `ccapi` to `"ccapi"` and uses `"claude-opus-4-7"` as the Claude API model. This can recreate a command name during fallback/reset paths and leaves new/default configurations on an older Claude API model.

The desired behavior is:

- New installs, config fallback, and reset do not automatically create `cc`, `ccapi`, or `ccodex` command names.
- Existing saved command names and model selections are preserved.
- The default Claude API model used by fallback/reset tracks the current latest Claude model for this release.

## Goals

1. Set all default command names to unconfigured empty strings:
   - `commands.cc == ""`
   - `commands.ccapi == ""`
   - `commands.ccodex == ""`
2. Update the default Claude API model to `"claude-opus-4-8"`.
3. Treat blank command names as “not ready to render” in shell function generation and automatic shell install flows.
4. Preserve existing user config values when decoding stored config JSON.
5. Keep explicit command-name validation for user-saved settings.

## Non-goals

- Do not migrate or overwrite existing saved `ccapi.model` values.
- Do not infer whether an existing saved model was user-chosen or inherited from an older default.
- Do not automatically generate a `ccapi` command when only an API key exists.
- Do not change Codex model defaults in this change.

## Configuration behavior

`AppConfig.default` will become the single source of fallback/reset defaults:

```swift
commands: Commands(cc: "", ccapi: "", ccodex: "")
ccapi: ClaudeAPI(model: "claude-opus-4-8")
```

This affects default construction only. Stored config decoding remains value-preserving, so a user config containing:

```json
{
  "commands": { "cc": "cc", "ccapi": "myapi", "ccodex": "ccodex" },
  "ccapi": { "model": "claude-opus-4-7" }
}
```

continues to decode with those exact values.

## Shell function rendering behavior

A provider function is renderable only when:

1. the provider is enabled/available for the current rendering context, and
2. the provider command name is non-empty after trimming whitespace, and
3. the command name passes `ShellCommandNameValidator`.

If a command name is blank, rendering skips that function instead of failing validation. This makes blank defaults safe for automatic install and fallback paths.

Explicitly configured invalid names should still fail when that provider is renderable. Invalid names for disabled providers should not block rendering, matching the existing disabled-provider behavior.

## Dashboard and automatic install behavior

`DashboardViewModel.activeFunctionNames(in:)` should exclude blank command names before checking shell profile conflicts. This prevents blank defaults from being treated as active function names.

`AutomaticShellInstallService.apply` should compute effective enabled functions by combining the provider availability flags with non-blank command names. A provider flag alone is not enough to render a function.

## Settings save behavior

When the user explicitly edits and saves command names, validation remains strict for names that are meant to be active. The save path should continue to reject invalid shell function names and duplicate active names.

Blank command names represent an unconfigured provider command. They are allowed as stored defaults/unconfigured values and are skipped by rendering and conflict detection.

## Testing plan

Update or add tests to cover:

- `AppConfig.default.commands.cc == ""`
- `AppConfig.default.commands.ccapi == ""`
- `AppConfig.default.commands.ccodex == ""`
- `AppConfig.default.ccapi.model == "claude-opus-4-8"`
- default rendering creates no `cc()`, `ccapi()`, or `ccodex()` functions
- rendering creates provider functions when command names are explicitly configured
- existing JSON config preserves saved command names and saved `ccapi.model`
- automatic install skips providers whose command names are blank
- dashboard active function conflict checks ignore blank command names

## Verification

Run focused XCTest suites for config, renderer, dashboard, provider settings, and automatic shell install, then run the full test suite:

```bash
swift test --filter AppConfigTests
swift test --filter AppConfigStoreTests
swift test --filter ShellFunctionRendererTests
swift test --filter DashboardViewModelTests
swift test --filter ProviderSettingsViewModelTests
swift test --filter AutomaticShellInstallServiceTests
swift test
```

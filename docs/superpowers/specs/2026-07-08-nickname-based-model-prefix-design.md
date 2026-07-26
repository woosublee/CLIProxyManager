# Nickname-based short model prefix design

Date: 2026-07-08

## Problem

Multi-account OAuth routing currently injects the auth profile `modelPrefix` into Claude Code model environment variables as `<prefix>/<model>`. CLIProxyAPI uses this prefix to choose the matching auth JSON. The prefix is generated from the auth file name, so Claude Code displays verbose model names such as:

- `codex-codex-personal456-pro-json/gpt-5.5(xhigh)[1m]`
- `codex-codex-work123-team-json/gpt-5.5(xhigh)[1m]`

The routing works, but the visible model label is too noisy. Users already set an account nickname in the app, so the prefix should use that nickname when available.

## Goals

- Keep CLIProxyAPI account routing based on model prefix.
- Make displayed Claude Code model labels shorter and human-readable.
- Prefer the app-level account nickname for the prefix.
- Keep a deterministic fallback when nickname is blank.
- Avoid prefix collisions across command profiles for the same provider.
- Preserve existing long-prefix profiles by updating them when settings are saved or profiles are reconciled.

## Non-goals

- Do not remove the model prefix routing strategy.
- Do not change CLIProxyAPI.
- Do not hide or transform model names inside Claude Code separately from the actual environment model value; the actual value must remain routable as `<prefix>/<model>`.
- Do not require nickname to be unique in the UI. Prefix generation handles collisions internally.

## Prefix rules

For each `OAuthCommandProfile`, compute a route prefix with this priority:

1. If `nickname` is non-empty after trimming whitespace, use a slug derived from nickname.
2. Otherwise, use a short fallback derived from the auth profile ID.

The prefix includes provider identity to keep Claude and Codex namespaces obvious:

- Claude nickname `Work` → `claude-work`
- Codex nickname `Team` → `codex-team`
- Codex nickname `Work Team` → `codex-work-team`
- Blank nickname with auth profile `codex-work123-team.json` → `codex-work123`

Slug rules:

- Lowercase.
- ASCII letters and digits are kept.
- Any other run of characters becomes one `-`.
- Leading/trailing `-` is trimmed.
- Empty slug falls back to the auth-profile fallback.
- No `/` is allowed in the prefix.

Collision handling:

- Prefixes are unique across all command profiles.
- If two command profiles would produce the same prefix, append `-2`, `-3`, etc.
- Example: two Codex profiles both nicknamed `Team` → `codex-team`, `codex-team-2`.

## Data flow

1. On startup/profile refresh, `DashboardViewModel.reconciledOAuthCommandProfiles(in:authProfiles:)` builds or refreshes command profiles.
2. When a command profile has a nickname, its `modelPrefix` is derived from the nickname.
3. When a command profile has no nickname, its `modelPrefix` uses the short auth-profile fallback.
4. When a settings sheet saves a new nickname, the affected command profile's `modelPrefix` is recomputed.
5. After config changes, `reconcileAuthProfilePrefixes()` writes each command profile's `modelPrefix` into the matching auth JSON `prefix` field.
6. `ShellFunctionRenderer` continues rendering `ANTHROPIC_DEFAULT_*_MODEL=<modelPrefix>/<model>`, but the prefix is now short.

## User-visible examples

Before:

```text
[codex-codex-work123-team-json/gpt-5.5(xhigh)[1m]]
```

After nickname `team`:

```text
[codex-team/gpt-5.5(xhigh)[1m]]
```

After blank nickname:

```text
[codex-work123/gpt-5.5(xhigh)[1m]]
```

## Edge cases

- If a nickname changes, the prefix changes on the next save, and auth JSON is synchronized immediately.
- If nickname becomes blank, the prefix changes to the short auth-profile fallback.
- If existing auth JSON already has a long prefix, config reconciliation or settings save replaces it with the computed short prefix.
- If `setPrefix(_:id:)` fails because the auth file is missing, existing error handling remains unchanged; prefix sync is best-effort today and should not delete or mutate other auth files.

## Tests

Add focused tests for:

- Nickname-based prefix generation for Claude and Codex command profiles.
- Blank nickname fallback to short auth-profile prefix.
- Duplicate nicknames receiving numeric suffixes.
- Saving Claude/Codex settings recomputes `modelPrefix` from nickname.
- `reconcileAuthProfilePrefixes()` writes the new short prefix to auth JSON through `setPrefix(_:id:)`.
- `ShellFunctionRenderer` emits short prefix model values for multiple profiles.
- Existing long auth-file-derived prefixes are replaced on reconciliation/save.

## Implementation notes

Likely production files:

- `Sources/CLIProxyManagerApp/ViewModels/DashboardViewModel.swift`
  - Replace current `modelPrefix(provider:authProfileID:)` generation with nickname-aware generation.
  - Ensure uniqueness across all command profiles.
  - Recompute prefix on settings save and reconciliation.
- `Sources/CLIProxyManagerCore/Shell/ShellFunctionRenderer.swift`
  - Likely no structural change; tests should verify it receives/render short prefixes.
- Test files under `Tests/CLIProxyManagerAppTests` and `Tests/CLIProxyManagerCoreTests`.

## Verification

- Focused unit tests for prefix generation and settings save.
- `swift test --filter DashboardViewModelRefreshTests`
- `swift test --filter ProviderSettingsViewModelTests`
- `swift test --filter ShellFunctionRendererTests`
- Full `swift test`
- Development build launch must use `/Users/woosublee/.cliproxy-manager/dev` settings, not `/Users/woosublee/.cliproxy-manager`.

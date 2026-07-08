# Provider Account Round-Robin Routing Design

## Summary

CLIProxyManager will support provider-scoped round-robin commands for OAuth-backed accounts. A round-robin command starts a new Claude Code CLI session with the next selected account for the same provider, while keeping that selected account fixed for the lifetime of the CLI session.

This design intentionally avoids per-request account switching. The CLI client owns conversation context and sends the relevant context on each request, but changing accounts mid-conversation can still create confusing failures because account entitlements, model availability, rate limits, and server-side session assumptions may differ. Session-start selection provides useful distribution without making one conversation span multiple accounts.

## Goals

- Let users distribute new CLI sessions across multiple accounts for the same provider.
- Keep existing account-specific commands working as fixed-account entry points.
- Add a separate round-robin command per provider.
- Let users choose which accounts participate in round-robin.
- Keep model settings fixed on the round-robin command, not on the selected account.
- Persist round-robin selection state across app and terminal restarts.
- Make invalid settings fail clearly before launching Claude Code.
- Design the data model so it can later support multiple round-robin groups per provider, while the initial UI exposes only one group per provider.

## Non-goals

- Per-request round-robin within a single Claude Code conversation.
- Automatic provider request retry on another account after a session has started.
- Rate-limit-aware cooldown.
- Weighted round-robin.
- Multiple visible round-robin groups per provider in the first UI.
- Silent fallback when state cannot be persisted.

## Current Project Context

The app already has a disabled placeholder for routing in `ServerSettingsView` and a `roundRobinEnabled` field in `AppConfig`. That field is currently forced to `false` during decoding and saving, so it is not usable for the new provider-scoped design.

Existing OAuth command routing is centered on `AppConfig.OAuthCommandProfile`:

```swift
OAuthCommandProfile
  provider: AuthProfileType
  authProfileID: String
  commandName: String
  codex: AppConfig.Codex?
  modelPrefix: String
  isEnabled: Bool
```

`ShellFunctionRenderer` renders one shell function per enabled OAuth command profile. Each function sets `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and default model environment variables before running `claude "$@"`. Account routing is represented by prefixing model IDs, for example `codex-fast/gpt-5.5(xhigh)`.

The helper CLI in `Sources/CLIProxyManagerCLI/main.swift` currently supports only `secret get|set|delete`. Round-robin will require a new helper command such as `routing next <round-robin-profile-id>`.

## Architecture

Add a new provider-scoped round-robin configuration model to `AppConfig`.

```swift
public struct RoundRobinProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: AuthProfileType
    public var isEnabled: Bool
    public var commandName: String
    public var nickname: String
    public var includedAuthProfileIDs: [String]
    public var accountDetailHidden: Bool
    public var dangerousPermissionsEnabled: Bool
    public var codex: Codex?
}
```

`roundRobinProfiles: [RoundRobinProfile]` should be added to `AppConfig`.

The first UI version will expose at most one default round-robin profile per provider:

- `claude-default`
- `codex-default`

The array shape is intentional. It leaves room for later UI support such as `ccodexwork`, `ccodexdeep`, or other user-defined groups without another config migration.

The existing `roundRobinEnabled: Bool` should remain backward-compatible but deprecated or ignored. It should not be used as the source of truth for enabling the new feature.

## Command Model

Account-specific commands remain fixed-account commands.

Example:

```text
ccfast   -> always uses codex-fast
ccdeep   -> always uses codex-deep
ccteam2  -> always uses codex-team-2
```

A round-robin command is separate.

```text
ccodex -> chooses the next selected Codex account when starting a new CLI session
```

The selected account stays fixed because the helper is called before `claude "$@"` starts and returns concrete model environment variables for that process.

## Model Settings Policy

Round-robin model settings belong to the round-robin command, not to the selected account.

For example, if `ccodex` is configured as:

```text
Opus:   gpt-5.5(xhigh)
Sonnet: gpt-5.5(medium)
Haiku:  gpt-5.5(low)
```

and the selected account prefix is `codex-fast`, the rendered runtime values are:

```text
ANTHROPIC_DEFAULT_OPUS_MODEL=codex-fast/gpt-5.5(xhigh)
ANTHROPIC_DEFAULT_SONNET_MODEL=codex-fast/gpt-5.5(medium)
ANTHROPIC_DEFAULT_HAIKU_MODEL=codex-fast/gpt-5.5(low)
```

The next CLI session might select `codex-deep`, but it will still use the same base model settings:

```text
ANTHROPIC_DEFAULT_OPUS_MODEL=codex-deep/gpt-5.5(xhigh)
```

This keeps account distribution independent from model behavior.

For Claude OAuth round-robin, the first implementation can reuse the same default Claude OAuth model constants currently used by `ShellFunctionRenderer` unless a separate Claude OAuth model UI is introduced later.

## UI and Settings Flow

Replace the disabled `Round-robin balancing` placeholder in the server routing section with provider-specific round-robin settings.

Initial UI shape:

```text
Routing

Codex round-robin
[ ] Enable
Command: [ccodex]
Accounts:
[x] codex-fast
[x] codex-deep
[ ] codex-personal
Models:
Opus:   [gpt-5.5] Reasoning: [xhigh] Context: [auto]
Sonnet: [gpt-5.5] Reasoning: [medium] Context: [auto]
Haiku:  [gpt-5.5] Reasoning: [low] Context: [auto]
Dangerous permissions: [ ]

Claude round-robin
[ ] Enable
Command: [cc]
Accounts:
[x] claude-work
[x] claude-personal
Dangerous permissions: [ ]
```

The default command suggestions are:

- Claude: `cc`
- Codex: `ccodex`

If the suggested command conflicts with an existing fixed account command, another round-robin command, the Claude API command, or a shell profile alias/function, show a validation message and require a different command.

When a provider has at least two enabled auth profiles, the default included accounts should be all enabled accounts for that provider. Users can uncheck accounts they do not want in the group. A round-robin profile can only be enabled when at least two selected accounts are currently usable.

Useful UI copy:

```text
Start each new CLI session with the next selected account. The chosen account stays fixed for that session.
```

For Codex model settings:

```text
These model settings belong to the round-robin command. Only the account prefix changes between sessions.
```

## Availability Rules

A provider's round-robin settings are available when:

- At least two auth profiles exist for the provider.
- At least two selected auth profiles are enabled.
- At least two selected auth profiles have usable routing prefixes.
- The round-robin command name is valid and non-conflicting.

The UI should show specific unavailable states:

```text
Unavailable — connect at least 2 Codex accounts.
Unavailable — only 1 enabled Codex account is available.
Select at least 2 accounts to enable round-robin.
Some accounts cannot be used because they do not have a routing prefix.
```

At save time, stale account IDs that no longer exist can be removed from `includedAuthProfileIDs`. At execution time, stale, disabled, provider-mismatched, or prefix-less accounts are skipped again.

## Runtime Flow

Shell function rendering adds one function for each enabled round-robin profile.

Example generated function shape:

```bash
ccodex() {
  local routing_env
  if ! routing_env="$(cliproxy-manager routing next codex-default)"; then
    echo "Cannot select a Codex account for round-robin. Open CLIProxyManager to check routing settings."
    return 1
  fi

  eval "$routing_env"

  if ! curl -sf -H 'Authorization: Bearer sk-dummy' "http://127.0.0.1:18317/v1/models" >/dev/null; then
    echo "CLIProxyAPI Manager is not running or authentication settings are invalid. Open the app to check the status."
    return 1
  fi

  ANTHROPIC_BASE_URL="http://127.0.0.1:18317" \
  ANTHROPIC_AUTH_TOKEN='sk-dummy' \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$ANTHROPIC_DEFAULT_OPUS_MODEL" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$ANTHROPIC_DEFAULT_SONNET_MODEL" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_DEFAULT_HAIKU_MODEL" \
  claude "$@"
}
```

The helper command returns tightly controlled shell-safe assignments such as:

```bash
ANTHROPIC_DEFAULT_OPUS_MODEL='codex-fast/gpt-5.5(xhigh)'
ANTHROPIC_DEFAULT_SONNET_MODEL='codex-fast/gpt-5.5(medium)'
ANTHROPIC_DEFAULT_HAIKU_MODEL='codex-fast/gpt-5.5(low)'
CLIPROXY_ROUND_ROBIN_PROFILE='codex-fast.json'
```

Only this fixed allowlist of variable names may be emitted. Values must be single-quoted with the same escaping style used by `ShellFunctionRenderer`. The helper should produce final model strings, not just a prefix. Keeping this logic in Swift makes validation and tests simpler and keeps shell functions small.

## Selection State

Round-robin selection state is persisted across app restarts and terminal restarts.

Add a `RoundRobinStateStore` that stores state in an app-managed JSON file under `ManagedPaths` so both the app and bundled helper resolve the same location, for example:

```json
{
  "groups": {
    "codex-default": {
      "lastSelectedAuthProfileID": "codex-fast.json"
    },
    "claude-default": {
      "lastSelectedAuthProfileID": "claude-work.json"
    }
  }
}
```

Selection algorithm:

```text
candidates: [A, B, C]
last: A
next: B

candidates: [A, B, C]
last: C
next: A

candidates: [A, C]
last: B
next: A
```

If the last selected account is no longer in the candidate list, choose the first candidate. Candidate order follows `includedAuthProfileIDs` order.

Because helper invocations are separate processes, `RoundRobinStateStore.next(...)` must protect read-select-write with a file lock. `NSLock` is not sufficient across processes. If the lock or state write fails, the helper should fail rather than silently launching with an unpersisted selection.

## Error Handling

MVP behavior should favor clear failure over silent fallback.

The helper fails before launching Claude Code when:

- The app config cannot be read.
- The round-robin profile ID does not exist.
- The round-robin profile is disabled.
- Fewer than two usable selected accounts are available.
- The chosen account lacks a routing prefix.
- State cannot be locked, read, or written.
- Model strings cannot be built.

Shell function user-facing error:

```text
Cannot select a Codex account for round-robin. Open CLIProxyManager to check routing settings.
```

The helper can print a more specific diagnostic to stderr, for example:

```text
Codex round-robin requires at least 2 enabled selected accounts.
```

Provider request failures after Claude Code starts are not automatically retried on another account in the first implementation. The next CLI session will select the next account according to state.

## Validation

Save-time validation should cover:

- Command name syntax via existing `ShellCommandNameValidator` rules.
- Duplicate command names across fixed OAuth commands, round-robin commands, and Claude API command.
- Shell profile conflicts via the existing shell installer validation flow.
- At least two selected usable accounts before enabling.
- Provider mismatch in selected accounts.
- Codex model settings validity.

Runtime validation repeats account availability checks because auth profile files can change outside the settings UI.

## Testing Strategy

### `AppConfigTests`

Add tests for:

- `roundRobinProfiles` decode/encode round-trip.
- Missing `roundRobinProfiles` decodes to an empty array.
- Existing `roundRobinEnabled` remains ignored or backward-compatible and does not enable the new feature by itself.
- Codex model settings inside a round-robin profile survive round-trip encoding.
- `dangerousPermissionsEnabled` defaults to `false` when omitted.

### `RoundRobinStateStoreTests`

Add file-based tests for:

- No previous state selects the first candidate.
- Middle candidate advances to the next candidate.
- Last candidate wraps to the first candidate.
- Missing last candidate falls back to the first candidate.
- Selection is persisted.
- Group states are independent.
- File lock protects read-select-write across separate invocations where practical to test.

### `RoundRobinSelectionServiceTests`

Add a core service for helper CLI selection and test:

- `includedAuthProfileIDs` order is preserved.
- Provider-mismatched profiles are excluded.
- Disabled profiles are excluded.
- Prefix-less profiles are excluded.
- Fewer than two usable candidates fails.
- Codex model strings are built from the round-robin profile's Codex settings plus selected prefix.
- Claude model strings are built from default Claude OAuth models plus selected prefix.
- Shell assignment output is safely quoted.

### `ShellFunctionRendererTests`

Add tests for:

- Enabled round-robin profiles render shell functions.
- Disabled round-robin profiles do not render shell functions.
- Fixed account commands and round-robin commands render together.
- Round-robin functions call `cliproxy-manager routing next <id>`.
- The function evaluates helper output before launching Claude Code.
- `dangerousPermissionsEnabled` controls `claude --dangerously-skip-permissions "$@"` for round-robin commands.
- Duplicate command names fail validation.

### CLI tests

Add tests for the helper command parser and behavior:

- `cliproxy-manager routing next codex-default` succeeds with valid config and profiles.
- Missing group ID fails.
- Insufficient candidates fails.
- Output uses shell-safe assignments.
- Existing `secret` commands continue to work.

### ViewModel/UI tests

Add tests for:

- Provider-level availability calculation.
- At least two enabled selected accounts are required.
- Command name validation and duplicate reporting.
- Saving updates `config.roundRobinProfiles` without altering fixed account commands.
- Initial included accounts default to enabled profiles for the provider.
- Codex round-robin model settings initialize from `config.ccodex`.

### App verification

After implementation, verify with a development build as the project preference requires:

1. Run the development app build.
2. Confirm two or more accounts exist for a provider.
3. Enable provider round-robin in Routing settings.
4. Configure a round-robin command.
5. Install or refresh shell functions.
6. Run the round-robin command multiple times.
7. Observe that each new CLI session selects the next account prefix.
8. Confirm the selected prefix remains fixed inside a single CLI process.

Where possible, inspect helper output or proxy logs before making live provider requests to reduce account and rate-limit impact.

## Migration and Compatibility

- Existing `OAuthCommandProfile` entries and account-specific commands continue to work unchanged.
- Existing users with no `roundRobinProfiles` get an empty array and no round-robin commands.
- The existing `roundRobinEnabled` boolean should not activate anything by itself. It can remain decoded as `false` or be left as a deprecated field for compatibility.
- If a future migration removes `roundRobinEnabled`, it should happen separately after the new model is established.

## Open Implementation Notes

- The file-locking mechanism should be chosen during implementation. It must work across helper CLI processes.
- Shell assignment output must be quoted by Swift, not hand-built in shell.
- The generated shell function should avoid executing arbitrary helper output beyond controlled assignments. If `eval` is used, helper output must be tightly controlled and tested.
- If avoiding `eval` is practical, a line-oriented parser in shell can be considered, but Swift-generated shell-safe assignments are likely simpler for the first implementation.

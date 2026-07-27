# Codex reset-credit badges: atomic dispatch implementation report

- Date: 2026-07-27
- Base HEAD: `c6b600a456b09236679e7c8655944f4775dd51f3`
- Scope: atomic subscription quota/reset dispatch authorization and terminal configuration-restart outcomes
- UI/app launch: not changed; app was not launched
- Final implementation commit SHA: `16765911d59b2aa9577d868ba13c0adbccb3244a`

## RED evidence

Production source was unchanged when the four deterministic continuation-based regressions first ran.

Command:

```text
swift test --filter 'DashboardViewModelRefreshTests/(testConfigurationSupersessionBeforeClientDispatchCancelsStaleSplitWorkAndRequeuesForcedOnce|testCancellationResistantStaleResetAttemptCannotSuppressStableGenerationReset|testLateOAuthObservesTerminalSuccessAfterSupersededRestartFailureInSameDrain|testNewerDifferentReasonSuccessClearsSupersededFastFailureOwnership)'
```

Result:

```text
Executed 4 tests, with 9 failures (0 unexpected)
```

Observed failures:

1. Superseded split usage/reset work crossed the controlled dispatch gates with the old profile snapshot instead of producing zero stale dispatches.
2. A cancellation-resistant stale reset report committed attempted metadata and a reset snapshot instead of remaining side-effect free.
3. A same-drain intermediate restart failure poisoned the late OAuth action result, leaving OAuth completion/provider success unset.
4. A newer successful API-key generation did not clear the superseded fast-mode failure message, and terminal subscription refresh did not run.

## GREEN evidence

### New deterministic regressions

```text
Executed 4 tests, with 0 failures (0 unexpected)
```

Covered tests:

- `testConfigurationSupersessionBeforeClientDispatchCancelsStaleSplitWorkAndRequeuesForcedOnce`
- `testCancellationResistantStaleResetAttemptCannotSuppressStableGenerationReset`
- `testLateOAuthObservesTerminalSuccessAfterSupersededRestartFailureInSameDrain`
- `testNewerDifferentReasonSuccessClearsSupersededFastFailureOwnership`

All new timing control uses checked continuations: separate quota usage/reset dispatch gates, per-restart continuations, OAuth start/completion continuations, auth reconciliation notification, and collector update notification.

### Representative prior concurrency regressions

```text
Executed 12 tests, with 0 failures (0 unexpected)
```

The selection covered armed polling, forced manual reload priority, genuine late OAuth terminal failure/recovery, same-reason generation preservation, generation-owned error clearing, pending reset claims/no churn, OAuth cancellation/replacement ownership, terminal reset-only scheduling, independent usage/reset deadlines, and removal-preserved forced priority.

### Full DashboardViewModel refresh suite

```text
Executed 249 tests, with 0 failures (0 unexpected)
```

Three prior expectations were updated intentionally: once the superseded action usage report is discarded, its stale `credentialExpired` state no longer suppresses Claude in the stable-generation recomputation, so the final request contains both current Claude and Codex profiles.

### Client/model suites

```text
CLIProxyAPISubscriptionQuotaClientTests: 27 passed, 0 failed
CodexResetCreditsModelsTests: 3 passed, 0 failed
Combined: 30 passed, 0 failed
```

### Full package verification

```text
swift test: 1,321 passed, 0 failed
swift build -c debug: success
```

### Diff validation

```text
git diff --check: success, no output
```

## Implemented fix 1: atomic dispatch authorization

- Added immutable usage/reset/combined dispatch permits containing:
  - configuration generation;
  - request source identity;
  - automatic/forced priority;
  - port;
  - exact `AuthProfile` snapshot;
  - exact usage/reset profile ID sets;
  - attempt timestamp;
  - owning usage/reset lifecycle generation.
- Stored active permit ownership beside the existing usage/reset task slots.
- Validated the permit on `MainActor` immediately before each concrete quota client invocation, with no intervening `await`.
- Revalidated the same permit after client return and before attempted/deferred metadata, usage/reset state, cache, persistence, retry/deadline, or polling commits.
- Configuration generation changes now cancel and invalidate older active permits, release in-flight and pending reset claims, preserve maximum force priority/source intent in the existing one-item deferred queue, and prevent stale lifecycle cleanup from owning current state.
- Cancellation-resistant stale reports are discarded completely. They cannot consume the three-hour reset interval, overwrite snapshots, persist cache entries, or schedule deadlines.
- Stable work always recomputes enabled profiles from current `authProfiles`; old profile snapshots are never reused.
- Pending reset coalescing is typed and preserves maximum priority plus source identity while retaining the separate one-shot reset task.

## Implemented fix 2: terminal restart outcome

- Replaced the historical aggregate Boolean drain result with a typed terminal result:
  - stable with final applied configuration generation/reasons;
  - terminal generation-owned failure;
  - stopped.
- Recorded final applied generation/reasons in configuration work state.
- Intermediate failure with newer explicit work is no longer published or latched; the drain continues to the newer generation.
- Terminal failure ownership is keyed by generation, not reason labels.
- A successful generation clears any owned failure at or before that generation, including a fast-mode failure superseded by a different-reason success, while preserving unrelated user-written settings messages.
- Server action completion now carries the typed terminal result. Late OAuth observes only the final action outcome, so a same-drain newer success completes OAuth once without an unnecessary restart.
- Genuine final/current-generation failure behavior remains intact: error state/message, pending reasons for explicit recovery, OAuth failure observation, and no automatic tight restart loop.

## Preserved invariants

- One long-lived subscription polling task.
- Separate one-shot reset task; slow reset work does not block usage deadlines.
- Forced priority dominates automatic priority across active invalidation, pending reset coalescing, removal, OAuth/action hand-back, and stable requeue.
- Reset claims are scheduling ownership only; they never count as an attempt until an authorized accepted report classifies them.
- Five-minute usage deadlines, reset retry gate, exponential retry behavior, terminal reset-only wake, and multi-account no-0ns-loop behavior remain covered.
- Global-off, management-key removal, and account removal clear active permits/tasks/claims without configuration requeue; removal preserves required forced refresh for surviving accounts.
- OAuth cancellation/replacement identity guards and collector exactly-once hand-back remain covered.
- Normal start/restart/stop behavior and collector lifecycle remain covered by the full suite.
- Migration, typed client outcomes/protocol defaults, best-effort snapshot persistence, security `$TOKEN$` behavior, and `example.com` test identifiers were not weakened.

## Concerns and limits

1. Under the existing async client/transport contract, once client execution has entered and an external request may already have crossed into the transport/OS, cancellation cannot promise zero wire traffic. The implemented guarantee is zero known-stale dispatch before client entry plus complete rejection of every stale app-state effect after entry; cancellation remains best effort for already-entered work.
2. No UI or runtime app launch verification was performed, per request. Automated verification reached the development debug build.

## Final handoff fix

- Parent/review SHA: `16765911d59b2aa9577d868ba13c0adbccb3244a`; the fix ships in the commit containing this section with subject `fix: preserve reset permit handoff` (final SHA is reported in the handoff response).
- RED: the server-action and OAuth continuation regressions each failed five behavior assertions after normal source release: reset snapshot/cache were absent, usage/reset each duplicated, and polling cadence churned.
- GREEN: new regressions 2/2; independent review selection 14/14; `DashboardViewModelRefreshTests` 251/251; client/model suites 30/30; full `swift test` 1,323/1,323; `swift build -c debug` succeeded.
- Fix: reset dispatch source authorization now transitions from source-owned to independent handoff only on successful action/OAuth completion, while active owner mismatch, cancellation, replacement, permit UUID/lifecycle, profile/port, global-off/removal, and configuration-generation checks remain authoritative.
- Concerns: no UI changes or app launch were performed; already-entered transport cancellation remains best effort as documented above.

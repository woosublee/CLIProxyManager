# Compact Usage Reset Tooltip Design

## Goal

Show all subscription usage reset information from one easy hover target in the Compact HUD.

Hovering anywhere over the rounded subscription usage card presents one multiline tooltip containing the reset status for every visible usage window. The user does not need to precisely target the `5h`, `7d`, or percentage text.

## Scope

- Make the complete rounded Compact HUD subscription usage card the reset-tooltip hover target.
- Present all visible subscription window reset states in one multiline tooltip.
- Show an explanatory waiting state when the provider has not supplied a reset time.
- Use the existing `FastTooltip` timing, cancellation, popover, material, and accessibility settings.
- Remove individual reset hover targets from Compact subscription rows.
- Preserve Compact API-cost row tooltips.
- Add focused presentation and source-contract tests.

## Non-goals

- Add click, tap, toggle, or inline-expansion behavior.
- Resize the Compact HUD when reset details appear.
- Estimate a reset time when the provider returns `null` or omits it.
- Add relative countdowns, timers, or periodic tooltip-only refreshes.
- Change Expanded HUD reset-time presentation.
- Change subscription usage fetching, parsing, caching, persistence, or refresh policy.
- Stop, restart, reconfigure, or write to the running production app or production CLIProxyAPI server during verification.

## Existing Context

`UsageWindow` carries an optional `resetAt`. `CLIProxyAPISubscriptionQuotaClient` parses the provider timestamp, and the Expanded HUD displays the local absolute time.

The Compact HUD currently creates one `CompactUsageRowPresentation` for each visible usage window. Subscription rows receive a reset tooltip only when `resetAt` exists, and `CompactUsageOverlayView` attaches that tooltip to each row `HStack` separately.

This works when the provider supplies a timestamp, but it still requires the pointer to enter a relatively short individual row. It also produces no hover feedback when Claude reports a window such as `five_hour` with `resets_at: null`.

Compact API-cost rows use the same row type but their tooltip describes cost and token details, not subscription reset time. Those row-level tooltips remain separate.

## Interaction Design

### Hover target

The rounded subscription usage card is one hover target. Its complete bounds include:

- period labels;
- usage values;
- spacing between the two columns;
- vertical spacing between rows;
- the card's internal padding.

No click action is added. The HUD frame and account layout remain unchanged.

The shared `FastTooltip` retains its existing 120-millisecond delay. Leaving the card cancels a pending tooltip or dismisses the visible tooltip immediately.

### Tooltip content

The tooltip contains one line for each visible subscription usage window, in the same order as the card:

```text
5h  Aug 8, 4:30 PM
7d  Shown after usage starts
```

Each line contains:

1. the existing compact period label;
2. the provider-supplied reset time formatted with `Date.formatted(date: .abbreviated, time: .shortened)`; or
3. `Shown after usage starts` when `resetAt` is unavailable.

The implementation does not hard-code `five_hour` or `seven_day`. Additional provider-supplied subscription windows appear as additional lines.

The tooltip uses the current locale and time zone. It does not include a heading or repeat `Next reset` on every line, keeping the surface compact.

## Presentation Model

Extend `CompactUsagePresentation` with an optional aggregate tooltip for the whole card:

```swift
let cardTooltip: String?
```

### Subscription usage

`compactSnapshotPresentation` creates one aggregate line per visible window and joins the lines with `\n`.

- A window with `resetAt` contributes `<label>  <formatted reset time>`.
- A window without `resetAt` contributes `<label>  Shown after usage starts`.
- A snapshot with no windows continues to use the existing placeholder and indicator and has no card tooltip.
- A stale snapshot uses the same last-success windows and reset values already retained by the current cache policy.

Subscription row `tooltip` values become `nil`; reset information is owned only by `cardTooltip`.

### API-cost usage

`compactAPICostSnapshotPresentation` sets `cardTooltip` to `nil` and preserves each API-cost row's existing `tooltip`. The view therefore continues to attach row-level tooltips for API-cost cards.

This separation prevents a group reset tooltip from replacing or combining unrelated cost details.

## View Structure

Extract or retain a focused rounded-card view that receives `CompactUsagePresentation`.

For subscription presentation:

1. render the existing rows;
2. apply one rectangular content shape to the complete padded card;
3. attach `fastTooltip(presentation.cardTooltip)` to that card;
4. do not attach `fastTooltip(row.tooltip)` to individual rows.

For API-cost presentation:

1. `cardTooltip` is `nil`;
2. keep `fastTooltip(row.tooltip)` on each row;
3. preserve existing cost text layout and accessibility labels.

The distinction comes from presentation data rather than provider-name checks in the view.

## Accessibility

Hover is supplemental. VoiceOver must expose equivalent reset status without requiring the tooltip.

Subscription row accessibility labels use:

```text
5h, 30 percent used, resets Aug 8, 4:30 PM
```

or, when no timestamp exists:

```text
5h, 0 percent used, reset time shown after usage starts
```

The aggregate tooltip itself remains informational and non-interactive. Existing Reduce Motion, Reduce Transparency, and Increase Contrast handling in `FastTooltip` remains unchanged.

## Data Flow

1. The existing quota client produces `UsageWindow` values with optional `resetAt`.
2. Existing available or stale account state supplies the snapshot to Compact presentation.
3. Compact subscription presentation maps every visible window to a reset-status line and joins the lines into `cardTooltip`.
4. The rounded usage card attaches one `fastTooltip` using the aggregate string.
5. Hovering anywhere inside the card presents all reset rows together.

No storage, request, cache, observer, timer, or production runtime control is introduced.

## Failure and Edge Handling

- `resetAt == nil`: show `Shown after usage starts`; do not invent a timestamp.
- All reset times missing: still show the multiline explanatory tooltip so hover visibly works.
- Some reset times missing: combine available timestamps and waiting states in their original row order.
- Empty snapshot: retain the current unavailable placeholder and indicator; no reset tooltip.
- Stale snapshot: show the last successful reset values and preserve the existing stale warning indicator.
- Past reset timestamp: display the provider-supplied absolute time without deriving a new schedule.
- Long provider labels: preserve the existing label and allow the shared tooltip's multiline wrapping and maximum width.
- API-cost state: keep existing individual cost tooltips and do not show reset waiting copy.
- Rapid pointer movement: rely on existing `FastTooltip` cancellation behavior.

## Testing

### Presentation tests

Extend `CompactUsagePresentationTests` to verify:

1. Multiple subscription windows produce one ordered multiline `cardTooltip`.
2. Available timestamps use the same local absolute format as the Expanded HUD.
3. A missing timestamp produces `Shown after usage starts`.
4. A mixed snapshot combines timestamp and waiting lines.
5. A stale snapshot retains the aggregate tooltip from its last-success windows.
6. Subscription rows have no individual tooltip.
7. API-cost presentation has no aggregate reset tooltip and preserves row tooltips.
8. Accessibility labels include either the reset timestamp or the waiting explanation.

### View source contract

Update the Compact HUD tooltip contract test to verify:

- the card container receives `fastTooltip(presentation.cardTooltip)`;
- the card container has a rectangular content shape covering its padding;
- subscription reset presentation no longer relies on individual row tooltip values;
- row-level `fastTooltip(row.tooltip)` remains available for API-cost presentation.

### Regression and build verification

Run focused tests, the complete `swift test` suite, and the warnings-as-errors development build. Produce a development app bundle using the development data root.

Runtime verification must not stop, restart, kill, reconfigure, or overwrite the running production app or production CLIProxyAPI server. If a dev runtime check cannot proceed independently, stop the dev verification and report the limitation instead of touching production.

## Completion Criteria

- Hovering anywhere over a Compact subscription usage card shows all visible reset statuses in one tooltip.
- Typical 5-hour and 7-day usage appears as two lines.
- Missing Claude reset timestamps visibly explain that the time appears after usage starts.
- Individual subscription rows no longer require precise hover targeting.
- Compact API-cost row tooltips remain unchanged.
- No click interaction or HUD resizing is introduced.
- VoiceOver exposes timestamp and waiting states.
- Existing FastTooltip timing and adaptive appearance remain unchanged.
- Subscription fetching, parsing, cache, refresh, and stale-value behavior remain unchanged.
- Production app and server remain running and untouched during verification.
- Focused tests, full tests, warnings-as-errors build, and development bundle verification pass.

# Compact Usage Reset Tooltip Design

## Goal

Show each subscription usage window's next reset time in the Compact HUD without requiring the user to expand the HUD.

Hovering a Compact HUD usage row such as `5h 30%` or `7d 12%` presents the same local absolute reset time used by the Expanded HUD.

## Scope

- Add reset-time tooltip content to Compact HUD subscription usage rows.
- Use the existing `FastTooltip` interaction, timing, and surface.
- Make the complete usage row the hover target instead of only the value text.
- Include the reset time in the row's VoiceOver description.
- Add focused presentation tests.

## Non-goals

- Change subscription usage fetching, parsing, caching, or refresh behavior.
- Add a relative countdown or a timer that periodically updates tooltip text.
- Change Expanded HUD reset-time presentation.
- Add tooltip content when a usage window has no reset time.
- Hard-code behavior to only the `five_hour` and `seven_day` window IDs.

## Existing Context

`UsageWindow` already carries an optional `resetAt` value. `CLIProxyAPISubscriptionQuotaClient` parses the provider's reset timestamp into this field, and the Expanded HUD currently renders it as:

```text
Next reset: <abbreviated local date and shortened local time>
```

`CompactUsageRowPresentation` already has an optional `tooltip` field. Compact API-cost rows populate it, while Compact subscription rows currently leave it `nil`. `CompactUsageOverlayView` already uses the shared `fastTooltip` modifier, but attaches it only to the value text.

## Design

### Reset text formatting

Add a small pure presentation helper that converts an optional reset date into the Expanded HUD's existing absolute local-time wording:

```text
Next reset: Aug 8, 4:30 PM
```

The helper uses `Date.formatted(date: .abbreviated, time: .shortened)`, preserving the user's current locale and time zone. It returns `nil` when `resetAt` is absent.

The presentation should not derive a relative duration. This avoids a new timer, stale countdown text, and additional lifecycle state.

### Compact subscription presentation

When `compactSnapshotPresentation` maps each `UsageWindow` to `CompactUsageRowPresentation`, it will:

1. Preserve the existing clamped and rounded percentage.
2. Preserve the existing compact display label.
3. Set `tooltip` from the window's reset time.
4. Append the same formatted reset time to the accessibility label when available.

The rule applies to every subscription usage window with `resetAt`, rather than checking specific IDs. This covers the requested 5-hour and 7-day rows and remains correct for other provider-supplied windows.

### Hover target

Move `fastTooltip(row.tooltip)` from the value `Text` to the complete usage-row `HStack` and give the row a rectangular content shape. Hovering either the duration label, the spacing between columns, or the usage value will therefore reveal the tooltip.

Compact API-cost rows use the same row component. Their existing tooltip content remains unchanged, while their hover target becomes the complete row for consistency.

### Accessibility

A subscription row without `resetAt` retains its existing accessibility label:

```text
5h, 30 percent used
```

A row with `resetAt` includes the reset time:

```text
5h, 30 percent used, resets Aug 8, 4:30 PM
```

The visible tooltip is informational and non-interactive. Existing `FastTooltip` behavior for Reduce Motion, Reduce Transparency, and Increase Contrast remains unchanged.

## Data Flow

1. The existing subscription quota client parses `resets_at` into `UsageWindow.resetAt`.
2. The existing account usage state retains the snapshot and its reset dates.
3. `compactSnapshotPresentation` formats each available reset date into tooltip and accessibility text.
4. `CompactUsageOverlayView` passes the presentation tooltip to the existing row-level `fastTooltip` modifier.
5. Hovering the row presents the tooltip after the existing 120-millisecond delay.

No new storage, refresh request, observer, or timer is introduced.

## Failure and Edge Handling

- `resetAt == nil`: the row has no reset tooltip and keeps its existing accessibility text.
- Empty snapshot: the existing unavailable placeholder and indicator remain unchanged.
- Stale snapshot: the last successful snapshot's reset time remains visible, consistent with the existing last-success usage policy and Expanded HUD behavior.
- A reset date in the past: display the provider-supplied absolute time without inventing a replacement schedule. Refresh and stale-state indicators remain responsible for communicating data freshness.
- Rapid pointer movement: existing `FastTooltip` cancellation prevents delayed or orphaned popovers.
- Locale or time-zone changes: formatting occurs from the stored `Date` using current system settings when the presentation is produced.

## Testing

Extend `CompactUsagePresentationTests` with fixed dates to verify:

1. A subscription window with `resetAt` produces `Next reset: <formatted date>` in `tooltip`.
2. The accessibility label includes the same reset time.
3. A subscription window without `resetAt` produces a `nil` tooltip and preserves the existing accessibility label.
4. A stale snapshot retains the last successful snapshot's reset tooltip.
5. Multiple windows receive their own reset tooltip independently.

Add or update a focused source-level view test to verify that `fastTooltip(row.tooltip)` is attached to the usage-row container rather than only the percentage value.

Run the relevant App test target, the complete Swift test suite, and produce a development app build. Per project practice, final app launch and manual hover verification remain with the user.

## Completion Criteria

- Hovering the complete Compact HUD 5-hour or 7-day usage row shows its next reset time.
- Tooltip wording and date formatting match the Expanded HUD's local absolute-time presentation.
- Rows without reset data show no empty or placeholder tooltip.
- VoiceOver announces the reset time when available.
- Existing tooltip timing and adaptive appearance remain unchanged.
- Subscription fetching, cache persistence, background refresh, and stale-value behavior are unchanged.
- Focused tests, the full Swift test suite, and the development build succeed.

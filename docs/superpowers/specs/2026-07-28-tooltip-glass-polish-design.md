# Neutral Glass Badge and Fast Tooltip Design

## Goal

Refine the Codex reset-credit badge so it reads as neutral glass rather than an error badge, and replace delayed macOS `.help` tooltips with one fast, consistent custom tooltip across CLIProxyManager.

## Scope

This change is UI-only.

- Change the reset-credit badge material and adaptive colors.
- Introduce one shared SwiftUI tooltip modifier and tooltip surface.
- Replace all 12 `.help` usages in `Sources/CLIProxyManagerApp`.
- Preserve existing reset-credit presentation, API, cache, polling, migration, and account lifecycle behavior.
- Preserve current avatar sizes, badge metrics, badge offsets, count formatting, and `99+` behavior.

## Current Problems

### Red badge

`CodexResetCreditBadge` overlays `BrandPalette.statusError` at high opacity. The result reads as an error or urgent notification instead of quiet supplemental account information.

### Delayed tooltip

The shared reset-credit avatar and other controls use SwiftUI `.help`. macOS controls its display delay, so the information appears too slowly for account usage inspection.

## Shared Fast Tooltip

### API

Create a reusable modifier with an optional string, preferred arrow edge, and a default 120-millisecond delay.

```swift
extension View {
    func fastTooltip(
        _ text: String?,
        edge: Edge = .top,
        delay: Duration = .milliseconds(120)
    ) -> some View
}
```

The modifier trims whitespace and treats `nil` or an empty string as no tooltip.

### Interaction

- Start a cancellable display task when hover begins.
- Present the tooltip after 120 milliseconds if the pointer remains over the source.
- Cancel the pending task when hover ends.
- Dismiss an already-visible tooltip immediately when hover ends.
- Re-entering the source starts a fresh delay.
- Do not introduce global tooltip state; each source owns its hover lifecycle.

### Presentation

Use a SwiftUI popover anchored to the source bounds so content is not clipped by the menu popup, Expanded HUD, Compact HUD, settings sheet, or dashboard container.

The tooltip surface uses:

- neutral `regularMaterial`;
- an 8-point continuous rounded rectangle;
- primary 11-point system text with multiline wrapping;
- 8-point vertical and 10-point horizontal padding;
- a maximum width of 280 points;
- an adaptive thin highlight/outline;
- a small neutral shadow;
- no provider, warning, or error tint.

### Accessibility and system settings

- Existing explicit accessibility labels remain the primary spoken description.
- Icon-only buttons that previously relied on `.help` receive explicit accessibility labels if missing.
- Reduce Motion removes scale movement and retains only a short opacity transition.
- Reduce Transparency replaces material with an opaque system background.
- Increase Contrast strengthens the outline and background separation.
- Tooltip content is informational and non-interactive.

## Tooltip Migration

Replace all `.help` usages under `Sources/CLIProxyManagerApp` with `fastTooltip`:

1. Add-provider button.
2. Menu bar API-cost rows.
3. Dashboard usage-overlay button.
4. Claude OAuth model refresh button.
5. Claude API-key model refresh button.
6. Codex reset-credit avatar.
7. Subscription usage warning icon.
8. HUD chrome buttons.
9. Expanded HUD API-cost rows.
10. Compact HUD account name.
11. Compact HUD usage rows.
12. Compact HUD status indicator.

Call sites may choose an arrow edge appropriate to their layout, but timing and surface styling remain shared.

## Neutral Reset-Credit Badge

Remove `BrandPalette.statusError` entirely from `CodexResetCreditBadge`.

The badge uses:

- `ultraThinMaterial` in normal transparency mode;
- a very light adaptive `Color.primary` neutral tint;
- primary foreground text instead of fixed white;
- monospaced rounded digits;
- a subtle top-facing highlight and adaptive outline;
- a small neutral shadow;
- an opaque system background under Reduce Transparency;
- a stronger outline under Increase Contrast.

The badge remains visually above the avatar but should not communicate warning, failure, or urgency.

## Components

### `FastTooltipModifier`

Owns hover timing, cancellation, presentation state, anchoring, and popover lifecycle.

### `FastTooltipBubble`

Owns material, typography, spacing, adaptive contrast, reduced-transparency behavior, and shadow.

### `CodexResetCreditBadge`

Retains badge metrics and text layout while changing only its material and adaptive neutral styling.

### `CodexResetCreditAvatar`

Continues to consume `CodexResetCreditsPresentation`. It replaces `.help` with `fastTooltip` and retains the current account-name accessibility label composition.

## Data Flow

1. Existing reset-credit snapshot produces `CodexResetCreditsPresentation`.
2. `CodexResetCreditAvatar` uses `badgeText` for the badge and `tooltip` for `fastTooltip`.
3. Hover timing is local UI state and never affects reset-credit refresh or persistence.
4. Other tooltip call sites pass their existing strings to the same modifier.

## Failure and Edge Handling

- Missing or empty tooltip text presents nothing.
- Rapid pointer traversal cancels pending presentations and avoids flicker.
- Multiple sources do not share state or overwrite one another.
- A disappearing reset-credit badge also removes its tooltip because the presentation becomes `nil`.
- Tooltip cancellation does not alter accessibility labels.

## Testing

Add focused tests that verify:

- the default tooltip delay is 120 milliseconds;
- empty text is treated as unavailable;
- every app `.help` call site migrated to `fastTooltip`;
- the shared tooltip source contains material, adaptive contrast, reduced-motion, and reduced-transparency handling;
- the reset-credit badge no longer references `BrandPalette.statusError`;
- badge metrics and offsets remain unchanged;
- menu bar app icon remains untouched;
- existing reset-credit presentation and propagation tests continue to pass.

Run the complete Swift test suite and produce a debug app bundle. Final visual verification covers Light and Dark appearance, tooltip response, badge neutrality, clipping, and Compact HUD warning separation.

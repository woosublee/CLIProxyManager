# Neutral Glass Badge and Fast Tooltip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace delayed native help tags with a shared 120-millisecond custom tooltip and restyle the Codex reset-credit count as adaptive neutral glass.

**Architecture:** A single `FastTooltip` view modifier owns hover timing and popover presentation, while `FastTooltipBubble` owns the shared material surface. Existing call sites keep their accessibility labels and only exchange `.help` for `.fastTooltip`; `CodexResetCreditBadge` retains its current layout metrics while removing the error tint.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, macOS 15+

## Global Constraints

- The default custom tooltip delay is exactly 120 milliseconds.
- Tooltip text is optional; `nil`, empty, or whitespace-only text presents nothing.
- Replace all `.help` usages under `Sources/CLIProxyManagerApp`; no native `.help(` call remains.
- Tooltip presentation uses one shared neutral glass surface and does not use provider, warning, or error tint.
- The reset-credit badge must not reference `BrandPalette.statusError`.
- Preserve reset-credit badge metrics, offsets, count formatting, and `99+` behavior.
- Preserve all existing accessibility labels; add explicit labels to icon-only controls that lack them.
- Respect Reduce Motion, Reduce Transparency, and Increase Contrast.
- Do not modify reset-credit API, cache, scheduler, migration, or lifecycle behavior.
- Public test email fixtures remain under `example.com`.
- Automated verification ends at a development app bundle; the user performs final visual inspection.

---

### Task 1: Shared fast tooltip component

**Files:**
- Create: `Sources/CLIProxyManagerApp/Views/FastTooltip.swift`
- Create: `Tests/CLIProxyManagerAppTests/FastTooltipTests.swift`

**Interfaces:**
- Produces: `FastTooltipConfiguration.defaultDelayMilliseconds == 120`
- Produces: `normalizedFastTooltipText(_:) -> String?`
- Produces: `View.fastTooltip(_:edge:delay:)`
- Task 2 consumes the modifier at every existing native-help call site.

- [ ] **Step 1: Write failing configuration and source-contract tests**

```swift
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipTests: XCTestCase {
    func testDefaultDelayAndTextNormalization() {
        XCTAssertEqual(FastTooltipConfiguration.defaultDelayMilliseconds, 120)
        XCTAssertNil(normalizedFastTooltipText(nil))
        XCTAssertNil(normalizedFastTooltipText("   \n"))
        XCTAssertEqual(normalizedFastTooltipText("  Reset available  "), "Reset available")
    }

    func testTooltipSourceUsesSharedAdaptivePopoverSurface() throws {
        let source = try appSource(relativePath: "Views/FastTooltip.swift")

        XCTAssertTrue(source.contains(".onHover"))
        XCTAssertTrue(source.contains(".popover("))
        XCTAssertTrue(source.contains(".regularMaterial"))
        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("accessibilityReduceTransparency"))
        XCTAssertTrue(source.contains("accessibilityContrast"))
        XCTAssertTrue(source.contains("Task.sleep"))
        XCTAssertFalse(source.contains("BrandPalette.statusError"))
    }

    private func appSource(relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/CLIProxyManagerApp")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 2: Run RED test**

Run: `swift test --filter FastTooltipTests`

Expected: compile failure because `FastTooltipConfiguration`, `normalizedFastTooltipText`, and `FastTooltip.swift` do not exist.

- [ ] **Step 3: Implement normalization and shared tooltip configuration**

```swift
import SwiftUI

enum FastTooltipConfiguration {
    static let defaultDelayMilliseconds = 120
    static let defaultDelay: Duration = .milliseconds(defaultDelayMilliseconds)
    static let maximumWidth: CGFloat = 280
}

func normalizedFastTooltipText(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
```

- [ ] **Step 4: Implement `FastTooltipModifier`**

The modifier must:

```swift
private struct FastTooltipModifier: ViewModifier {
    let text: String?
    let edge: Edge
    let delay: Duration

    @State private var displayTask: Task<Void, Never>?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onHover(perform: updateHover)
            .popover(
                isPresented: Binding(
                    get: { normalizedFastTooltipText(text) != nil && isPresented },
                    set: { isPresented = $0 }
                ),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: edge
            ) {
                if let text = normalizedFastTooltipText(text) {
                    FastTooltipBubble(text: text)
                }
            }
            .onDisappear { cancelPresentation() }
    }
}
```

`updateHover` starts a cancellable `Task`, sleeps for the configured delay, checks cancellation, and sets `isPresented = true` on hover. Hover exit cancels the task and sets `isPresented = false` immediately.

- [ ] **Step 5: Implement adaptive neutral tooltip bubble**

`FastTooltipBubble` uses:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
@Environment(\.accessibilityContrast) private var contrast
```

Its content must use 11-point system text, a 280-point maximum width, 10 horizontal / 8 vertical padding, an 8-point continuous rounded rectangle, regular material when transparency is enabled, an opaque adaptive system surface otherwise, an adaptive outline, a small neutral shadow, and an opacity-only reduced-motion transition.

- [ ] **Step 6: Expose the modifier API**

```swift
extension View {
    func fastTooltip(
        _ text: String?,
        edge: Edge = .top,
        delay: Duration = FastTooltipConfiguration.defaultDelay
    ) -> some View {
        modifier(FastTooltipModifier(text: text, edge: edge, delay: delay))
    }
}
```

- [ ] **Step 7: Run GREEN tests**

Run: `swift test --filter FastTooltipTests`

Expected: 2 tests, 0 failures.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/CLIProxyManagerApp/Views/FastTooltip.swift \
  Tests/CLIProxyManagerAppTests/FastTooltipTests.swift
git commit -m "feat: add fast glass tooltips" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Migrate native help and neutralize the reset-credit badge

**Files:**
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderListView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/MenuBarStatusView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/DashboardView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/ProviderSettingsSheets.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SubscriptionUsageWarningIcon.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/UsageOverlayView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/CompactUsageOverlayView.swift`
- Modify: `Tests/CLIProxyManagerAppTests/CodexResetCreditBadgeLayoutTests.swift`
- Create: `Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift`

**Interfaces:**
- Consumes: `View.fastTooltip(_:edge:delay:)`
- Produces: zero `.help(` usages in app source
- Produces: neutral adaptive `CodexResetCreditBadge`

- [ ] **Step 1: Write failing migration tests**

```swift
import Foundation
import XCTest
@testable import CLIProxyManagerApp

final class FastTooltipMigrationTests: XCTestCase {
    func testAppSourcesUseFastTooltipInsteadOfNativeHelp() throws {
        let sourceRoot = repositoryRoot().appendingPathComponent("Sources/CLIProxyManagerApp")
        let sourceFiles = try FileManager.default
            .subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try sourceFiles.map {
            try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
        }

        XCTAssertFalse(sources.contains { $0.contains(".help(") })
        XCTAssertGreaterThanOrEqual(sources.filter { $0.contains(".fastTooltip(") }.count, 8)
    }

    func testKnownTooltipSurfacesUseSharedModifier() throws {
        let files = [
            "Views/ProviderListView.swift",
            "Views/MenuBarStatusView.swift",
            "Views/DashboardView.swift",
            "Views/ProviderSettingsSheets.swift",
            "Views/CodexResetCreditBadge.swift",
            "Views/SubscriptionUsageWarningIcon.swift",
            "Views/UsageOverlayView.swift",
            "Views/CompactUsageOverlayView.swift"
        ]
        for file in files {
            XCTAssertTrue(try appSource(relativePath: file).contains(".fastTooltip("), file)
        }
    }
}
```

Include the same `appSource` and `repositoryRoot` helpers used by Task 1.

Update `CodexResetCreditBadgeLayoutTests` assertions:

```swift
XCTAssertTrue(badge.contains(".ultraThinMaterial"))
XCTAssertTrue(badge.contains("accessibilityReduceTransparency"))
XCTAssertTrue(badge.contains("accessibilityContrast"))
XCTAssertTrue(badge.contains(".fastTooltip(tooltip"))
XCTAssertFalse(badge.contains("BrandPalette.statusError"))
XCTAssertFalse(badge.contains(".help("))
```

- [ ] **Step 2: Run RED tests**

Run: `swift test --filter FastTooltipMigrationTests`

Run: `swift test --filter CodexResetCreditBadgeLayoutTests`

Expected: failures because native `.help` calls and the red badge still exist.

- [ ] **Step 3: Replace all 12 native help call sites**

Apply these mappings:

```swift
.help(text)
```

to:

```swift
.fastTooltip(text)
```

Use `.bottom` for sources placed near a top window edge when it prevents off-screen placement; otherwise use the shared `.top` default. Replace `.help(row.tooltip ?? "")` with `.fastTooltip(row.tooltip)` so empty optional values present nothing.

Add or preserve explicit accessibility labels for every icon-only button.

- [ ] **Step 4: Restyle `CodexResetCreditBadge` as neutral adaptive glass**

Add environment values:

```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
@Environment(\.accessibilityContrast) private var contrast
```

Retain the exact font, padding, min-width, min-height, offset, transition, and metrics. Change only foreground/background/outline/shadow:

```swift
.foregroundStyle(.primary)
.background {
    if reduceTransparency {
        Capsule().fill(Color(nsColor: .windowBackgroundColor))
    } else {
        Capsule().fill(.ultraThinMaterial)
    }
}
.overlay {
    Capsule().fill(Color.primary.opacity(0.08))
}
.overlay {
    Capsule().strokeBorder(
        Color.primary.opacity(contrast == .increased ? 0.42 : 0.20),
        lineWidth: contrast == .increased ? 1 : 0.5
    )
}
.overlay(alignment: .top) {
    Capsule()
        .stroke(.white.opacity(0.24), lineWidth: 0.5)
        .mask(alignment: .top) { Rectangle().frame(height: height / 2) }
}
.shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
```

The implementation may adjust the highlight construction to valid SwiftUI syntax while preserving the stated appearance. It must not use `BrandPalette.statusError` or another chromatic status color.

- [ ] **Step 5: Replace reset-credit avatar native help**

```swift
decoratedAvatar
    .fastTooltip(tooltip)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(accountName). \(accessibilityLabel)")
```

When presentation content is absent, keep the undecorated avatar without tooltip or reset-specific accessibility content.

- [ ] **Step 6: Run focused GREEN tests**

Run: `swift test --filter FastTooltipMigrationTests`

Run: `swift test --filter FastTooltipTests`

Run: `swift test --filter CodexResetCreditBadgeLayoutTests`

Run: `swift test --filter SubscriptionUsageWarningIconTests`

Run: `swift test --filter MenuBarStatusSnapshotTests`

Expected: all selected XCTest cases pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/CLIProxyManagerApp/Views \
  Tests/CLIProxyManagerAppTests/CodexResetCreditBadgeLayoutTests.swift \
  Tests/CLIProxyManagerAppTests/FastTooltipMigrationTests.swift
git commit -m "feat: polish reset credit badge tooltips" \
  -m "Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Full verification and development app launch

**Files:**
- Verify: all changed source and test files
- Verify: `docs/superpowers/specs/2026-07-28-tooltip-glass-polish-design.md`

**Interfaces:**
- Verifies: tooltip behavior contracts, migration completeness, neutral badge styling, full regression suite, development bundle
- Produces: signed development app bundle for user visual inspection

- [ ] **Step 1: Run all focused tooltip and badge tests**

```bash
swift test --filter FastTooltipTests
swift test --filter FastTooltipMigrationTests
swift test --filter CodexResetCreditBadgeLayoutTests
swift test --filter CodexResetCreditsPresentationTests
swift test --filter SubscriptionUsageWarningIconTests
swift test --filter MenuBarStatusSnapshotTests
swift test --filter UsageOverlayPresentationStateTests
```

Expected: every command selects tests and passes with 0 failures.

- [ ] **Step 2: Run complete regression and development build**

```bash
swift test
swift build -c debug
git diff --check
```

Expected: all tests pass, debug build exits 0, and diff check has no output.

- [ ] **Step 3: Verify migration and scope statically**

```bash
! rg -n '\.help\(' Sources/CLIProxyManagerApp
! rg -n 'BrandPalette\.statusError' Sources/CLIProxyManagerApp/Views/CodexResetCreditBadge.swift
git diff --name-only main...HEAD
```

Expected: no native help call, no error color in the reset badge, and no data/API/cache/scheduler files in the changed-file list.

- [ ] **Step 4: Build a separate debug app bundle**

```bash
make CONFIGURATION=debug BUILD_DIR=build/reset-credit-tooltip-polish-dev bundle
```

Expected: `build/reset-credit-tooltip-polish-dev/CLIProxyManager.app` exists with executable, helpers, Sparkle framework, and flat resources.

- [ ] **Step 5: Prepare the bundle for side-by-side development launch**

Update only the generated bundle:

```bash
plutil -replace CFBundleIdentifier -string "com.woosublee.CLIProxyManager.tooltip-polish-dev" \
  build/reset-credit-tooltip-polish-dev/CLIProxyManager.app/Contents/Info.plist
plutil -replace CFBundleDisplayName -string "CLIProxyManager Tooltip Polish Dev" \
  build/reset-credit-tooltip-polish-dev/CLIProxyManager.app/Contents/Info.plist
xattr -d com.apple.FinderInfo build/reset-credit-tooltip-polish-dev/CLIProxyManager.app 2>/dev/null || true
xattr -d com.apple.ResourceFork build/reset-credit-tooltip-polish-dev/CLIProxyManager.app 2>/dev/null || true
xattr -cr build/reset-credit-tooltip-polish-dev/CLIProxyManager.app
codesign --force --deep --sign - --timestamp=none \
  build/reset-credit-tooltip-polish-dev/CLIProxyManager.app
codesign --verify --deep --strict --verbose=2 \
  build/reset-credit-tooltip-polish-dev/CLIProxyManager.app
```

- [ ] **Step 6: Back up shell files, launch, verify survival, and restore**

Back up `~/.cliproxy-manager/functions.zsh` and `~/.zshrc`, launch with:

```bash
open -n build/reset-credit-tooltip-polish-dev/CLIProxyManager.app
```

Verify the generated executable process remains alive for at least 5 seconds, restore the backed-up shell files, and activate the development bundle ID.

- [ ] **Step 7: Provide the manual visual checklist**

1. Badge uses neutral glass with no red tint in Light and Dark appearance.
2. Badge digits remain legible at 1, 2, and `99+` widths.
3. Reset-credit tooltip appears after approximately 120 milliseconds.
4. Tooltip disappears immediately on pointer exit.
5. Tooltip is not clipped in menu popup, Expanded HUD, or Compact HUD.
6. Other migrated buttons, warnings, usage rows, and indicators use the same tooltip timing and surface.
7. Reduce Transparency uses an opaque readable surface.
8. Increase Contrast strengthens separation.
9. Compact reset badge and warning indicator remain separated.
10. No badge appears on the menu bar app icon.

- [ ] **Step 8: Commit no generated artifacts**

Run: `git status --short --branch`

Expected: tracked working tree is clean; generated build output is ignored.

---

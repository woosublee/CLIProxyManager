# Automatic Update Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add working Sparkle 2 automatic update support that uses GitHub Release assets for both the DMG and `appcast.xml`, without requiring Apple Developer ID signing or notarization.

**Architecture:** Sparkle is linked only into the macOS app target. A focused `UpdaterService` owns `SPUStandardUpdaterController`, while SwiftUI settings consume a small app-owned interface/copy layer. Release automation generates a one-item Sparkle appcast from the GitHub tag release DMG using Sparkle EdDSA signing and uploads it beside the DMG.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, Sparkle 2.9.2, XCTest, Bash, GitHub Actions, GitHub Releases.

---

## Preflight

- Work from an isolated branch or worktree because the current main worktree has unrelated untracked files.
- Do not commit Sparkle private keys. Only commit the public EdDSA key in `Info.plist`.
- This plan intentionally does not add Apple Developer ID signing or notarization.
- Sources used for Sparkle facts:
  - Sparkle SPM repo: `https://github.com/sparkle-project/Sparkle`
  - Sparkle latest release checked as `2.9.2`
  - Sparkle EdDSA signing docs: `https://sparkle-project.org/documentation/`
  - Sparkle publishing docs: `https://sparkle-project.org/documentation/publishing/`

## File structure

- Modify `Package.swift`
  - Add Sparkle package dependency.
  - Link product `Sparkle` into `CLIProxyManagerApp`.

- Modify `Info.plist`
  - Add `SUFeedURL`.
  - Add `SUPublicEDKey`.
  - Add `SUEnableAutomaticChecks`.

- Create `Sources/CLIProxyManagerApp/Services/UpdaterService.swift`
  - Own Sparkle's `SPUStandardUpdaterController`.
  - Expose app-owned update-check operations and settings copy.

- Modify `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
  - Create one app-scoped `UpdaterService` as `@StateObject`.
  - Pass it into settings.

- Modify `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
  - Pass `UpdaterService` to `AboutSettingsView`.

- Modify `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
  - Replace disabled update placeholder with working Sparkle-backed controls.

- Create `Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift`
  - Test Sparkle package wiring, `Info.plist` keys, and update UI copy constants.

- Create `scripts/generate-sparkle-appcast.sh`
  - Generate `build/appcast.xml` from a DMG, release metadata, and `SPARKLE_PRIVATE_KEY`.

- Create `Tests/ScriptTests/generate-sparkle-appcast-tests.sh`
  - Test appcast generation with a fake `sign_update` executable.

- Modify `.github/workflows/release.yml`
  - Require `SPARKLE_PRIVATE_KEY` for release publishing.
  - Generate and upload `appcast.xml` with the DMG.

- Modify `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`
  - Verify release workflow includes Sparkle appcast generation and upload.

- Modify `README.md`
  - Document automatic updates, Sparkle key setup, release secret, and non-notarized limitations.

---

### Task 1: Add Sparkle package and updater metadata tests

**Files:**
- Modify: `Package.swift`
- Modify: `Info.plist`
- Create: `Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift`

- [ ] **Step 1: Write failing configuration tests**

Create `Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift`:

```swift
import XCTest
@testable import CLIProxyManagerApp

final class UpdaterConfigurationTests: XCTestCase {
    func testInfoPlistContainsSparkleUpdateFeed() throws {
        let plist = try repositoryPlist()

        XCTAssertEqual(
            plist["SUFeedURL"] as? String,
            "https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml"
        )
    }

    func testInfoPlistContainsCommittedSparklePublicKey() throws {
        let plist = try repositoryPlist()
        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)

        XCTAssertGreaterThan(publicKey.count, 40)
        XCTAssertFalse(publicKey.localizedCaseInsensitiveContains("replace"))
        XCTAssertFalse(publicKey.localizedCaseInsensitiveContains("placeholder"))
    }

    func testInfoPlistEnablesAutomaticChecksByDefault() throws {
        let plist = try repositoryPlist()

        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testPackageLinksSparkleProductIntoAppTarget() throws {
        let package = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(package.contains(".package(url: \"https://github.com/sparkle-project/Sparkle\", exact: \"2.9.2\")"))
        XCTAssertTrue(package.contains(".product(name: \"Sparkle\", package: \"Sparkle\")"))
    }

    func testUpdateSettingsCopyMentionsGitHubReleases() {
        XCTAssertEqual(UpdateSettingsCopy.automaticCheckDescription, "Automatically check GitHub Releases for new stable versions.")
        XCTAssertEqual(UpdateSettingsCopy.checkNowDescription, "Check GitHub Releases for a signed CLIProxyManager update.")
        XCTAssertEqual(UpdateSettingsCopy.feedDescription, "Updates are downloaded from GitHub Releases and verified with Sparkle signatures.")
    }

    private func repositoryPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("Info.plist"))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --filter UpdaterConfigurationTests
```

Expected: FAIL. The failures should mention missing `SUFeedURL`, missing `SUPublicEDKey`, missing package dependency, or missing `UpdateSettingsCopy`.

- [ ] **Step 3: Add Sparkle to `Package.swift`**

Change `Package.swift` to this structure:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CLIProxyManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CLIProxyManager", targets: ["CLIProxyManagerApp"]),
        .executable(name: "cliproxy-manager", targets: ["CLIProxyManagerCLI"]),
        .library(name: "CLIProxyManagerCore", targets: ["CLIProxyManagerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2")
    ],
    targets: [
        .target(
            name: "CLIProxyManagerCore",
            dependencies: [],
            path: "Sources/CLIProxyManagerCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerApp",
            dependencies: [
                "CLIProxyManagerCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/CLIProxyManagerApp",
            resources: [
                .copy("Resources/cliproxyapi"),
                .copy("Resources/Licenses")
            ]
        ),
        .executableTarget(
            name: "CLIProxyManagerCLI",
            dependencies: ["CLIProxyManagerCore"],
            path: "Sources/CLIProxyManagerCLI"
        ),
        .testTarget(
            name: "CLIProxyManagerCoreTests",
            dependencies: ["CLIProxyManagerCore"],
            path: "Tests/CLIProxyManagerCoreTests"
        ),
        .testTarget(
            name: "CLIProxyManagerAppTests",
            dependencies: ["CLIProxyManagerApp"],
            path: "Tests/CLIProxyManagerAppTests"
        )
    ]
)
```

- [ ] **Step 4: Generate or export the Sparkle EdDSA key pair**

Run this once on the release maintainer machine. It writes the private key to `build/sparkle_private_key.txt`, which must not be committed.

```bash
set -euo pipefail
mkdir -p build/sparkle-tools
curl -L -o build/sparkle-tools/Sparkle-2.9.2.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz
tar -xJf build/sparkle-tools/Sparkle-2.9.2.tar.xz -C build/sparkle-tools
SPARKLE_GENERATE_KEYS=$(find build/sparkle-tools -type f -name generate_keys -perm +111 | head -n 1)
"$SPARKLE_GENERATE_KEYS" -x build/sparkle_private_key.txt | tee build/sparkle_key_output.txt
```

From `build/sparkle_key_output.txt`, copy the value printed for `SUPublicEDKey`. Store the full contents of `build/sparkle_private_key.txt` in the GitHub secret named `SPARKLE_PRIVATE_KEY`.

- [ ] **Step 5: Add Sparkle keys to `Info.plist`**

Use `PlistBuddy` so the generated public key is inserted without editing XML by hand:

```bash
PUBLIC_KEY=$(python3 - <<'PY'
from pathlib import Path
import re
text = Path('build/sparkle_key_output.txt').read_text()
patterns = [
    r'SUPublicEDKey\s*=\s*([A-Za-z0-9+/=]+)',
    r'<key>SUPublicEDKey</key>\s*<string>([^<]+)</string>',
    r'\b([A-Za-z0-9+/=]{40,})\b',
]
for pattern in patterns:
    match = re.search(pattern, text)
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit('Could not find SUPublicEDKey in build/sparkle_key_output.txt')
PY
)
/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :SUEnableAutomaticChecks' Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :SUFeedURL string https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml' Info.plist
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" Info.plist
/usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' Info.plist
plutil -lint Info.plist
```

Expected: `Info.plist: OK`.

- [ ] **Step 6: Resolve dependencies**

Run:

```bash
swift package resolve
```

Expected: SwiftPM resolves `sparkle-project/Sparkle` at `2.9.2` and creates or updates `Package.resolved`.

- [ ] **Step 7: Re-run configuration tests**

Run:

```bash
swift test --filter UpdaterConfigurationTests
```

Expected: FAIL only because `UpdateSettingsCopy` does not exist yet. Package and plist assertions should pass.

- [ ] **Step 8: Commit package and plist wiring**

Run:

```bash
git add Package.swift Package.resolved Info.plist Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift
git commit -m $'test: cover Sparkle updater configuration\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

---

### Task 2: Add updater service and wire About settings UI

**Files:**
- Create: `Sources/CLIProxyManagerApp/Services/UpdaterService.swift`
- Modify: `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/SettingsView.swift`
- Modify: `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`
- Test: `Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift`

- [ ] **Step 1: Create `UpdaterService.swift`**

Create `Sources/CLIProxyManagerApp/Services/UpdaterService.swift`:

```swift
import Combine
import Foundation
import Sparkle

@MainActor
enum UpdateSettingsCopy {
    static let automaticCheckDescription = "Automatically check GitHub Releases for new stable versions."
    static let checkNowDescription = "Check GitHub Releases for a signed CLIProxyManager update."
    static let feedDescription = "Updates are downloaded from GitHub Releases and verified with Sparkle signatures."
}

@MainActor
final class UpdaterService: ObservableObject {
    static let feedURLString = "https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml"

    private let updaterController: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        updaterController.updater.automaticallyChecksForUpdates
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard updaterController.updater.automaticallyChecksForUpdates != enabled else { return }
        objectWillChange.send()
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
        objectWillChange.send()
    }
}
```

- [ ] **Step 2: Wire one app-scoped updater service**

Modify `Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift` so the app owns one `UpdaterService`:

```swift
import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: DashboardViewModel
    @StateObject private var quitCoordinator: QuitCoordinator
    @StateObject private var updaterService: UpdaterService

    init() {
        let viewModel = DashboardViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _quitCoordinator = StateObject(wrappedValue: QuitCoordinator(shouldStopServerBeforeQuit: {
            viewModel.serverControlState.shouldStopServerBeforeQuit
        }))
        _updaterService = StateObject(wrappedValue: UpdaterService())
    }

    private var appWindowController: AppWindowController {
        AppWindowController(appController: SwiftUIAppController(openWindow: openWindow))
    }

    var body: some Scene {
        Window("CLIProxyManager", id: "main") {
            DashboardView(
                viewModel: viewModel,
                openSettings: { appWindowController.openSettings() },
                quit: { quitCoordinator.requestQuit() }
            )
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(viewModel: viewModel, updaterService: updaterService)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: AppWindowMetrics.settingsWidth, height: AppWindowMetrics.settingsHeight)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appWindowController.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") {
                    appWindowController.closeKeyWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit CLIProxyManager") {
                    quitCoordinator.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarStatusView(
                viewModel: viewModel,
                openMain: {
                    appWindowController.openMain()
                },
                openSettings: {
                    appWindowController.openSettings()
                },
                quit: { quitCoordinator.requestQuit() }
            )
        } label: {
            if let image = AppMarkRenderer.menuBarTemplate() {
                Image(nsImage: image)
            } else {
                Image(systemName: "waveform.path")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Pass the updater service through `SettingsView`**

Modify `Sources/CLIProxyManagerApp/Views/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var updaterService: UpdaterService
    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selection = tab
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.systemImage)
                                Text(tab.title)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == tab ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear))
                            )
                            .overlay {
                                if selection == tab {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }

            ScrollView {
                switch selection {
                case .general:
                    GeneralSettingsView(viewModel: viewModel)
                case .server:
                    ServerSettingsView(viewModel: viewModel)
                case .advanced:
                    AdvancedSettingsView(viewModel: viewModel)
                case .about:
                    AboutSettingsView(updaterService: updaterService)
                }
            }
        }
        .frame(width: AppWindowMetrics.settingsWidth, height: AppWindowMetrics.settingsHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .settingsToast(message: viewModel.settingsMessage, dismiss: viewModel.clearSettingsMessage)
    }
}
```

- [ ] **Step 4: Replace the disabled Updates placeholder**

In `Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift`, replace the existing `AboutSettingsView` with this version. Keep `aboutVersionText` unchanged above it.

```swift
struct AboutSettingsView: View {
    @ObservedObject var updaterService: UpdaterService
    @State private var showLicenses: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                AppIconView(size: 72)
                VStack(spacing: 4) {
                    Text("CLIProxyManager")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Built for the people who proxy")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(verbatim: aboutVersionText())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            SettingsGroup(title: "Updates") {
                SettingsRow(label: "Check for updates", description: UpdateSettingsCopy.automaticCheckDescription) {
                    Toggle("", isOn: Binding(
                        get: { updaterService.automaticallyChecksForUpdates },
                        set: { updaterService.setAutomaticallyChecksForUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SettingsToggleStyle())
                }
                SettingsRow(label: "Check now", description: UpdateSettingsCopy.checkNowDescription, isEnabled: updaterService.canCheckForUpdates) {
                    Button("Check now") {
                        updaterService.checkForUpdates()
                    }
                    .controlSize(.small)
                }
                SettingsRow(label: "Update source", description: UpdateSettingsCopy.feedDescription) {
                    Text("GitHub")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            VStack(spacing: 6) {
                Text(verbatim: "© 2026 CLIProxyManager")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Text("Includes CLIProxyAPI — MIT license.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button("View") {
                        showLicenses = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .sheet(isPresented: $showLicenses) {
            LicensesSheet(onClose: { showLicenses = false })
        }
    }
}
```

- [ ] **Step 5: Run updater configuration tests**

Run:

```bash
swift test --filter UpdaterConfigurationTests
```

Expected: PASS.

- [ ] **Step 6: Run app settings tests**

Run:

```bash
swift test --filter SettingsNavigationTests
```

Expected: PASS.

- [ ] **Step 7: Build the app target**

Run:

```bash
swift build --product CLIProxyManager
```

Expected: PASS. If the compiler reports Sparkle API names changed, inspect Sparkle's generated module interface and update only `UpdaterService.swift` while keeping the same app-facing methods.

- [ ] **Step 8: Commit updater app integration**

Run:

```bash
git add Sources/CLIProxyManagerApp/Services/UpdaterService.swift \
  Sources/CLIProxyManagerApp/CLIProxyManagerApp.swift \
  Sources/CLIProxyManagerApp/Views/SettingsView.swift \
  Sources/CLIProxyManagerApp/Views/GeneralSettingsView.swift \
  Tests/CLIProxyManagerAppTests/UpdaterConfigurationTests.swift
git commit -m $'feat: add Sparkle updater settings integration\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

---

### Task 3: Add Sparkle appcast generation script

**Files:**
- Create: `scripts/generate-sparkle-appcast.sh`
- Create: `Tests/ScriptTests/generate-sparkle-appcast-tests.sh`

- [ ] **Step 1: Write the script test first**

Create `Tests/ScriptTests/generate-sparkle-appcast-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/sparkle-appcast-test.XXXXXX")
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

FAKE_SIGN_UPDATE="$SANDBOX/sign_update"
cat > "$FAKE_SIGN_UPDATE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DMG_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ed-key-file)
      shift
      cat "$1" >/dev/null 2>&1 || cat >/dev/null
      ;;
    *)
      DMG_PATH="$1"
      ;;
  esac
  shift || true
done
if [[ ! -f "$DMG_PATH" ]]; then
  echo "missing dmg" >&2
  exit 2
fi
echo 'sparkle:edSignature="fake-ed-signature" length="123"'
SH
chmod +x "$FAKE_SIGN_UPDATE"

DMG_PATH="$SANDBOX/CLIProxyManager-0.2.0.dmg"
printf 'fake dmg contents' > "$DMG_PATH"

OUTPUT_PATH="$SANDBOX/appcast.xml"
SPARKLE_PRIVATE_KEY='fake-private-key' \
SPARKLE_SIGN_UPDATE="$FAKE_SIGN_UPDATE" \
REPOSITORY='woosublee/CLIProxyManager' \
RELEASE_TAG='v0.2.0' \
VERSION='0.2.0' \
BUILD_NUMBER='7' \
DMG_PATH="$DMG_PATH" \
APPCAST_PATH="$OUTPUT_PATH" \
"$REPO_ROOT/scripts/generate-sparkle-appcast.sh"

[[ -f "$OUTPUT_PATH" ]]
grep -F '<sparkle:version>7</sparkle:version>' "$OUTPUT_PATH" >/dev/null
grep -F '<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>' "$OUTPUT_PATH" >/dev/null
grep -F 'https://github.com/woosublee/CLIProxyManager/releases/download/v0.2.0/CLIProxyManager-0.2.0.dmg' "$OUTPUT_PATH" >/dev/null
grep -F 'sparkle:edSignature="fake-ed-signature"' "$OUTPUT_PATH" >/dev/null
grep -F 'type="application/octet-stream"' "$OUTPUT_PATH" >/dev/null

echo "generate-sparkle-appcast-tests passed"
```

- [ ] **Step 2: Run the script test and verify it fails**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: FAIL because `scripts/generate-sparkle-appcast.sh` does not exist.

- [ ] **Step 3: Add appcast generation script**

Create `scripts/generate-sparkle-appcast.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "generate-sparkle-appcast: $*" >&2
  exit 1
}

REPOSITORY=${REPOSITORY:-woosublee/CLIProxyManager}
APP_NAME=${APP_NAME:-CLIProxyManager}
APPCAST_PATH=${APPCAST_PATH:-build/appcast.xml}
SPARKLE_VERSION=${SPARKLE_VERSION:-2.9.2}

[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || fail "SPARKLE_PRIVATE_KEY is required"
[[ -n "${RELEASE_TAG:-}" ]] || fail "RELEASE_TAG is required"
[[ -n "${VERSION:-}" ]] || fail "VERSION is required"
[[ -n "${BUILD_NUMBER:-}" ]] || fail "BUILD_NUMBER is required"
[[ -n "${DMG_PATH:-}" ]] || fail "DMG_PATH is required"
[[ -f "$DMG_PATH" ]] || fail "DMG_PATH does not exist: $DMG_PATH"

resolve_sign_update() {
  if [[ -n "${SPARKLE_SIGN_UPDATE:-}" ]]; then
    [[ -x "$SPARKLE_SIGN_UPDATE" ]] || fail "SPARKLE_SIGN_UPDATE is not executable: $SPARKLE_SIGN_UPDATE"
    printf '%s\n' "$SPARKLE_SIGN_UPDATE"
    return
  fi

  local tools_dir="build/sparkle-tools"
  local archive="$tools_dir/Sparkle-$SPARKLE_VERSION.tar.xz"
  mkdir -p "$tools_dir"
  if [[ ! -f "$archive" ]]; then
    curl -L -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  fi
  if ! find "$tools_dir" -type f -name sign_update -perm +111 | grep -q .; then
    tar -xJf "$archive" -C "$tools_dir"
  fi
  local found
  found=$(find "$tools_dir" -type f -name sign_update -perm +111 | head -n 1)
  [[ -n "$found" ]] || fail "Could not find Sparkle sign_update in $tools_dir"
  printf '%s\n' "$found"
}

SIGN_UPDATE=$(resolve_sign_update)
SIGNATURE_OUTPUT=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" "$DMG_PATH" --ed-key-file -)
ED_SIGNATURE=$(printf '%s\n' "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)
[[ -n "$ED_SIGNATURE" ]] || fail "Could not parse sparkle:edSignature from sign_update output: $SIGNATURE_OUTPUT"

FILE_LENGTH=$(stat -f%z "$DMG_PATH")
DMG_NAME=$(basename "$DMG_PATH")
DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/$DMG_NAME"
RELEASE_URL="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
mkdir -p "$(dirname "$APPCAST_PATH")"

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>https://github.com/$REPOSITORY/releases</link>
    <description>Stable CLIProxyManager releases</description>
    <language>en</language>
    <item>
      <title>$APP_NAME $VERSION</title>
      <link>$RELEASE_URL</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>$RELEASE_URL</sparkle:releaseNotesLink>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$DOWNLOAD_URL" sparkle:edSignature="$ED_SIGNATURE" length="$FILE_LENGTH" type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

plutil -lint "$APPCAST_PATH" >/dev/null 2>&1 || true
echo "Generated $APPCAST_PATH"
```

- [ ] **Step 4: Make scripts executable**

Run:

```bash
chmod +x scripts/generate-sparkle-appcast.sh Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

- [ ] **Step 5: Run the script test**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: PASS with `generate-sparkle-appcast-tests passed`.

- [ ] **Step 6: Test missing private key failure**

Run:

```bash
set +e
REPOSITORY='woosublee/CLIProxyManager' \
RELEASE_TAG='v0.2.0' \
VERSION='0.2.0' \
BUILD_NUMBER='7' \
DMG_PATH='missing.dmg' \
scripts/generate-sparkle-appcast.sh > /tmp/sparkle-appcast-missing-key.out 2>&1
status=$?
set -e
test "$status" -ne 0
grep -F 'SPARKLE_PRIVATE_KEY is required' /tmp/sparkle-appcast-missing-key.out
```

Expected: command exits non-zero and prints `SPARKLE_PRIVATE_KEY is required`.

- [ ] **Step 7: Commit appcast script**

Run:

```bash
git add scripts/generate-sparkle-appcast.sh Tests/ScriptTests/generate-sparkle-appcast-tests.sh
git commit -m $'feat: generate Sparkle appcast for releases\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

---

### Task 4: Update release workflow to publish appcast

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift`

- [ ] **Step 1: Update release workflow tests first**

Modify `Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift` so `testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags` includes these assertions after the existing workflow assertions:

```swift
        XCTAssertTrue(workflow.contains("APPCAST_PATH=build/appcast.xml"))
        XCTAssertTrue(workflow.contains("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(workflow.contains("test -n \"$SPARKLE_PRIVATE_KEY\""))
        XCTAssertTrue(workflow.contains("scripts/generate-sparkle-appcast.sh"))
        XCTAssertTrue(workflow.contains("gh release upload \"$RELEASE_TAG\" \"$DMG_PATH\" \"$APPCAST_PATH\" --clobber"))
```

- [ ] **Step 2: Run workflow tests and verify failure**

Run:

```bash
swift test --filter ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags
```

Expected: FAIL because the workflow does not generate or upload `appcast.xml` yet.

- [ ] **Step 3: Update `.github/workflows/release.yml`**

Replace the workflow with:

```yaml
name: Release DMG

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:
    inputs:
      tag:
        description: Existing tag to upload the DMG to, for example v0.1.2
        required: true
        type: string

permissions:
  contents: write

jobs:
  release-dmg:
    name: Build and upload DMG
    runs-on: macos-14

    steps:
      - name: Resolve release tag
        id: release-tag
        env:
          DISPATCH_TAG: ${{ inputs.tag }}
        run: |
          if [[ "${{ github.event_name }}" == "workflow_dispatch" ]]; then
            RELEASE_TAG="$DISPATCH_TAG"
          else
            RELEASE_TAG="$GITHUB_REF_NAME"
          fi
          [[ "$RELEASE_TAG" == v* ]]
          echo "release_tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT"
          echo "RELEASE_TAG=$RELEASE_TAG" >> "$GITHUB_ENV"

      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.release-tag.outputs.release_tag }}

      - name: Resolve release metadata
        run: |
          VERSION=${RELEASE_TAG#v}
          BUILD_NUMBER=$(plutil -extract CFBundleVersion raw Info.plist)
          DMG_PATH="build/CLIProxyManager-${VERSION}.dmg"
          APPCAST_PATH="build/appcast.xml"
          echo "VERSION=$VERSION" >> "$GITHUB_ENV"
          echo "BUILD_NUMBER=$BUILD_NUMBER" >> "$GITHUB_ENV"
          echo "DMG_PATH=$DMG_PATH" >> "$GITHUB_ENV"
          echo "APPCAST_PATH=$APPCAST_PATH" >> "$GITHUB_ENV"

      - name: Test
        run: swift test

      - name: Build and verify ad-hoc signed DMG
        run: make CODESIGN_IDENTITY=- VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" verify-dmg

      - name: Generate Sparkle appcast
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          test -n "$SPARKLE_PRIVATE_KEY"
          scripts/generate-sparkle-appcast.sh

      - name: Upload DMG and appcast to GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release view "$RELEASE_TAG" >/dev/null 2>&1 || \
            gh release create "$RELEASE_TAG" --verify-tag --title "CLIProxyManager $VERSION" --notes "Ad-hoc signed, non-notarized DMG with Sparkle appcast."
          gh release upload "$RELEASE_TAG" "$DMG_PATH" "$APPCAST_PATH" --clobber
```

- [ ] **Step 4: Run release workflow tests**

Run:

```bash
swift test --filter ReleaseWorkflowTests/testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags
```

Expected: PASS.

- [ ] **Step 5: Run script test again**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
```

Expected: PASS.

- [ ] **Step 6: Commit workflow update**

Run:

```bash
git add .github/workflows/release.yml Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift
git commit -m $'ci: publish Sparkle appcast with releases\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

---

### Task 5: Document automatic updates and release key setup

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the Releases section**

Replace the existing Releases section in `README.md`:

```markdown
## Releases

Release artifacts are distributed as ad-hoc signed, non-notarized DMGs on GitHub Releases.
```

with:

```markdown
## Releases and automatic updates

Release artifacts are distributed as ad-hoc signed, non-notarized DMGs on GitHub Releases.

CLIProxyManager uses Sparkle 2 for automatic updates. The app checks the stable GitHub Release feed at:

```text
https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml
```

Each release must upload both files:

- `CLIProxyManager-<version>.dmg`
- `appcast.xml`

Sparkle verifies update artifacts with an EdDSA signature before installation. This signature is separate from Apple Developer ID signing. The initial update path does not require Apple Developer ID signing or notarization, but macOS may still show Gatekeeper or quarantine warnings because the app is non-notarized.
```

- [ ] **Step 2: Add release maintainer instructions**

Add this section after the `Updating the bundled CLIProxyAPI binary` section:

```markdown
## Cutting an automatic-update release

Automatic updates require a Sparkle EdDSA private key in the GitHub repository secret named `SPARKLE_PRIVATE_KEY`.

To create or export the key pair on a maintainer Mac:

```zsh
mkdir -p build/sparkle-tools
curl -L -o build/sparkle-tools/Sparkle-2.9.2.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz
tar -xJf build/sparkle-tools/Sparkle-2.9.2.tar.xz -C build/sparkle-tools
SPARKLE_GENERATE_KEYS=$(find build/sparkle-tools -type f -name generate_keys -perm +111 | head -n 1)
"$SPARKLE_GENERATE_KEYS" -x build/sparkle_private_key.txt | tee build/sparkle_key_output.txt
```

Commit only the public key printed for `SUPublicEDKey` in `Info.plist`. Store the full contents of `build/sparkle_private_key.txt` as the `SPARKLE_PRIVATE_KEY` GitHub secret. Do not commit `build/sparkle_private_key.txt`.

To cut a release:

```zsh
git tag v0.2.0
git push origin v0.2.0
```

The release workflow runs tests, builds the ad-hoc signed DMG, generates `appcast.xml`, and uploads both assets to the GitHub Release.

If users installed `/usr/local/bin/cliproxy-manager`, they may need to reinstall the helper after an app update. Sparkle updates the app bundle but does not silently overwrite `/usr/local/bin`.
```

- [ ] **Step 3: Run README-sensitive tests**

Run:

```bash
swift test --filter ReleaseWorkflowTests
```

Expected: PASS.

- [ ] **Step 4: Commit docs**

Run:

```bash
git add README.md
git commit -m $'docs: explain Sparkle automatic updates\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

---

### Task 6: Full verification and manual update smoke test

**Files:**
- No new files expected.
- Verify all files changed by earlier tasks.

- [ ] **Step 1: Run all Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 2: Run script tests**

Run:

```bash
bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh
bash Tests/ScriptTests/vendor-cliproxyapi-tests.sh
```

Expected: both PASS.

- [ ] **Step 3: Build and verify DMG locally**

Run:

```bash
make CODESIGN_IDENTITY=- VERSION="0.1.2" BUILD_NUMBER="6" verify-dmg
```

Expected: PASS with `DMG verification passed`.

- [ ] **Step 4: Generate a local appcast with the real Sparkle private key**

Run with the local private key file generated in Task 1:

```bash
SPARKLE_PRIVATE_KEY=$(cat build/sparkle_private_key.txt) \
RELEASE_TAG='v0.1.2' \
VERSION='0.1.2' \
BUILD_NUMBER='6' \
DMG_PATH='build/CLIProxyManager-0.1.2.dmg' \
APPCAST_PATH='build/appcast.xml' \
scripts/generate-sparkle-appcast.sh
```

Expected: `build/appcast.xml` exists and contains `sparkle:edSignature`.

- [ ] **Step 5: Inspect the generated appcast**

Run:

```bash
grep -F '<sparkle:version>6</sparkle:version>' build/appcast.xml
grep -F '<sparkle:shortVersionString>0.1.2</sparkle:shortVersionString>' build/appcast.xml
grep -F 'sparkle:edSignature=' build/appcast.xml
grep -F 'https://github.com/woosublee/CLIProxyManager/releases/download/v0.1.2/CLIProxyManager-0.1.2.dmg' build/appcast.xml
```

Expected: all four commands print matching lines.

- [ ] **Step 6: Launch the app and smoke-check the UI**

Run:

```bash
open build/CLIProxyManager.app
```

Manual check:

1. Open Settings.
2. Go to About.
3. Confirm Updates section is enabled.
4. Toggle automatic checks.
5. Click Check now.
6. Confirm Sparkle presents its standard update-check UI or an expected no-update/feed error dialog depending on whether a release asset exists.

- [ ] **Step 7: Check working tree**

Run:

```bash
git status --short
```

Expected: only intentionally uncommitted files remain. If `build/sparkle_private_key.txt` appears, delete it or ensure it is ignored before any commit.

- [ ] **Step 8: Final commit if verification changed tracked files**

Run only if earlier verification required small tracked-file fixes:

```bash
git add <fixed-files>
git commit -m $'fix: stabilize Sparkle update verification\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>'
```

- [ ] **Step 9: Report results**

Report these exact items:

- Swift test result.
- Script test result.
- DMG verification result.
- Whether `build/appcast.xml` was generated with a Sparkle signature.
- Whether the About updates UI opened and the Check now button invoked Sparkle.
- Whether the Sparkle private key stayed uncommitted.

---

## Self-review notes

- Spec coverage: app integration, GitHub Release-only appcast, Sparkle EdDSA signing, no Apple notarization requirement, stable-only feed, release workflow, README docs, and helper reinstall caveat are all mapped to tasks.
- Scope check: helper auto-reinstall is intentionally excluded and documented; Developer ID signing/notarization is excluded and documented.
- Type consistency: `UpdaterService`, `UpdateSettingsCopy`, `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SPARKLE_PRIVATE_KEY`, and `APPCAST_PATH` are used consistently across code, tests, scripts, and workflow.

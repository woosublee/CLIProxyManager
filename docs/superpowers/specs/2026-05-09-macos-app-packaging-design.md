# macOS App Packaging and Local Signing Design

## Goal

Make CLIProxyManager installable as a normal macOS application while keeping the existing SwiftPM project structure.

The first supported packaging path is local development installation:

```zsh
make install
```

This should produce a signed `CLIProxyManager.app`, copy it into `/Applications`, and install the `cliproxy-manager` helper command for generated shell functions.

## Scope

### In scope

- Keep `swift build -c release` as the compile step.
- Add a Makefile that builds, bundles, signs, installs, runs, and cleans the app.
- Add an `Info.plist` for the app bundle.
- Add a minimal entitlements file for local signing.
- Sign the app with a local Apple Development identity by default.
- Install `/Applications/CLIProxyManager.app`.
- Install or update `/usr/local/bin/cliproxy-manager` from the release build.

### Out of scope

- Developer ID distribution signing.
- Notarization.
- DMG packaging.
- Xcode project generation.
- App Sandbox.
- Automatic certificate creation or Apple account login.

## Recommended approach

Use SwiftPM for compilation and a Makefile for packaging.

This combines the stable module/resource handling of the current Swift package with the explicit app-bundle, signing, and install flow used by the freeflow project. We should not switch to freeflow's direct `swiftc $(SOURCES)` compilation because CLIProxyManager already has multiple SwiftPM products and copied resources.

## Bundle layout

The Makefile will create this structure under `build/`, which is generated local packaging output and is ignored by git:

```text
build/CLIProxyManager.app/
  Contents/
    Info.plist
    MacOS/
      CLIProxyManager
    Resources/
      cliproxy-manager
      cliproxyapi/
        cliproxyapi
      Licenses/
        CLIProxyAPI-LICENSE.txt
```

SwiftPM's generated app resource bundle remains next to the built executable in the configuration-specific SwiftPM binary directory (for example, `.build/arm64-apple-macosx/release`). The Makefile will copy the contents of any generated `*CLIProxyManagerApp*.bundle` resources into `Contents/Resources` when present, specifically `cliproxyapi/` and `Licenses/`, without copying the `.bundle` directory itself.

## Info.plist

Add a repository-level `Info.plist` with app metadata:

- `CFBundleName`: `CLIProxyManager`
- `CFBundleDisplayName`: `CLIProxyManager`
- `CFBundleExecutable`: `CLIProxyManager`
- `CFBundleInfoDictionaryVersion`: `6.0`
- `CFBundleIdentifier`: configurable, default `com.woosublee.CLIProxyManager`
- `CFBundlePackageType`: `APPL`
- `CFBundleShortVersionString`: configurable, default `0.1.0`
- `CFBundleVersion`: configurable, default `1`
- `LSMinimumSystemVersion`: `13.0`

Do not set `LSUIElement` in this iteration. The app currently has normal windows plus a menu bar extra, so keeping a Dock-visible app is safer for launch, onboarding, settings, and quitting behavior.

## Entitlements and signing

Add `CLIProxyManager.entitlements` as a minimal plist with an empty dictionary.

Do not enable App Sandbox. CLIProxyManager manages files under the user's home directory, edits shell profile files, launches the bundled proxy process, reads/writes Keychain secrets, and installs a command-line helper. Sandboxing this now would require a separate permission and helper design.

The Makefile will sign with hardened runtime:

```zsh
codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements CLIProxyManager.entitlements build/CLIProxyManager.app
```

Default:

```make
CODESIGN_IDENTITY ?= Apple Development
```

Users can override it:

```zsh
make install CODESIGN_IDENTITY="Apple Development: Name (TEAMID)"
```

If signing fails because no matching certificate exists, the Makefile should fail clearly and print the identity override hint.

## Helper command installation

The app currently renders shell functions with `/usr/local/bin/cliproxy-manager` as the helper command. To preserve that behavior, `make install` will copy the release helper executable to:

```text
/usr/local/bin/cliproxy-manager
```

The installed app bundle will also include the helper in:

```text
CLIProxyManager.app/Contents/Resources/cliproxy-manager
```

This keeps the app bundle self-contained for later improvements while preserving current shell function compatibility.

If `/usr/local/bin` does not exist or is not writable, `make install` should create it when possible and otherwise fail with a clear message. The user can rerun the command with appropriate local permissions.

## Makefile targets

### `make all`

Builds both SwiftPM products, creates the `.app` bundle, copies metadata/resources, removes extended attributes, and signs the app.

### `make run`

Builds the app and opens:

```text
build/CLIProxyManager.app
```

### `make install`

Builds the app, stages both the signed app bundle and helper, backs up any existing installed app/helper, then swaps both staged artifacts into place:

```text
/Applications/CLIProxyManager.app
/usr/local/bin/cliproxy-manager
```

If either swap fails after backups are made, the install rolls both paths back to their previous state so the app and helper stay in sync.

### `make install-and-run`

Runs `make install`, terminates any running installed CLIProxyManager instance, and opens the installed app.

### `make clean`

Removes the local `build` directory. It should not delete `.build` so SwiftPM incremental builds remain fast.

### `make distclean`

Optional deeper clean that removes both `build` and `.build`.

## Error handling

- Missing Swift release executable: fail and instruct the user to run `swift build -c release` through `make all`.
- Missing signing identity: fail with a message showing how to set `CODESIGN_IDENTITY`.
- Install staging failure: fail before changing existing installed files if either the app bundle or helper cannot be staged.
- Install swap failure: after staging both artifacts, back up any existing `/Applications/CLIProxyManager.app` and `/usr/local/bin/cliproxy-manager`, swap the app and helper together, and roll both paths back if either swap fails.
- Helper install failure: fail with a clear message and preserve or restore the previous helper so a new app is not left installed with an old or missing helper.

## Testing and verification

After implementation, verify:

```zsh
make clean
make all
make verify
spctl --assess --type execute --verbose build/CLIProxyManager.app
make install
ls -l /Applications/CLIProxyManager.app
ls -l /usr/local/bin/cliproxy-manager
open /Applications/CLIProxyManager.app
swift test
```

`make verify` signs `build/CLIProxyManager.app`, copies it to a `/tmp` app with `ditto --norsrc --noextattr`, removes extended attributes from that copy, and runs `codesign --verify --deep --strict --verbose=2` there. This avoids false failures from the worktree file-provider reattaching `com.apple.FinderInfo` to package directories. `spctl` may still report local-development limitations depending on the certificate trust state. The hard requirement for this iteration is successful `make verify` and local launch.

## Future distribution path

When external distribution is needed, add separate targets rather than changing the local development flow:

- `make dmg`
- `make codesign-dmg`
- `make notarize`

Those targets should use `Developer ID Application` and `notarytool`, following the freeflow policy. They are intentionally not part of this local Apple Development signing iteration.

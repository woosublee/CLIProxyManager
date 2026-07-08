# Automatic Update Support Design

## Summary

Add Sparkle 2 based automatic update support to CLIProxyManager. The first production goal is practical operation with the current GitHub Releases distribution model: GitHub Release assets host both the update artifact and `appcast.xml`, and Sparkle validates updates with its EdDSA signature. Apple Developer ID signing and notarization are not required for the initial implementation.

The app remains ad-hoc signed and non-notarized unless the release environment later provides Apple credentials. This means the update path should work technically, but the release documentation must clearly state the macOS Gatekeeper limitations of non-notarized distribution.

## Goals

- Add Sparkle 2 to the macOS SwiftUI app.
- Replace the disabled `About > Updates` placeholder with a working update check UI.
- Use a stable-only update channel.
- Host the Sparkle feed through GitHub Releases only.
- Generate and upload a Sparkle appcast for tag releases.
- Sign update artifacts with Sparkle EdDSA signatures.
- Preserve the current DMG-based GitHub Release distribution.
- Document how to create and configure the Sparkle signing key.
- Keep Developer ID signing and notarization as optional future improvements, not blockers.

## Non-goals

- Add beta, nightly, or user-selectable update channels.
- Add GitHub Pages, S3, R2, or another feed host.
- Require Apple Developer ID signing or notarization.
- Automatically overwrite `/usr/local/bin/cliproxy-manager` after an app update.
- Add a separate self-update mechanism for the bundled CLIProxyAPI binary.
- Replace the existing release process with a different packaging system.

## Current project context

CLIProxyManager is a SwiftPM-based macOS SwiftUI app with a menu bar UX. The existing package builds these products:

- `CLIProxyManager` macOS app executable
- `cliproxy-manager` helper CLI executable
- `CLIProxyManagerCore` library

The app bundle and DMG are assembled by the `Makefile`, and `.github/workflows/release.yml` currently builds and uploads ad-hoc signed, non-notarized DMGs to GitHub Releases.

The app already has an `About > Updates` section in `GeneralSettingsView`, but the toggle and check button are disabled placeholders. This is the natural entry point for Sparkle.

The app also bundles CLIProxyAPI under app resources. `ProxyServiceManager.installBundledBinaryIfNeeded()` copies or replaces the managed CLIProxyAPI binary under `~/.cliproxy-manager` when the bundled binary changes. Therefore, updating the app bundle also updates the bundled CLIProxyAPI path used by the app on the next prepare/start flow.

## Update feed and artifact hosting

Use GitHub Release assets only.

The app feed URL should be:

```text
https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml
```

GitHub redirects this URL to the latest release asset named `appcast.xml`. This avoids GitHub Pages while still giving the app a stable feed URL.

Each release should upload at least:

- `CLIProxyManager-<version>.dmg`
- `appcast.xml`

The appcast should include one stable item for the release, with:

- version from `CFBundleVersion`
- short version from `CFBundleShortVersionString`
- enclosure URL pointing to the release DMG asset
- artifact length
- Sparkle EdDSA signature
- release notes URL or inline description if available

Only non-prerelease stable tag releases should update the `latest` release feed. Prerelease assets are out of scope for this design.

## Sparkle integration

Add Sparkle 2 as a SwiftPM dependency and link it to `CLIProxyManagerApp`.

Introduce a small app-layer updater wrapper, tentatively named `UpdaterService`, responsible for:

- owning `SPUStandardUpdaterController`
- exposing whether updates can currently be checked
- exposing and mutating `automaticallyChecksForUpdates`
- performing user-initiated update checks

The wrapper should keep Sparkle-specific code out of SwiftUI views. Views should call a simple app-owned interface rather than importing Sparkle directly where avoidable.

Use Sparkle's standard user driver rather than a custom update UI. This keeps the implementation small and delegates download, signature validation, installation, relaunch prompts, and user-visible update errors to Sparkle.

## Info.plist configuration

Add Sparkle configuration to `Info.plist`:

- `SUFeedURL`: `https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml`
- `SUPublicEDKey`: the generated Sparkle public EdDSA key
- automatic check defaults as needed by Sparkle 2

The public key is safe to commit. The private key must not be committed.

The design assumes a single stable feed. There should be no UI for selecting update channels.

## Release signing model

Sparkle EdDSA signing is required for automatic updates.

Apple Developer ID signing and notarization are not required for this initial implementation. The release may remain ad-hoc signed and non-notarized.

Required release secret/configuration:

- Sparkle EdDSA private key, exposed to the release workflow as a secret such as `SPARKLE_PRIVATE_KEY`.

Release behavior should be strict: if a tag release attempts to publish automatic update metadata without the Sparkle private key, the workflow should fail instead of publishing a broken appcast. A release without a valid appcast would make installed apps unable to update reliably.

Developer ID signing and notarization can be added later without changing the app-side Sparkle architecture.

## Release workflow

Update `.github/workflows/release.yml` so tag releases perform these additional steps after building the DMG:

1. Build and verify the app/DMG as today.
2. Make Sparkle tooling available in CI.
3. Sign the DMG with Sparkle EdDSA signing.
4. Generate `appcast.xml` for the release artifact.
5. Upload both the DMG and `appcast.xml` to the GitHub Release.

The implementation may use Sparkle's `generate_appcast` tool if it can be made reliable in CI. If `generate_appcast` is awkward with GitHub Release-only hosting, add a small repository script that generates the one-item appcast using Sparkle's `sign_update` output and known release metadata.

The workflow should keep the current ad-hoc signing path intact.

## Updates UI

Replace the disabled placeholder in `AboutSettingsView` with working controls:

- Automatically check for updates toggle
- Check now button
- Explanatory text that updates are downloaded from GitHub Releases

The check button should call Sparkle's user-initiated update check. The button should be disabled only when Sparkle reports that checking is unavailable.

The UI should not expose beta channels, custom feed URLs, or signing details.

For menu bar-only mode, Sparkle's standard UI is sufficient because it presents its own windows/dialogs when needed. No separate notification system is required in this design.

## Helper CLI and bundled CLIProxyAPI behavior

App updates replace the app bundle. The updated app bundle includes:

- the app executable
- the bundled helper at `Contents/Helpers/cliproxy-manager`
- the bundled CLIProxyAPI resource

The managed CLIProxyAPI binary under `~/.cliproxy-manager` should continue to be updated by the existing `ProxyServiceManager.installBundledBinaryIfNeeded()` comparison/copy behavior.

The external helper at `/usr/local/bin/cliproxy-manager` is different. Sparkle should not silently overwrite it because that path may require elevated permissions and is outside the app bundle.

Initial policy:

- Do not automatically modify `/usr/local/bin/cliproxy-manager` during Sparkle updates.
- Document that users may need to reinstall the helper after updating the app.
- If implementation scope allows, add a non-blocking settings/about warning when the installed helper is missing or differs from the bundled helper.

A privileged helper installer or automatic helper repair flow can be designed separately later.

## Error handling

Sparkle handles most update errors through its standard user driver:

- feed download failures
- malformed appcast
- missing update artifact
- signature mismatch
- download failure
- installation failure

The app should not duplicate these dialogs. It only needs to avoid presenting enabled controls when Sparkle cannot check for updates.

Release documentation must state that the app is currently non-notarized. Some macOS environments may still show Gatekeeper/quarantine warnings or require manual approval even though Sparkle validates update signatures.

## Testing strategy

Add or update tests for these areas:

- `Info.plist` contains `SUFeedURL` and `SUPublicEDKey`.
- `SUFeedURL` uses `https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml`.
- `Package.swift` includes Sparkle and links it to `CLIProxyManagerApp`.
- Settings/About tests verify the updates UI is no longer a disabled placeholder.
- Release workflow tests verify that `appcast.xml` is generated and uploaded.
- Release workflow tests verify that Sparkle signing requires the private key on tag releases.
- Existing `ProxyServiceManagerTests` continue to cover bundled CLIProxyAPI replacement.

Avoid UI tests that depend on live network update checks. Sparkle network behavior should be covered by release artifact generation and configuration tests, not by hitting GitHub from unit tests.

## Documentation updates

Update README or release documentation with:

- how automatic updates work
- the feed URL
- how to generate the Sparkle key pair
- which GitHub secret stores the private key
- how to cut a release that includes appcast metadata
- current limitation: ad-hoc signed and non-notarized distribution
- helper CLI reinstall caveat for `/usr/local/bin/cliproxy-manager`

## Open implementation details

The implementation plan should decide:

- whether to use Sparkle's `generate_appcast` directly or a small repository-specific appcast script
- exact Sparkle SwiftPM product names required by the package version
- exact `Info.plist` keys for default automatic check behavior
- how to inject the Sparkle private key in CI without logging it
- whether helper mismatch detection fits in the first implementation pass

## Acceptance criteria

- The app includes Sparkle 2 and can perform a user-initiated update check from `About > Updates`.
- The app uses the GitHub latest release appcast URL.
- Tag releases publish both the DMG and `appcast.xml` as GitHub Release assets.
- Update artifacts are signed with Sparkle EdDSA signatures.
- The app does not require Apple Developer ID signing or notarization for the initial automatic update path.
- The release workflow fails rather than publishing a broken automatic-update release when Sparkle signing material is missing.
- Documentation explains the current non-notarized limitation and the helper reinstall caveat.
- Existing app, menu bar, settings, release workflow, and proxy manager tests continue to pass.

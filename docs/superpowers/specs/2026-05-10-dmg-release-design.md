# DMG Release Design

## Goal

Add a release path for distributing CLIProxyManager as a macOS DMG through GitHub Releases without requiring an Apple Developer Program account.

## Signing Policy

Use separate signing defaults for local development and public release artifacts.

- Local install/run builds use a self-signed or local certificate by default.
- Public DMG release builds use ad-hoc signing by default.

This keeps local builds consistently signed for the developer's machine while preventing personal certificate metadata from being embedded in public GitHub Release artifacts.

## Makefile Targets

The existing `sign`, `install`, `run`, and `install-and-run` targets remain local-development oriented. They should use a local signing identity by default, with an override for machines that use a different certificate.

Release packaging adds a DMG-oriented path that signs with the release identity, which defaults to ad-hoc signing.

Expected usage:

```sh
make install LOCAL_CODESIGN_IDENTITY="CLIProxyManager Local Release"
make dmg VERSION=0.1.0 BUILD_NUMBER=1
```

The generated DMG should be named:

```text
build/CLIProxyManager-0.1.0.dmg
```

## DMG Layout

The DMG should contain:

```text
CLIProxyManager.app
Applications -> /Applications
```

Use macOS built-in tools only for the first version. A plain `hdiutil`-created DMG is enough; custom backgrounds, Finder window styling, and icon placement are outside this scope.

## GitHub Release Flow

The release artifact belongs on GitHub Releases, not GitHub Packages. GitHub Packages is for package-manager ecosystems such as npm, Maven, NuGet, RubyGems, and container images; it is not the right place for a macOS DMG installer.

Expected release command:

```sh
gh release create v0.1.0 build/CLIProxyManager-0.1.0.dmg
```

A Makefile or script may wrap this command, but uploading to GitHub remains an explicit release action because it changes remote project state.

## Gatekeeper and Notarization

The public DMG is not notarized. Users may see Gatekeeper warnings because the app is not signed with an Apple Developer ID certificate and has not been submitted to Apple notarization.

Documentation should say:

- The GitHub Release DMG is ad-hoc signed and not notarized.
- macOS may block the first launch.
- Users who trust the release can use right-click > Open.
- Developer ID signing, notarization, and stapling can be added later by overriding the release signing identity and adding notarization steps.

## Verification

Release packaging should verify:

- The app bundle exists.
- The app and helper are signed.
- The DMG exists at the expected path.
- The DMG can be attached with `hdiutil attach`.
- The mounted image contains `CLIProxyManager.app` and an `Applications` symlink.

Automated tests should cover generated release command behavior where practical, and shell targets should fail on missing artifacts or failed `hdiutil` commands.

# Release

CLIProxyManager can be distributed as a macOS DMG through GitHub Releases.

## Signing modes

Local install and run targets can use a local signing identity:

```sh
make install LOCAL_CODESIGN_IDENTITY="CLIProxyManager Local Release"
make run LOCAL_CODESIGN_IDENTITY="CLIProxyManager Local Release"
```

Public DMG builds default to ad-hoc signing:

```sh
make dmg VERSION=0.1.0 BUILD_NUMBER=1
```

The public default avoids embedding self-signed certificate metadata in GitHub Release artifacts.

## Build a DMG

```sh
make clean
make verify-dmg VERSION=0.1.0 BUILD_NUMBER=1
```

The DMG is created at:

```text
build/CLIProxyManager-0.1.0.dmg
```

The image contains `CLIProxyManager.app` and an `Applications` symlink.

## Publish to GitHub Releases

Create or update the tag first, then upload the DMG as a release asset:

```sh
gh release create v0.1.0 build/CLIProxyManager-0.1.0.dmg --title "CLIProxyManager 0.1.0" --notes "Ad-hoc signed macOS DMG. Not notarized."
```

If the release already exists:

```sh
gh release upload v0.1.0 build/CLIProxyManager-0.1.0.dmg --clobber
```

## Gatekeeper warning

The public DMG is ad-hoc signed and is not notarized. macOS may block the first launch because the app is not signed with an Apple Developer ID certificate.

If you trust the GitHub Release artifact, open the app with right-click > Open.

## Future Developer ID path

With an Apple Developer Program account, release builds can switch to a Developer ID identity:

```sh
make verify-dmg RELEASE_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
```

Notarization and stapling are not part of the current release flow.

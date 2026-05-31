# cliproxymanager Code Signing Identity Design

## Context

CLIProxyManager currently distributes local release artifacts without Apple Developer ID signing or notarization. Sparkle EdDSA signatures continue to provide update integrity, and the app keeps the `disable-library-validation` entitlement for the current Sparkle distribution path.

The release flow should stop using ad-hoc signing as the default. Development builds and canonical local production release builds should use one local self-signed code signing identity named `cliproxymanager`.

A `cliproxymanager` code signing identity has been created in the local login Keychain for this machine and verified with `codesign --sign cliproxymanager` on a temporary binary. The release tooling should require that identity but should not auto-create it.

## Goals

- Use `cliproxymanager` as the default code signing identity for development builds and canonical local release builds.
- Remove `CODESIGN_IDENTITY=-` from the default local release path.
- Fail early with a clear message when `cliproxymanager` is missing.
- Keep Sparkle EdDSA signing unchanged.
- Keep Developer ID signing and notarization out of scope.
- Keep `disable-library-validation` enabled.

## Non-goals

- Introducing Apple Developer ID Application certificates.
- Adding notarization.
- Importing signing certificates into GitHub Actions.
- Rotating or changing the Sparkle EdDSA key.
- Removing `disable-library-validation`.
- Automatically creating or modifying Keychain certificates from release scripts.

## Signing Policy

The project default signing identity is `cliproxymanager`.

`Makefile` should default local and release signing variables to this identity:

- `LOCAL_CODESIGN_IDENTITY ?= cliproxymanager`
- `RELEASE_CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)` or the equivalent `cliproxymanager` default
- `CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)`

As a result, `make sign`, `make verify`, `make dmg`, `make verify-dmg`, `make install`, and `make run` all use `cliproxymanager` unless the caller explicitly overrides `CODESIGN_IDENTITY`.

Explicit overrides remain possible for emergency debugging, for example `make CODESIGN_IDENTITY=- verify`, but ad-hoc signing is not the default development or release behavior.

## Local Release Flow

`scripts/release-local.sh` should validate that the local Keychain search list contains a usable code signing identity named `cliproxymanager` before building the DMG.

The script should call:

```sh
security find-identity -v -p codesigning
```

and fail if no identity line contains `"cliproxymanager"`.

When the identity exists, the script should call:

```sh
make VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" verify-dmg
```

It should not pass `CODESIGN_IDENTITY=-`.

The script should continue to:

1. Validate that the release tag starts with `v`.
2. Resolve `VERSION` and `BUILD_NUMBER`.
3. Build and verify the signed DMG.
4. Generate the Sparkle appcast.
5. Create the GitHub Release if needed.
6. Upload the DMG and `appcast.xml`.

GitHub Release notes should no longer describe the artifact as ad-hoc signed. They should describe it as a non-notarized DMG signed with the local `cliproxymanager` code signing identity and protected by a Sparkle appcast signature.

## Error Handling

If `cliproxymanager` is missing, `release-local.sh` should fail before starting the build. The error should state:

- A `cliproxymanager` code signing identity is required.
- The user can confirm identities with `security find-identity -v -p codesigning`.
- The release script does not create certificates automatically.

The error should not silently fall back to ad-hoc signing. Silent fallback would make the release artifact differ from the intended signing policy.

## GitHub Actions Fallback

The GitHub Actions release workflow is not the primary release path. This change should not add certificate import, temporary Keychain setup, or GitHub Secrets for the code signing certificate.

The workflow may remain as a manual fallback. It can continue to pass `CODESIGN_IDENTITY=-` explicitly if CI has no `cliproxymanager` identity. Any wording that claims the main release artifacts are ad-hoc signed should be updated. Documentation should make clear that the canonical release path is local and uses `cliproxymanager`; the CI workflow is a fallback that may produce an ad-hoc signed DMG until a future certificate-import design is added.

## Documentation

README release documentation should be updated to say:

- Local release artifacts are signed with the local `cliproxymanager` code signing identity.
- Artifacts are still non-notarized and not signed with Apple Developer ID.
- Sparkle EdDSA signing is separate from macOS code signing.
- The `disable-library-validation` entitlement remains enabled for the current non-Developer-ID Sparkle distribution path.
- The `cliproxymanager` identity must exist in the local Keychain before running `scripts/release-local.sh`.

## Tests

Update script and Swift tests to lock in the policy.

`Tests/ScriptTests/release-local-tests.sh` should:

- Provide a fake `security` command that returns a `cliproxymanager` code signing identity.
- Assert that `release-local.sh` checks for the identity before calling `make`.
- Assert that the fake `make` command receives `VERSION=... BUILD_NUMBER=... verify-dmg`, not `CODESIGN_IDENTITY=- ...`.
- Assert that GitHub Release notes no longer say `Ad-hoc signed`.
- Preserve the invalid tag test.

`Tests/CLIProxyManagerCoreTests/ReleaseWorkflowTests.swift` should:

- Assert that `Makefile` defaults to `cliproxymanager`.
- Assert that the local release path does not force `CODESIGN_IDENTITY=-`.
- Keep existing checks for Sparkle framework bundling, canonical Sparkle signing paths, manual workflow dispatch, appcast generation, and release upload.
- Adjust ad-hoc wording expectations so they match the new canonical local signing policy.

## Verification Plan

After implementation, run:

```sh
swift test
bash Tests/ScriptTests/release-local-tests.sh
make CODESIGN_IDENTITY=cliproxymanager verify
```

If environment and time permit, also run:

```sh
make CODESIGN_IDENTITY=cliproxymanager verify-dmg
```

Report any skipped verification explicitly.

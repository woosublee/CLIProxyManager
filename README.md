# CLIProxyManager

<p align="center">
  <img src="docs/assets/readme-main-window.png" alt="CLIProxyManager main window" width="600">
</p>

CLIProxyManager is a macOS menu bar app for managing a local CLIProxyAPI server and the shell functions you use to launch Claude Code with different account and model backends.

It is designed for users who want one place to:

- Connect Claude OAuth and Codex OAuth profiles.
- Optionally use a Claude API key stored in macOS Keychain.
- Start, stop, and configure the bundled CLIProxyAPI server.
- Install convenient shell functions into `~/.zshrc`.
- Check account, server, and shell setup status from the app.

## Requirements

- macOS 15 or later.
- Claude Code installed and available on your machine.
- A Claude account, Codex/OpenAI OAuth account, or Claude API key depending on which shell function you want to use.
- zsh if you want the app to manage shell functions automatically.

## Releases and automatic updates

Canonical automatic-update release artifacts are built in GitHub Actions, signed with the self-signed `cliproxymanager` code signing identity, and distributed as non-notarized DMGs on GitHub Releases. CLIProxyManager uses Sparkle 2 for automatic updates with this feed URL:

```text
https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml
```

Each GitHub Release that should be available through automatic updates must include both:

- `CLIProxyManager-<version>.dmg`
- `appcast.xml`

Sparkle's EdDSA signature is separate from macOS code signing. The current automatic-update path intentionally stays on the existing self-signed, non-notarized signing model so releases can be cut from CI without interrupting the Sparkle update chain for existing installs. New users may still see macOS Gatekeeper or quarantine warnings because the DMG is non-notarized and not signed with an Apple Developer ID certificate.

The app currently keeps the hardened-runtime `disable-library-validation` entitlement enabled for this non-Developer-ID Sparkle distribution path. Release builds re-sign the bundled Sparkle framework and helper executables with the `cliproxymanager` identity, and without this entitlement macOS can reject the app at launch because the re-signed Sparkle code is not loaded under a matching Developer ID Team ID. Revisit this when Developer ID signing and notarization are introduced.

CLIProxyAPI binary updates are separate from CLIProxyManager app updates. On launch, CLIProxyManager checks the upstream `router-for-me/CLIProxyAPI` GitHub Releases feed in the background at most once every 24 hours. If a newer stable macOS arm64 CLIProxyAPI release is available, the app asks before downloading or applying it.

When the user accepts a CLIProxyAPI binary update, the app downloads `CLIProxyAPI_<version>_darwin_aarch64.tar.gz` and verifies it against upstream `checksums.txt` before storing it. The user can apply the verified binary immediately, which restarts the app-managed server if it is running, or defer it until the next server start. Checksum mismatches, missing assets, extraction failures, and version metadata mismatches keep the existing binary unchanged.

## Quick start

1. Open CLIProxyManager.
2. Use **Add Provider** to connect an account:
   - **Claude OAuth** for your normal Claude Code subscription login.
   - **Codex OAuth** for OpenAI/Codex-backed routing through the local proxy.
3. Review the generated command name and optional nickname, then save.
4. Open **Settings** and install shell functions.
5. Restart your terminal, or run:

   ```zsh
   source ~/.zshrc
   ```

6. Use one of the installed shell functions:

   ```zsh
   cc
   ccodex
   ccapi
   ```

`ccapi` is installed only when a Claude API key exists in the macOS Keychain.

## SSH and headless management

`cpm start` controls only the local CLIProxyAPI proxy process. It does not open the GUI app and does not require a display session. It requires SSH access as the same non-root macOS account that owns `~/.cliproxy-manager`.

```zsh
cpm status
cpm start
cpm logs -f
cpm restart
cpm stop

cpm app status
cpm app start
cpm app stop
```

The GUI app is optional — all proxy lifecycle operations work from an SSH session.

## Shell functions

CLIProxyManager generates shell functions instead of aliases so each command can set the right environment only for that invocation.

### `cc`

Runs Claude Code through the bundled local CLIProxyAPI server using your Claude OAuth profile.

Use this when you want Claude Code to use your normal Claude account or subscription login through the app-managed proxy.

### `ccodex`

Runs Claude Code through the bundled local CLIProxyAPI server using Codex/OpenAI OAuth-backed routing.

CLIProxyManager maps Claude model roles to the Codex model settings saved in the app:

- Opus role
- Sonnet role
- Haiku role

You can configure model, reasoning level, and context window from the Codex account settings sheet.

### `ccapi`

Runs Claude Code directly with a Claude API key from macOS Keychain.

The app does not write the API key into your shell profile. The generated function calls the helper command to read the key at runtime.

```zsh
cliproxy-manager secret get claude-api-key
```

If no Claude API key is stored, `ccapi` is omitted from the installed shell functions.

## Settings overview

### General

Use General settings to control app appearance and behavior:

- Light, Dark, or System appearance.
- Launch at login.
- Menu bar only mode.
- Notifications.

### Server

Use Server settings to control the local CLIProxyAPI runtime:

- Listen port.
- Bind address.
- Start server on launch.
- Manual restart after changing server settings.

The app writes the proxy config under:

```text
~/.cliproxy-manager/cliproxyapi/config.yaml
```

### Accounts

Connected provider rows appear after an auth profile exists. Each provider row lets you review the command name, nickname, connection details, and account actions.

Removing an account deletes the corresponding app-managed auth profile from:

```text
~/.cliproxy-manager/auth
```

### Advanced

Advanced settings include log level, log access, and reset actions. Resetting app settings preserves user-managed account data and command names, but resets preferences such as appearance, behavior, server settings, and logging level.

## Files managed by the app

CLIProxyManager stores app-managed files under:

```text
~/.cliproxy-manager
```

Important files and directories:

| Path | Purpose |
| --- | --- |
| `~/.cliproxy-manager/config.json` | App preferences and command settings. |
| `~/.cliproxy-manager/functions.zsh` | Generated shell functions. |
| `~/.cliproxy-manager/auth/` | App-managed OAuth profile files. |
| `~/.cliproxy-manager/logs/` | App and proxy logs. |
| `~/.cliproxy-manager/cliproxyapi/` | Bundled proxy binary and generated proxy config. |

When shell functions are installed, CLIProxyManager adds or updates one managed block in `~/.zshrc` that sources `~/.cliproxy-manager/functions.zsh`.

## Troubleshooting

### The command is not found in my terminal

Restart your terminal or run:

```zsh
source ~/.zshrc
```

Then check that the shell functions file exists:

```zsh
ls ~/.cliproxy-manager/functions.zsh
```

### The app reports a shell function name conflict

Another function or alias with the same name already exists in your shell profile. Choose a different command name in CLIProxyManager, or remove the conflicting function from your shell profile.

### `ccapi` is missing

`ccapi` is generated only when a Claude API key is stored in Keychain. Add or update the API key in the app, then reinstall shell functions.

### The local server is not responding

Open CLIProxyManager and check the server status. If needed:

1. Stop the server.
2. Start it again.
3. Confirm the configured port is not already used by another process.
4. Open logs from the Advanced settings screen.

### Codex models are not listed

Start the local server and confirm the Codex OAuth profile is connected. If model loading still fails, enter the model names manually in Codex settings.

## Security and credentials

- Claude API keys are stored in macOS Keychain.
- OAuth profile files are stored under `~/.cliproxy-manager/auth`.
- Generated shell functions use a local dummy API key only for the app-managed local proxy.
- Do not commit files from `~/.cliproxy-manager` to a repository.

## CLIProxyAPI license notice

This app bundles or manages CLIProxyAPI, which is distributed under the MIT License. The CLIProxyAPI license text is included at:

```text
Sources/CLIProxyManagerApp/Resources/Licenses/CLIProxyAPI-LICENSE.txt
```

When distributing this app with CLIProxyAPI, keep the upstream CLIProxyAPI copyright notice and MIT permission notice in the app bundle and public release materials.

## Updating the bundled CLIProxyAPI binary

CLIProxyManager vendors the official macOS arm64 CLIProxyAPI release binary into:

```text
Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi
```

This vendoring flow changes the default binary shipped inside the app. It is still useful for release baselines, but day-to-day CLIProxyAPI updates can also be applied by the installed app through the in-app CLIProxyAPI binary updater.

Use the vendoring script with an upstream release version:

```zsh
scripts/vendor-cliproxyapi.sh 7.0.0
```

The script downloads `router-for-me/CLIProxyAPI` release assets from GitHub, verifies the archive against upstream `checksums.txt`, copies the archive's `cli-proxy-api` executable as `cliproxyapi`, and writes:

```text
Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json
```

After updating the binary, verify it is bundled by running:

```zsh
swift test --filter LicenseResourceTests/testCLIProxyAPIBinaryResourceIsBundled
```

Commit the updated binary and manifest together.

## Cutting an automatic-update release

Automatic-update releases require two signing materials in GitHub Secrets:

- `CLIPROXYMANAGER_CERTIFICATE_BASE64`: base64-encoded `.p12` export of the self-signed `cliproxymanager` code signing certificate, including its private key.
- `CLIPROXYMANAGER_CERTIFICATE_PASSWORD`: password for that `.p12` export.
- `SPARKLE_PRIVATE_KEY`: Sparkle EdDSA private key for signing `appcast.xml`.

The committed Sparkle public key lives in `Info.plist` as `SUPublicEDKey`. The private key and `.p12` certificate export must not be committed.

To create or export the Sparkle key pair, download the Sparkle 2.9.2 tarball and run `generate_keys`:

```zsh
mkdir -p build
curl -L -o build/Sparkle-2.9.2.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-2.9.2.tar.xz
tar -xf build/Sparkle-2.9.2.tar.xz -C build
build/Sparkle-2.9.2/bin/generate_keys -x build/sparkle_private_key.txt
```

If `generate_keys -x` creates a Keychain item whose account is the export file path, copy the same private key value into the canonical item instead of generating a new key:

```zsh
security add-generic-password \
  -U \
  -s "https://sparkle-project.org" \
  -a "com.woosublee.CLIProxyManager.sparkle.ed25519" \
  -l "Private key for signing Sparkle updates" \
  -D "private key" \
  -j "Public key (SUPublicEDKey value) for this key is:\n\n$(plutil -extract SUPublicEDKey raw Info.plist)" \
  -w "$(cat build/sparkle_private_key.txt)"
```

Local fallback tooling reads that canonical Keychain item automatically when `SPARKLE_PRIVATE_KEY` is unset. Do not commit `build/sparkle_private_key.txt`.

Before running the release workflow, update the version and build number in both `Info.plist` and `Makefile`. The workflow rejects releases when `make -s print-app-version`, `make -s print-build-number`, `make -s print-build-tag`, and the workflow input tag disagree.

Run the **Self-signed Release** GitHub Actions workflow with a new tag such as `v1.2.3`. Do not create the tag first; the workflow checks that the remote tag does not already exist, builds from the workflow commit, signs the app and DMG with the imported `cliproxymanager` certificate, generates `build/appcast.xml`, creates the tag, and uploads both release assets:

- `CLIProxyManager-<version>.dmg`
- `appcast.xml`

This CI release is self-signed and non-notarized. It keeps the existing Sparkle update path compatible with local self-signed releases, but it does not remove first-launch Gatekeeper warnings for brand-new installs. A Developer ID signed and notarized release path can be introduced later.

### Local fallback release

Local fallback releases still require a code signing identity named `cliproxymanager` in the local Keychain. Confirm it before cutting a fallback release:

```zsh
security find-identity -v -p codesigning | grep '"cliproxymanager"'
```

The fallback script does not create code signing certificates automatically. It validates the `v*` tag, requires the local `cliproxymanager` code signing identity, reads `CFBundleVersion` from `Info.plist`, builds and verifies the signed DMG, generates `build/appcast.xml` using the Keychain Sparkle private key, and uploads both release assets with the authenticated `gh` CLI:

```zsh
scripts/release-local.sh v1.2.3
```

By default, the fallback script does not clobber existing GitHub Release assets. Set `ALLOW_LOCAL_RELEASE_CLOBBER=1` only when you intentionally want to replace the DMG and appcast for an existing release.

Sparkle updates the app bundle, but it does not automatically overwrite the `/usr/local/bin/cliproxy-manager` helper. If a release changes the helper, reinstall it from CLIProxyManager after updating.

## Provider terms

CLIProxyManager is not an official product of Anthropic, OpenAI, Codex, or any other model provider. It should not be described as endorsed, certified, or guaranteed by those providers.

Users are responsible for using their own accounts and credentials in compliance with each provider's terms, usage policies, and account requirements.

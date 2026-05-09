# CLIProxyManager

CLIProxyManager is a macOS menu bar app for managing a local CLIProxyAPI server and the shell functions you use to launch Claude Code with different account and model backends.

It is designed for users who want one place to:

- Connect Claude OAuth and Codex OAuth profiles.
- Optionally use a Claude API key stored in macOS Keychain.
- Start, stop, and configure the bundled CLIProxyAPI server.
- Install convenient shell functions into `~/.zshrc`.
- Check account, server, and shell setup status from the app.

## Requirements

- macOS 13 or later.
- Claude Code installed and available on your machine.
- A Claude account, Codex/OpenAI OAuth account, or Claude API key depending on which shell function you want to use.
- zsh if you want the app to manage shell functions automatically.

## Releases

Release artifacts are distributed as ad-hoc signed, non-notarized DMGs on GitHub Releases.

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

## Provider terms

CLIProxyManager is not an official product of Anthropic, OpenAI, Codex, or any other model provider. It should not be described as endorsed, certified, or guaranteed by those providers.

Users are responsible for using their own accounts and credentials in compliance with each provider's terms, usage policies, and account requirements.

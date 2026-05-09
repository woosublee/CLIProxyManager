# CLIProxyManager

CLIProxyManager is a macOS app for managing local Claude Code launch profiles and a bundled CLIProxyAPI server from one user-facing interface.

## What it does

CLIProxyManager helps users run Claude Code with three shell functions:

- `cc`: uses the user's normal Claude Code subscription login.
- `ccapi`: uses a Claude API key stored in macOS Keychain.
- `ccodex`: routes through a local CLIProxyAPI server for OpenAI/Codex OAuth-backed usage.

The app is intended to make installation, diagnostics, shell function setup, and local server management easier for non-developer users.

## CLIProxyAPI license notice

This app bundles or manages CLIProxyAPI, which is distributed under the MIT License. The CLIProxyAPI license text is included at `Sources/CLIProxyManagerApp/Resources/Licenses/CLIProxyAPI-LICENSE.txt`.

When distributing this app with CLIProxyAPI, keep the upstream CLIProxyAPI copyright notice and MIT permission notice in the app bundle and public release materials.

## Provider terms

CLIProxyManager is not an official product of Anthropic, OpenAI, Codex, or any other model provider. It should not be described as endorsed, certified, or guaranteed by those providers.

Users are responsible for using their own accounts and credentials in compliance with each provider's terms, usage policies, and account requirements.

---
name: verify
description: Use when verifying CLIProxyManager runtime behavior through the built app, especially shell function generation, helper path routing, bundled app execution, or DMG-style app bundle flows.
---

# CLIProxyManager Runtime Verification

## Overview

Verify through the built `.app` or generated shell functions, not by calling internal Swift APIs. Be careful: the app uses `FileManager.default.homeDirectoryForCurrentUser`, so setting `HOME=...` is not a safe sandbox on macOS.

## Safe Surfaces

| Surface | Use for | Command pattern |
|---|---|---|
| Swift tests | Regression coverage only | `swift test` |
| App bundle | Packaging/helper presence | `make bundle CONFIGURATION=release BUILD_DIR="$CLAUDE_JOB_DIR/tmp/<name>"` |
| Existing installed app | User-facing shell function behavior | `zsh -lc 'source ~/.cliproxy-manager/functions.zsh; <command> --version'` |

## Shell Function Verification

1. Build a release bundle into `$CLAUDE_JOB_DIR/tmp`.
2. Confirm `CLIProxyManager.app/Contents/Helpers/cliproxy-manager` is executable.
3. Do **not** run the app with a fake `HOME` expecting isolation; it can still write to the real `~/.cliproxy-manager`.
4. If a live shell function is already configured, verify the real surface by sourcing `~/.cliproxy-manager/functions.zsh` and running the command with a harmless flag such as `--version`.
5. If runtime app launch is required, first back up `~/.cliproxy-manager/functions.zsh` and `~/.zshrc`, then restore them before reporting.

## Common Mistakes

- Assuming `HOME=$tmp` changes `FileManager.homeDirectoryForCurrentUser`.
- Treating unit tests as runtime verification.
- Forgetting that app initialization may rewrite `~/.cliproxy-manager/functions.zsh` and `.zshrc`.

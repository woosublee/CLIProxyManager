#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi"

if [[ $# -gt 0 ]]; then
  SOURCE="$1"
else
  SOURCE="$(command -v cliproxyapi || true)"
fi

if [[ -z "$SOURCE" || ! -f "$SOURCE" ]]; then
  echo "cliproxyapi binary not found. Pass the binary path explicitly." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$SOURCE" "$DEST"
chmod +x "$DEST"

echo "Vendored CLIProxyAPI binary to $DEST"

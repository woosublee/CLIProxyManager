#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CLIPROXY_MANAGER_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/cliproxyapi-artifact-lib.sh
source "$SCRIPT_DIR/cliproxyapi-artifact-lib.sh"

MANIFEST="$REPO_ROOT/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json"
CACHE_ROOT="$REPO_ROOT/.build/cliproxyapi"
OUTPUT=''
OFFLINE=0
PRUNE_CACHE=0

usage() {
  cat <<'EOF'
Usage: scripts/resolve-bundled-cliproxyapi.sh [--manifest PATH] [--cache-root PATH] [--output PATH] [--offline] [--prune-cache]

Resolves the CLIProxyAPI binary pinned by the committed manifest. Cached and
downloaded artifacts are verified against the manifest before use. --offline
allows only an already verified cache entry. --prune-cache removes stale
hash-addressed entries while preserving the currently pinned artifact.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

atomic_copy() {
  local source="$1"
  local destination="$2"
  local directory temporary

  directory="$(dirname "$destination")"
  mkdir -p "$directory"
  temporary="$directory/.${destination##*/}.tmp.$$"
  rm -f "$temporary"
  cp "$source" "$temporary"
  chmod 755 "$temporary"
  mv -f "$temporary" "$destination"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || fail '--manifest requires a path'
      MANIFEST="$2"
      shift 2
    ;;
    --cache-root)
      [[ $# -ge 2 ]] || fail '--cache-root requires a path'
      CACHE_ROOT="$2"
      shift 2
    ;;
    --output)
      [[ $# -ge 2 ]] || fail '--output requires a path'
      OUTPUT="$2"
      shift 2
    ;;
    --offline)
      OFFLINE=1
      shift
    ;;
    --prune-cache)
      PRUNE_CACHE=1
      shift
    ;;
    --help|-h)
      usage
      exit 0
    ;;
    *)
      fail "Unknown argument: $1"
    ;;
  esac
done

cliproxyapi_load_manifest "$MANIFEST" || fail 'Unable to read bundled CLIProxyAPI manifest'
cliproxyapi_manifest_is_valid || fail 'Bundled CLIProxyAPI manifest is invalid'

if [[ "$PRUNE_CACHE" -eq 1 ]]; then
  if [[ -d "$CACHE_ROOT" ]]; then
    for entry in "$CACHE_ROOT"/*; do
      [[ -d "$entry" ]] || continue
      entry_name="${entry##*/}"
      cliproxyapi_is_sha256 "$entry_name" || continue
      [[ "$entry_name" == "$CLIPROXYAPI_MANIFEST_BINARY_SHA256" ]] || rm -rf "$entry"
    done
  fi
  exit 0
fi

cache_binary="$CACHE_ROOT/$CLIPROXYAPI_MANIFEST_BINARY_SHA256/cliproxyapi"
resolved_binary=''
if [[ -f "$cache_binary" ]]; then
  if cliproxyapi_binary_matches_manifest "$cache_binary"; then
    resolved_binary="$cache_binary"
  elif [[ "$OFFLINE" -eq 1 ]]; then
    fail 'Bundled CLIProxyAPI cache verification failed in offline mode'
  fi
elif [[ "$OFFLINE" -eq 1 ]]; then
  fail 'Bundled CLIProxyAPI cache is unavailable in offline mode'
fi

if [[ -z "$resolved_binary" ]]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cliproxyapi-resolve.XXXXXX")"
  cleanup() { rm -rf "$work_dir"; }
  trap cleanup EXIT

  archive="$work_dir/$CLIPROXYAPI_MANIFEST_ASSET"
  if ! "${CLIPROXYAPI_CURL:-/usr/bin/curl}" -fsSL \
    --connect-timeout "${CLIPROXYAPI_CONNECT_TIMEOUT_SECONDS:-15}" \
    --max-time "${CLIPROXYAPI_MAX_TIME_SECONDS:-600}" \
    "$CLIPROXYAPI_MANIFEST_SOURCE" -o "$archive"; then
    fail 'Unable to download the pinned CLIProxyAPI archive'
  fi
  [[ "$(cliproxyapi_sha256_file "$archive")" == "$CLIPROXYAPI_MANIFEST_ARCHIVE_SHA256" ]] ||
    fail 'Pinned CLIProxyAPI archive checksum mismatch'

  extract_dir="$work_dir/extract"
  mkdir -p "$extract_dir"
  if ! "${CLIPROXYAPI_TAR:-/usr/bin/tar}" -xzf "$archive" -C "$extract_dir"; then
    fail 'Unable to extract the pinned CLIProxyAPI archive'
  fi
  extracted_binary="$extract_dir/$CLIPROXYAPI_MANIFEST_ARCHIVE_PATH"
  cliproxyapi_binary_matches_manifest "$extracted_binary" ||
    fail 'Pinned CLIProxyAPI binary does not match the manifest'

  cache_directory="$(dirname "$cache_binary")"
  mkdir -p "$cache_directory"
  atomic_copy "$extracted_binary" "$cache_binary"
  resolved_binary="$cache_binary"
fi

if [[ -n "$OUTPUT" ]]; then
  atomic_copy "$resolved_binary" "$OUTPUT"
fi

printf '%s\n' "$resolved_binary"

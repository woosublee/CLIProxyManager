#!/usr/bin/env bash
# Prints the SwiftPM scratch path for a checkout under SWIFT_SCRATCH_ROOT.
#
# Make splits values on whitespace, so the root is validated here, where paths
# keep their spaces. The root and checkout are resolved physically, so a symlink
# cannot alias the checkout, and each checkout gets its own subdirectory named
# after it plus a hash of its physical path.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail 'Usage: scripts/resolve-swift-scratch-path.sh <scratch-root> <checkout>'

root="$1"
checkout="$2"

case "$root" in
  '~') root="$HOME" ;;
  '~/'*) root="$HOME/${root#\~/}" ;;
esac
[[ "$root" == /* ]] ||
  fail "SWIFT_SCRATCH_ROOT must be an absolute path or start with ~/, for example \$HOME/Library/Caches/CLIProxyManager"

# Resolve the longest existing prefix physically; the rest may not exist yet.
physical_path() {
  local path="$1"
  local rest=''
  while [[ ! -d "$path" ]]; do
    rest="/$(basename "$path")$rest"
    path="$(dirname "$path")"
  done
  printf '%s%s' "$(cd -P "$path" && pwd)" "$rest"
}

while [[ "$root" == */ && "$root" != / ]]; do
  root="${root%/}"
done
root="$(physical_path "$root")"
checkout="$(cd -P "$checkout" && pwd)" || fail "Unable to resolve checkout: $2"

case "$root/" in
  "$checkout/"*) fail 'SWIFT_SCRATCH_ROOT must be outside the checkout so SwiftPM output leaves the synced folder' ;;
esac

key="$(printf '%s' "$checkout" | shasum -a 256 | cut -c1-12)"
printf '%s/%s-%s\n' "${root%/}" "$(basename "$checkout")" "$key"

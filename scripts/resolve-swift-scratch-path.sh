#!/usr/bin/env bash
# Prints the SwiftPM scratch path for a checkout under SWIFT_SCRATCH_ROOT.
#
# Make splits values on whitespace, so the root is validated here, where paths
# keep their spaces. The existing part of the root is resolved by the kernel
# (cd -P), so symlinks, .. and case-insensitive spellings mean what the file
# system says they mean. The checkout is compared by device and inode, not by
# spelling, and each checkout gets its own subdirectory named after it plus a
# key derived from that identity.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail 'Usage: scripts/resolve-swift-scratch-path.sh <scratch-root> <checkout>'

root="$1"
checkout="$2"

# Surrounding whitespace is a typo, not part of the intended directory name.
root="${root#"${root%%[![:space:]]*}"}"
root="${root%"${root##*[![:space:]]}"}"

case "$root" in
  '~') root="$HOME" ;;
  '~/'*) root="$HOME/${root#\~/}" ;;
esac
[[ "$root" == /* ]] ||
  fail "SWIFT_SCRATCH_ROOT must be an absolute path or start with ~/, for example \$HOME/Library/Caches/CLIProxyManager"

file_identity() {
  stat -f '%d:%i' "$1"
}

# Split the root into its longest existing prefix and the part still to create.
prefix="$root"
rest=''
while [[ ! -e "$prefix" ]]; do
  [[ ! -L "$prefix" ]] || fail "SWIFT_SCRATCH_ROOT goes through a broken symbolic link: $prefix"
  rest="/${prefix##*/}$rest"
  prefix="${prefix%/*}"
  [[ -n "$prefix" ]] || prefix='/'
done
[[ -d "$prefix" ]] || fail "SWIFT_SCRATCH_ROOT must be a directory path, but $prefix is not a directory"
case "$rest/" in
  */../* | */./*) fail "SWIFT_SCRATCH_ROOT must not use . or .. after the part that exists: $rest" ;;
esac
resolved_prefix="$(cd -P "$prefix" && pwd)" || fail "Unable to resolve SWIFT_SCRATCH_ROOT component: $prefix"

checkout="$(cd -P "$checkout" && pwd)" || fail "Unable to resolve checkout: $2"
checkout_identity="$(file_identity "$checkout")"

# The new directories in $rest do not exist yet, so the root is inside the
# checkout exactly when its existing prefix is the checkout or below it.
ancestor="$resolved_prefix"
while :; do
  [[ "$(file_identity "$ancestor")" != "$checkout_identity" ]] ||
    fail 'SWIFT_SCRATCH_ROOT must be outside the checkout so SwiftPM output leaves the synced folder'
  [[ "$ancestor" != / ]] || break
  ancestor="$(cd -P "$ancestor/.." && pwd)"
done

key="$(printf '%s' "$checkout_identity" | shasum -a 256 | cut -c1-12)"
root_path="${resolved_prefix%/}${rest//\/\///}"
printf '%s/%s-%s\n' "${root_path%/}" "${checkout##*/}" "$key"

#!/usr/bin/env bash
# Copies the CLIProxyManagerApp SwiftPM resource bundle's contents into the app
# bundle's Resources directory.
#
# The app looks resources up in Bundle.main, so the resource bundle is flattened
# into Contents/Resources instead of shipping as a nested .bundle. The native
# build engine writes a flat resource bundle; swiftbuild writes a macOS bundle
# whose resources live under Contents/Resources next to its Info.plist and
# signature, which must not reach the app.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail 'Usage: scripts/install-swiftpm-resources.sh <swift-bin-path> <app-resources-dir>'

bin_path="$1"
resources_dir="$2"
[[ -d "$resources_dir" ]] || fail "Missing app resources directory: $resources_dir"

shopt -s nullglob
bundles=("$bin_path"/*_CLIProxyManagerApp.bundle)
shopt -u nullglob
[[ ${#bundles[@]} -gt 0 ]] || fail "Missing SwiftPM resource bundle in $bin_path"
[[ ${#bundles[@]} -eq 1 ]] || fail "Expected one CLIProxyManagerApp resource bundle in $bin_path, found ${#bundles[@]}"
bundle="${bundles[0]}"
[[ -d "$bundle" ]] || fail "SwiftPM resource bundle is not a directory: $bundle"

# swiftbuild writes a macOS bundle with Contents/Info.plist; a flat bundle has none.
# App resources must not use a top-level Contents folder: verify-app-structure.sh
# rejects Resources/Contents as a nested bundle.
if [[ -f "$bundle/Contents/Info.plist" ]]; then
  [[ -d "$bundle/Contents/Resources" ]] ||
    fail "SwiftPM resource bundle has Contents/Info.plist without Contents/Resources: $bundle"
  source_dir="$bundle/Contents/Resources"
else
  source_dir="$bundle"
fi

ditto --norsrc --noextattr "$source_dir" "$resources_dir" ||
  fail "Unable to copy SwiftPM resources from $source_dir"

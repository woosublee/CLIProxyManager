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

BUNDLE_NAME='CLIProxyManager_CLIProxyManagerApp.bundle'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail 'Usage: scripts/install-swiftpm-resources.sh <swift-bin-path> <app-resources-dir>'

bin_path="$1"
resources_dir="$2"
bundle="$bin_path/$BUNDLE_NAME"

[[ -d "$bundle" ]] || fail "Missing SwiftPM resource bundle: $bundle"
[[ -d "$resources_dir" ]] || fail "Missing app resources directory: $resources_dir"

if [[ -e "$bundle/Contents" || -L "$bundle/Contents" ]]; then
  [[ -d "$bundle/Contents/Resources" ]] ||
    fail "SwiftPM resource bundle has Contents without Contents/Resources: $bundle"
  source_dir="$bundle/Contents/Resources"
else
  source_dir="$bundle"
fi

ditto --norsrc --noextattr "$source_dir" "$resources_dir" ||
  fail "Unable to copy SwiftPM resources from $source_dir"

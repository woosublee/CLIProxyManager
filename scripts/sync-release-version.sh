#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-version-lib.sh"

mode="${1:-sync}"
[[ $# -le 1 ]] || release_fail 'Usage: scripts/sync-release-version.sh [--check]'
[[ "$mode" == 'sync' || "$mode" == '--check' ]] || release_fail 'Usage: scripts/sync-release-version.sh [--check]'

ARTIFACT_CHANNEL=official
unset DEVELOPMENT_VERSION DEVELOPMENT_BUILD_NUMBER
release_load_identity "$REPO_ROOT"
PLUTIL_BIN="$(release_plutil)"
plist="$REPO_ROOT/Info.plist"
actual_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)"
actual_build="$($PLUTIL_BIN -extract CFBundleVersion raw "$plist" 2>/dev/null || true)"
display_version='invalid'
display_build='invalid'
[[ "$actual_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && display_version="$actual_version"
[[ "$actual_build" =~ ^[1-9][0-9]*$ ]] && display_build="$actual_build"

if [[ "$mode" == '--check' ]]; then
  status=0
  if [[ "$actual_version" != "$RELEASE_VERSION" ]]; then
    printf 'ERROR: Info.plist version mismatch: expected %s, actual %s\n' "$RELEASE_VERSION" "$display_version" >&2
    status=1
  fi
  if [[ "$actual_build" != "$RELEASE_BUILD" ]]; then
    printf 'ERROR: Info.plist build mismatch: expected %s, actual %s\n' "$RELEASE_BUILD" "$display_build" >&2
    status=1
  fi
  if [[ $status -ne 0 ]]; then
    printf 'ERROR: Run scripts/sync-release-version.sh to update the generated mirror\n' >&2
  fi
  exit "$status"
fi

staged="$(mktemp "$REPO_ROOT/.Info.plist.XXXXXX" 2>/dev/null)" || release_fail 'Unable to stage the Info.plist mirror'
cleanup() { rm -f "$staged" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cp -p "$plist" "$staged" >/dev/null 2>&1 || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -replace CFBundleShortVersionString -string "$RELEASE_VERSION" "$staged" >/dev/null 2>&1 || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -replace CFBundleVersion -string "$RELEASE_BUILD" "$staged" >/dev/null 2>&1 || release_fail 'Unable to update the Info.plist mirror'
$PLUTIL_BIN -lint "$staged" >/dev/null 2>&1 || release_fail 'Unable to validate the Info.plist mirror'
staged_version="$($PLUTIL_BIN -extract CFBundleShortVersionString raw "$staged" 2>/dev/null)" || release_fail 'Unable to validate the Info.plist mirror'
staged_build="$($PLUTIL_BIN -extract CFBundleVersion raw "$staged" 2>/dev/null)" || release_fail 'Unable to validate the Info.plist mirror'
[[ "$staged_version" == "$RELEASE_VERSION" ]] || release_fail 'Unable to validate the Info.plist mirror'
[[ "$staged_build" == "$RELEASE_BUILD" ]] || release_fail 'Unable to validate the Info.plist mirror'
release_atomic_replace "$staged" "$plist" >/dev/null 2>&1 || release_fail 'Unable to replace the Info.plist mirror'
trap - EXIT

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

CANONICAL_BUNDLE_ID='com.woosublee.CLIProxyManager'
CANONICAL_APP_NAME='CLIProxyManager'

usage() {
  printf '%s\n' 'Usage: scripts/verify-app-structure.sh --app APP --version X.Y.Z --build POSITIVE_INT --channel development|official'
}

invalid_arguments() {
  printf 'Invalid checker arguments\n' >&2
  exit 1
}

structure_failure() {
  printf 'App structure validation failed: %s\n' "$1" >&2
  exit 1
}

is_sha256() {
  [[ ${#1} -eq 64 && "$1" =~ ^[0-9A-Fa-f]+$ ]]
}

app=''
version=''
build=''
channel=''
app_set=0
version_set=0
build_set=0
channel_set=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 && "$app_set" -eq 0 ]] || invalid_arguments
      app="$2"
      app_set=1
      shift 2
    ;;
    --version)
      [[ $# -ge 2 && "$version_set" -eq 0 ]] || invalid_arguments
      version="$2"
      version_set=1
      shift 2
    ;;
    --build)
      [[ $# -ge 2 && "$build_set" -eq 0 ]] || invalid_arguments
      build="$2"
      build_set=1
      shift 2
    ;;
    --channel)
      [[ $# -ge 2 && "$channel_set" -eq 0 ]] || invalid_arguments
      channel="$2"
      channel_set=1
      shift 2
    ;;
    --help|-h)
      usage
      exit 0
    ;;
    *)
      invalid_arguments
    ;;
  esac
done

[[ "$app_set" -eq 1 && -n "$app" && "$version_set" -eq 1 && "$build_set" -eq 1 && "$channel_set" -eq 1 ]] ||
  invalid_arguments
release_is_stable_semver "$version" || invalid_arguments
release_is_positive_int64 "$build" || invalid_arguments
case "$channel" in
  development|official) ;;
  *) invalid_arguments ;;
esac

contents="$app/Contents"
resources="$contents/Resources"
info_plist="$contents/Info.plist"

[[ -d "$app" && -d "$contents" ]] || structure_failure 'app bundle'
[[ -f "$info_plist" ]] || structure_failure 'Info.plist'

bundle_identifier="$(release_plist_value CFBundleIdentifier "$info_plist")"
bundle_name="$(release_plist_value CFBundleName "$info_plist")"
display_name="$(release_plist_value CFBundleDisplayName "$info_plist")"
bundle_executable="$(release_plist_value CFBundleExecutable "$info_plist")"
bundle_icon_file="$(release_plist_value CFBundleIconFile "$info_plist")"
bundle_version="$(release_plist_value CFBundleShortVersionString "$info_plist")"
bundle_build="$(release_plist_value CFBundleVersion "$info_plist")"

[[ "$bundle_identifier" == "$CANONICAL_BUNDLE_ID" &&
   "$bundle_name" == "$CANONICAL_APP_NAME" &&
   "$display_name" == "$CANONICAL_APP_NAME" &&
   "$bundle_executable" == "$CANONICAL_APP_NAME" &&
   "$bundle_icon_file" == "$CANONICAL_APP_NAME" &&
   "$bundle_version" == "$version" &&
   "$bundle_build" == "$build" ]] || structure_failure 'metadata'

release_channel_marker="$(release_plist_value CLIProxyManagerReleaseChannel "$info_plist")"
case "$channel" in
  development)
    [[ "$release_channel_marker" == 'development' ]] || structure_failure 'release channel marker'
  ;;
  official)
    [[ -z "$release_channel_marker" ]] || structure_failure 'release channel marker'
  ;;
esac

[[ -f "$contents/MacOS/CLIProxyManager" && -x "$contents/MacOS/CLIProxyManager" ]] ||
  structure_failure 'main executable'
[[ -f "$contents/Helpers/cpm" && -x "$contents/Helpers/cpm" &&
   -f "$contents/Helpers/cliproxy-manager" && -x "$contents/Helpers/cliproxy-manager" ]] ||
  structure_failure 'helper executables'
[[ -f "$resources/CLIProxyManager.icns" ]] || structure_failure 'icon'
[[ -x "$contents/Frameworks/Sparkle.framework/Autoupdate" ]] ||
  structure_failure 'Sparkle Autoupdate'
[[ -d "$contents/Frameworks/Sparkle.framework/Updater.app" ]] ||
  structure_failure 'Sparkle Updater'
[[ ! -e "$resources/cpm" && ! -L "$resources/cpm" &&
   ! -e "$resources/cliproxy-manager" && ! -L "$resources/cliproxy-manager" ]] ||
  structure_failure 'unexpected resource helper'

proxy_binary="$resources/cliproxyapi/cliproxyapi"
proxy_manifest="$resources/cliproxyapi/cliproxyapi.manifest.json"
[[ -f "$proxy_manifest" &&
   -f "$resources/Licenses/CLIProxyAPI-LICENSE.txt" &&
   -f "$resources/ProviderImages/claude.png" &&
   -f "$resources/ProviderImages/codex.png" ]] ||
  structure_failure 'resource contents'
[[ -f "$proxy_binary" && -x "$proxy_binary" ]] ||
  structure_failure 'bundled proxy binary'

expected_sha256="$(release_plist_value vendoredBinarySha256 "$proxy_manifest")"
actual_sha256="$(shasum -a 256 "$proxy_binary" 2>/dev/null | awk '{print $1}')"
is_sha256 "$expected_sha256" && [[ "$actual_sha256" == "$expected_sha256" ]] ||
  structure_failure 'bundled proxy binary checksum'

expected_size="$(release_plist_value vendoredBinarySizeBytes "$proxy_manifest")"
actual_size="$(wc -c < "$proxy_binary" 2>/dev/null | tr -d '[:space:]')"
release_is_positive_integer "$expected_size" && [[ "$actual_size" == "$expected_size" ]] ||
  structure_failure 'bundled proxy binary size'

printf 'App structure verification passed\n'

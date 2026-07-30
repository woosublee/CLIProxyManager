#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

PLUTIL_BIN="$(release_plutil)"
HDIUTIL="${HDIUTIL:-/usr/bin/hdiutil}"
source_plist=''
app_bundle=''
dmg_file=''
appcast_file=''
provenance_file=''
official=0
artifact_count=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-plist)
      [[ $# -ge 2 ]] || release_fail 'Missing value for --source-plist'
      source_plist="$2"
      artifact_count=$((artifact_count + 1))
      shift 2
      ;;
    --app)
      [[ $# -ge 2 ]] || release_fail 'Missing value for --app'
      app_bundle="$2"
      artifact_count=$((artifact_count + 1))
      shift 2
      ;;
    --dmg)
      [[ $# -ge 2 ]] || release_fail 'Missing value for --dmg'
      dmg_file="$2"
      artifact_count=$((artifact_count + 1))
      shift 2
      ;;
    --appcast)
      [[ $# -ge 2 ]] || release_fail 'Missing value for --appcast'
      appcast_file="$2"
      artifact_count=$((artifact_count + 1))
      shift 2
      ;;
    --provenance)
      [[ $# -ge 2 ]] || release_fail 'Missing value for --provenance'
      provenance_file="$2"
      artifact_count=$((artifact_count + 1))
      shift 2
      ;;
    --official)
      official=1
      shift
      ;;
    *)
      release_fail 'Unknown option'
      ;;
  esac
done

[[ "$artifact_count" -gt 0 ]] || release_fail 'At least one release artifact is required'

if [[ "$official" -eq 1 ]]; then
  if [[ "${ARTIFACT_CHANNEL:-official}" == 'development' ]] ||
     [[ -n "${DEVELOPMENT_VERSION:-}" ]] ||
     [[ -n "${DEVELOPMENT_BUILD_NUMBER:-}" ]]; then
    release_fail 'Official release verification cannot use development identity overrides'
  fi
  ARTIFACT_CHANNEL=official
fi

release_load_identity "$REPO_ROOT"

safe_version_actual() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'missing\n'
  elif [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf 'invalid\n'
  fi
}

safe_build_actual() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'missing\n'
  elif [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$value"
  else
    printf 'invalid\n'
  fi
}

safe_tag_actual() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'missing\n'
  elif [[ "$value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf 'invalid\n'
  fi
}

safe_dmg_name_actual() {
  local value="$1"
  if [[ "$value" =~ ^CLIProxyManager-[0-9]+\.[0-9]+\.[0-9]+(-development)?\.dmg$ ]]; then
    printf '%s\n' "$value"
  else
    printf 'invalid\n'
  fi
}

plist_value() {
  local key="$1"
  local plist="$2"
  "$PLUTIL_BIN" -extract "$key" raw "$plist" 2>/dev/null || true
}

verify_plist_channel() {
  local logical_name="$1"
  local plist="$2"
  local require_development="$3"
  local actual_channel
  actual_channel="$(plist_value CLIProxyManagerReleaseChannel "$plist")"

  if [[ "$official" -eq 1 && "$actual_channel" == 'development' ]]; then
    if [[ "$logical_name" == 'built app' ]]; then
      release_fail 'official release cannot use a development app artifact'
    fi
    release_fail "official release cannot use a development $logical_name artifact"
  fi

  if [[ "$RELEASE_CHANNEL" == 'development' && "$require_development" -eq 1 && "$actual_channel" != 'development' ]]; then
    release_fail "$logical_name release channel mismatch: expected development, actual missing"
  fi
}

verify_plist_identity() {
  local logical_name="$1"
  local plist="$2"
  local require_development="$3"
  local actual_version actual_build display_version display_build
  actual_version="$(plist_value CFBundleShortVersionString "$plist")"
  actual_build="$(plist_value CFBundleVersion "$plist")"
  display_version="$(safe_version_actual "$actual_version")"
  display_build="$(safe_build_actual "$actual_build")"

  [[ "$actual_version" == "$RELEASE_VERSION" ]] ||
    release_fail "$logical_name version mismatch: expected $RELEASE_VERSION, actual $display_version"
  [[ "$actual_build" == "$RELEASE_BUILD" ]] ||
    release_fail "$logical_name build mismatch: expected $RELEASE_BUILD, actual $display_build"
  verify_plist_channel "$logical_name" "$plist" "$require_development"
}

verify_appcast() {
  local appcast="$1"
  release_read_appcast_identity "$appcast"
  [[ "$APPCAST_VERSION" == "$RELEASE_VERSION" ]] ||
    release_fail "appcast version mismatch: expected $RELEASE_VERSION, actual $APPCAST_VERSION"
  [[ "$APPCAST_BUILD" == "$RELEASE_BUILD" ]] ||
    release_fail "appcast build mismatch: expected $RELEASE_BUILD, actual $APPCAST_BUILD"
  [[ "$APPCAST_TAG" == "$RELEASE_TAG" ]] ||
    release_fail "appcast tag mismatch: expected $RELEASE_TAG, actual $APPCAST_TAG"
  [[ "$APPCAST_DMG_NAME" == "$RELEASE_DMG_NAME" ]] ||
    release_fail "appcast DMG filename mismatch: expected $RELEASE_DMG_NAME, actual $APPCAST_DMG_NAME"
}

verify_provenance() {
  local provenance="$1"
  local actual_version actual_build actual_tag actual_trust
  local display_version display_build display_tag display_trust
  actual_version="$(plist_value current.version "$provenance")"
  actual_build="$(plist_value current.build "$provenance")"
  actual_tag="$(plist_value current.tag "$provenance")"
  display_version="$(safe_version_actual "$actual_version")"
  display_build="$(safe_build_actual "$actual_build")"
  display_tag="$(safe_tag_actual "$actual_tag")"

  [[ "$actual_version" == "$RELEASE_VERSION" ]] ||
    release_fail "provenance version mismatch: expected $RELEASE_VERSION, actual $display_version"
  [[ "$actual_build" == "$RELEASE_BUILD" ]] ||
    release_fail "provenance build mismatch: expected $RELEASE_BUILD, actual $display_build"
  [[ "$actual_tag" == "$RELEASE_TAG" ]] ||
    release_fail "provenance tag mismatch: expected $RELEASE_TAG, actual $display_tag"

  if [[ "$official" -eq 1 ]]; then
    actual_trust="$(plist_value trust "$provenance")"
    case "$actual_trust" in
      official|local-fallback) ;;
      '')
        release_fail 'provenance trust mismatch: expected official or local-fallback, actual missing'
        ;;
      *)
        if [[ "$actual_trust" =~ ^[a-z][a-z-]*$ ]]; then
          display_trust="$actual_trust"
        else
          display_trust='invalid'
        fi
        release_fail "provenance trust mismatch: expected official or local-fallback, actual $display_trust"
        ;;
    esac
  fi
}

verify_dmg() (
  local dmg="$1"
  local actual_name mount_dir mounted
  actual_name="$(basename "$dmg")"

  if [[ "$official" -eq 1 && "$actual_name" == *-development.dmg ]]; then
    release_fail 'official release cannot use a development DMG artifact'
  fi
  [[ "$actual_name" == "$RELEASE_DMG_NAME" ]] ||
    release_fail "DMG filename mismatch: expected $RELEASE_DMG_NAME, actual $(safe_dmg_name_actual "$actual_name")"

  mount_dir="$(mktemp -d /tmp/cliproxymanager-dmg.XXXXXX)" ||
    release_fail 'Unable to create DMG mount directory'
  mounted=0
  cleanup() {
    if [[ "$mounted" -eq 1 ]]; then
      "$HDIUTIL" detach "$mount_dir" >/dev/null 2>&1 ||
        "$HDIUTIL" detach -force "$mount_dir" >/dev/null 2>&1 || true
    fi
    rm -rf "$mount_dir"
  }
  trap cleanup EXIT

  if ! "$HDIUTIL" attach "$dmg" -readonly -nobrowse -quiet -mountpoint "$mount_dir" >/dev/null 2>&1; then
    release_fail 'Unable to mount DMG'
  fi
  mounted=1
  verify_plist_identity 'DMG app' "$mount_dir/CLIProxyManager.app/Contents/Info.plist" 1
)

if [[ -n "$source_plist" ]]; then
  verify_plist_identity 'source Info.plist' "$source_plist" 0
fi
if [[ -n "$app_bundle" ]]; then
  verify_plist_identity 'built app' "$app_bundle/Contents/Info.plist" 1
fi
if [[ -n "$dmg_file" ]]; then
  verify_dmg "$dmg_file"
fi
if [[ -n "$appcast_file" ]]; then
  verify_appcast "$appcast_file"
fi
if [[ -n "$provenance_file" ]]; then
  verify_provenance "$provenance_file"
fi

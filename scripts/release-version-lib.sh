#!/usr/bin/env bash

release_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

release_repo_root() {
  local script_path="$1"
  cd "$(dirname "$script_path")/.." && pwd
}

release_atomic_replace() {
  local staged="$1"
  local destination="$2"
  mv -f "$staged" "$destination"
}

release_plutil() {
  printf '%s\n' "${PLUTIL:-/usr/bin/plutil}"
}

release_load_identity() {
  local repo_root="$1"
  local metadata="$repo_root/release/version.json"
  local metadata_xml key_count version_type build_type

  metadata_xml="$(mktemp /tmp/cliproxymanager-version.XXXXXX.xml)" || return 1
  if ! plutil -convert xml1 -o "$metadata_xml" "$metadata" >/dev/null; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json must be valid JSON'
    return 1
  fi

  if [[ "$(xmllint --xpath 'name(/plist/*[1])' "$metadata_xml" 2>/dev/null)" != 'dict' ]]; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json root must be an object'
    return 1
  fi

  key_count="$(xmllint --xpath 'count(/plist/dict/key)' "$metadata_xml")"
  if [[ "$key_count" != '2' ]] ||
     [[ "$(xmllint --xpath 'count(/plist/dict/key[text()="version"])' "$metadata_xml")" != '1' ]] ||
     [[ "$(xmllint --xpath 'count(/plist/dict/key[text()="build"])' "$metadata_xml")" != '1' ]]; then
    rm -f "$metadata_xml"
    release_fail 'release/version.json must contain exactly version and build'
    return 1
  fi
  rm -f "$metadata_xml"

  version_type="$(plutil -type version "$metadata" 2>/dev/null || true)"
  build_type="$(plutil -type build "$metadata" 2>/dev/null || true)"
  [[ "$version_type" == 'string' ]] || release_fail 'version must be a JSON string' || return 1
  [[ "$build_type" == 'integer' ]] || release_fail 'build must be a JSON integer' || return 1

  RELEASE_VERSION="$(plutil -extract version raw "$metadata")"
  RELEASE_BUILD="$(plutil -extract build raw "$metadata")"
  [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    release_fail 'version must use stable SemVer x.y.z without whitespace, prerelease, or build metadata' || return 1
  [[ "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]] ||
    release_fail 'build must be a positive integer' || return 1

  RELEASE_CHANNEL="${ARTIFACT_CHANNEL:-official}"
  case "$RELEASE_CHANNEL" in
    official)
      [[ -z "${DEVELOPMENT_VERSION:-}" ]] || release_fail 'DEVELOPMENT_VERSION is only valid for development artifacts' || return 1
      [[ -z "${DEVELOPMENT_BUILD_NUMBER:-}" ]] || release_fail 'DEVELOPMENT_BUILD_NUMBER is only valid for development artifacts' || return 1
      RELEASE_TAG="v$RELEASE_VERSION"
      RELEASE_DMG_NAME="CLIProxyManager-$RELEASE_VERSION.dmg"
      ;;
    development)
      [[ -n "${DEVELOPMENT_VERSION:-}" ]] || release_fail 'DEVELOPMENT_VERSION is required for development artifacts' || return 1
      [[ -n "${DEVELOPMENT_BUILD_NUMBER:-}" ]] || release_fail 'DEVELOPMENT_BUILD_NUMBER is required for development artifacts' || return 1
      [[ "$DEVELOPMENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail 'development version must use stable SemVer x.y.z' || return 1
      [[ "$DEVELOPMENT_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || release_fail 'development build must be a positive integer' || return 1
      RELEASE_VERSION="$DEVELOPMENT_VERSION"
      RELEASE_BUILD="$DEVELOPMENT_BUILD_NUMBER"
      RELEASE_TAG=''
      RELEASE_DMG_NAME="CLIProxyManager-$RELEASE_VERSION-development.dmg"
      ;;
    *)
      release_fail 'ARTIFACT_CHANNEL must be official or development'
      return 1
      ;;
  esac

  RELEASE_DMG_PATH="build/$RELEASE_DMG_NAME"
  RELEASE_APPCAST_PATH='build/appcast.xml'
}

release_read_appcast_identity() {
  local appcast="$1"
  local xml="${XMLLINT:-/usr/bin/xmllint}"
  local item_version enclosure_version item_build enclosure_build enclosure_url

  "$xml" --noout "$appcast" >/dev/null 2>&1 || release_fail 'appcast.xml must be valid XML' || return 1
  item_build="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="version"])[1])' "$appcast" 2>/dev/null)" ||
    release_fail 'Unable to read build from appcast.xml' || return 1
  item_version="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' "$appcast" 2>/dev/null)" ||
    release_fail 'Unable to read version from appcast.xml' || return 1
  enclosure_build="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="version"])' "$appcast" 2>/dev/null)" ||
    release_fail 'Unable to read enclosure build from appcast.xml' || return 1
  enclosure_version="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@*[local-name()="shortVersionString"])' "$appcast" 2>/dev/null)" ||
    release_fail 'Unable to read enclosure version from appcast.xml' || return 1
  enclosure_url="$($xml --xpath 'string((//*[local-name()="item"]/*[local-name()="enclosure"])[1]/@url)' "$appcast" 2>/dev/null)" ||
    release_fail 'Unable to read enclosure URL from appcast.xml' || return 1

  [[ "$item_build" =~ ^[1-9][0-9]*$ ]] || release_fail 'appcast build must be a positive integer' || return 1
  [[ "$item_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_fail 'appcast version must use stable SemVer x.y.z' || return 1
  [[ "$item_build" == "$enclosure_build" ]] || release_fail 'appcast build mismatch between item and enclosure' || return 1
  [[ "$item_version" == "$enclosure_version" ]] || release_fail 'appcast version mismatch between item and enclosure' || return 1

  case "$enclosure_url" in
    */releases/download/v[0-9]*/*) ;;
    *) release_fail 'appcast enclosure URL must identify a GitHub release tag and DMG' || return 1 ;;
  esac

  APPCAST_BUILD="$item_build"
  APPCAST_VERSION="$item_version"
  APPCAST_TAG="$(printf '%s' "$enclosure_url" | sed -E 's#^.*/releases/download/([^/]+)/.*$#\1#')"
  APPCAST_DMG_NAME="$(basename "$enclosure_url")"
  [[ "$APPCAST_TAG" == "v$APPCAST_VERSION" ]] || release_fail 'appcast tag must match appcast version' || return 1
  [[ "$APPCAST_DMG_NAME" == "CLIProxyManager-$APPCAST_VERSION.dmg" ]] || release_fail 'appcast DMG filename must match appcast version' || return 1
}

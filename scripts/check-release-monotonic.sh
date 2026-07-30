#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "$SCRIPT_DIR/release-version-lib.sh"

GH="${GH:-gh}"
repository=''
previous_appcast=''
exclude_tag=''
provenance_path="$REPO_ROOT/build/release-provenance.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      [[ $# -ge 2 ]] || release_fail '--repository requires OWNER/REPO'
      repository="$2"
      shift 2
      ;;
    --previous-appcast)
      [[ $# -ge 2 ]] || release_fail '--previous-appcast requires a file'
      previous_appcast="$2"
      shift 2
      ;;
    --exclude-tag)
      [[ $# -ge 2 ]] || release_fail '--exclude-tag requires a tag'
      exclude_tag="$2"
      shift 2
      ;;
    --provenance)
      [[ $# -ge 2 ]] || release_fail '--provenance requires a file'
      provenance_path="$2"
      shift 2
      ;;
    *)
      release_fail 'Unknown option'
      ;;
  esac
done

if [[ -n "$exclude_tag" ]]; then
  [[ "$exclude_tag" == v* ]] && release_is_stable_semver "${exclude_tag#v}" ||
    release_fail '--exclude-tag must use vX.Y.Z'
fi
if [[ -z "$repository" && -z "$previous_appcast" ]]; then
  repository="$($GH repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" ||
    release_fail 'Unable to determine the GitHub repository'
fi
[[ -z "$repository" || "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_fail 'Repository must use OWNER/REPO'
[[ -z "$previous_appcast" || -f "$previous_appcast" ]] || release_fail 'The explicit previous appcast does not exist'

identity="$($SCRIPT_DIR/resolve-release-version.sh shell 2>/dev/null)" || release_fail 'Unable to resolve release identity'
eval "$identity"
[[ "$RELEASE_CHANNEL" == 'official' ]] || release_fail 'Release monotonicity check requires official artifacts'

trust='official'
source_name='github-release-appcast'
latest_tag=''
download_dir=''
staged=''

cleanup() {
  if [[ -n "$download_dir" ]]; then
    rm -rf "$download_dir" >/dev/null 2>&1 || true
  fi
  if [[ -n "$staged" ]]; then
    rm -f "$staged" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "$previous_appcast" ]]; then
  trust='local-fallback'
  source_name='explicit-previous-appcast'
  release_read_appcast_identity "$previous_appcast"
else
  latest_tag="$($GH release list \
    --repo "$repository" \
    --exclude-drafts \
    --exclude-pre-releases \
    --limit 1000 \
    --json tagName,publishedAt \
    --jq "[.[] | select(.tagName != \"$exclude_tag\" and .publishedAt != null)] | sort_by(.publishedAt) | last | .tagName // empty" 2>/dev/null)" ||
    release_fail 'Unable to query the latest published release'

  if [[ -n "$latest_tag" ]]; then
    download_dir="$(mktemp -d /tmp/cliproxymanager-appcast.XXXXXX 2>/dev/null)" ||
      release_fail 'Unable to stage appcast.xml download'
    "$GH" release download "$latest_tag" \
      --repo "$repository" \
      --pattern appcast.xml \
      --dir "$download_dir" >/dev/null 2>&1 ||
      release_fail 'Unable to download appcast.xml from the latest published release'
    [[ -f "$download_dir/appcast.xml" ]] ||
      release_fail 'Unable to download appcast.xml from the latest published release'
    release_read_appcast_identity "$download_dir/appcast.xml"
    [[ "$APPCAST_TAG" == "$latest_tag" ]] ||
      release_fail 'appcast tag must match the latest published release'
  else
    source_name='no-previous-release'
  fi
fi

if [[ -n "$latest_tag" || -n "$previous_appcast" ]]; then
  if ! release_positive_integer_greater_than "$RELEASE_BUILD" "$APPCAST_BUILD"; then
    release_fail "current build $RELEASE_BUILD must be greater than previous build $APPCAST_BUILD"
  fi
fi

provenance_dir="$(dirname "$provenance_path")"
mkdir -p "$provenance_dir" >/dev/null 2>&1 || release_fail 'Unable to create the release provenance directory'
staged="$(mktemp "$provenance_dir/.release-provenance.XXXXXX" 2>/dev/null)" ||
  release_fail 'Unable to stage release provenance'

if [[ -n "$latest_tag" || -n "$previous_appcast" ]]; then
  if ! (
    exec 2>/dev/null
    {
      printf '{\n'
      printf '  "trust": "%s",\n' "$trust"
      printf '  "current": {"version": "%s", "build": %s, "tag": "%s"},\n' "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_TAG"
      printf '  "previous": {"version": "%s", "build": %s, "tag": "%s", "dmgName": "%s"},\n' "$APPCAST_VERSION" "$APPCAST_BUILD" "$APPCAST_TAG" "$APPCAST_DMG_NAME"
      printf '  "source": "%s"\n' "$source_name"
      printf '}\n'
    } >"$staged"
  ); then
    release_fail 'Unable to write release provenance'
  fi
else
  if ! (
    exec 2>/dev/null
    {
      printf '{\n'
      printf '  "trust": "official",\n'
      printf '  "current": {"version": "%s", "build": %s, "tag": "%s"},\n' "$RELEASE_VERSION" "$RELEASE_BUILD" "$RELEASE_TAG"
      printf '  "previous": null,\n'
      printf '  "source": "no-previous-release"\n'
      printf '}\n'
    } >"$staged"
  ); then
    release_fail 'Unable to write release provenance'
  fi
fi

PLUTIL_BIN="$(release_plutil)"
validated_source="$($PLUTIL_BIN -extract source raw "$staged" 2>/dev/null)" ||
  release_fail 'Unable to validate release provenance'
[[ "$validated_source" == "$source_name" ]] || release_fail 'Unable to validate release provenance'
sed 's/"previous": null/"previous": false/' "$staged" 2>/dev/null | \
  "$PLUTIL_BIN" -convert xml1 -o - - 2>/dev/null | \
  "$PLUTIL_BIN" -lint - >/dev/null 2>&1 || release_fail 'Unable to validate release provenance'
release_atomic_replace "$staged" "$provenance_path" >/dev/null 2>&1 || release_fail 'Unable to replace release provenance'
staged=''

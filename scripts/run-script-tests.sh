#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INDEX_RECORDS="$(mktemp "${TMPDIR:-/tmp}/cliproxymanager-script-tests.XXXXXX")" || {
  printf 'Unable to create script test discovery file\n' >&2
  exit 1
}

cleanup() {
  rm -f "$INDEX_RECORDS"
}
trap cleanup EXIT

if ! git -C "$REPO_ROOT" ls-files -s -z -- 'Tests/ScriptTests/*-tests.sh' > "$INDEX_RECORDS"; then
  printf 'Unable to discover script tests from Git index\n' >&2
  exit 1
fi

found=0
while IFS= read -r -d '' record; do
  mode="${record%% *}"
  path="${record#*$'\t'}"

  [[ "$mode" == '100755' ]] || continue
  relative_path="${path#Tests/ScriptTests/}"
  [[ "$relative_path" != "$path" && "$relative_path" != */* && "$relative_path" == *-tests.sh ]] || continue

  test_script="$REPO_ROOT/$path"
  [[ -f "$test_script" && -x "$test_script" ]] || continue

  found=1
  "$test_script"
done < "$INDEX_RECORDS"

if [[ "$found" -eq 0 ]]; then
  printf 'No executable script tests discovered\n' >&2
  exit 1
fi

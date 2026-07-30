#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_SCRIPT="$REPO_ROOT/scripts/run-script-tests.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$SOURCE_SCRIPT" ]] || fail "run-script-tests.sh should exist and be executable"

sandbox="$(mktemp -d /tmp/script-test-runner-tests.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
fake_bin="$sandbox/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '-C' ]]; then
  shift 2
fi

case "${1:-}" in
  ls-files)
    shift
    [[ "${1:-}" == '-s' || "${1:-}" == '--stage' ]] || exit 90
    shift
    [[ "${1:-}" == '-z' ]] || exit 91
    shift
    [[ "${1:-}" == '--' ]] || exit 92
    cat "$SCRIPT_TEST_GIT_INDEX"
  ;;
  *)
    exit 93
  ;;
esac
SH
chmod +x "$fake_bin/git"

passing_test='#!/usr/bin/env bash
set -euo pipefail
printf "%s\\n" "$(basename "$0")" >> "$SCRIPT_TEST_LOG"
'
failing_test='#!/usr/bin/env bash
set -euo pipefail
printf "%s\\n" "$(basename "$0")" >> "$SCRIPT_TEST_LOG"
exit 37
'

make_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/Tests/ScriptTests"
  cp "$SOURCE_SCRIPT" "$repo/scripts/run-script-tests.sh"
  chmod +x "$repo/scripts/run-script-tests.sh"
}

write_test() {
  local repo="$1"
  local relative_path="$2"
  local contents="$3"
  local mode="$4"
  local target="$repo/$relative_path"

  mkdir -p "$(dirname "$target")"
  printf '%s' "$contents" > "$target"
  chmod "$mode" "$target"
}

make_index() {
  local index_file="$1"
  shift
  local entry mode path
  : > "$index_file"
  for entry in "$@"; do
    mode="${entry%%:*}"
    path="${entry#*:}"
    printf '%s %s 0\t%s\0' "$mode" '0123456789012345678901234567890123456789' "$path" >> "$index_file"
  done
}

run_runner() {
  local repo="$1"
  local index_file="$2"
  PATH="$fake_bin:$PATH" SCRIPT_TEST_GIT_INDEX="$index_file" "$repo/scripts/run-script-tests.sh"
}

repo="$sandbox/ordered-repo"
index="$sandbox/ordered.index"
log="$sandbox/ordered.log"
make_repo "$repo"
write_test "$repo" 'Tests/ScriptTests/01-first-tests.sh' "$passing_test" 755
write_test "$repo" 'Tests/ScriptTests/20 name-tests.sh' "$passing_test" 755
write_test "$repo" 'Tests/ScriptTests/99-last-tests.sh' "$passing_test" 755
write_test "$repo" 'Tests/ScriptTests/tracked-but-not-executable-tests.sh' "$passing_test" 644
write_test "$repo" 'Tests/ScriptTests/untracked-tests.sh' "$passing_test" 755
write_test "$repo" 'Tests/ScriptTests/nested/ignored-tests.sh' "$passing_test" 755
make_index "$index" \
  '100755:Tests/ScriptTests/01-first-tests.sh' \
  '100755:Tests/ScriptTests/20 name-tests.sh' \
  '100755:Tests/ScriptTests/99-last-tests.sh' \
  '100644:Tests/ScriptTests/tracked-but-not-executable-tests.sh' \
  '100755:Tests/ScriptTests/nested/ignored-tests.sh'
SCRIPT_TEST_LOG="$log" run_runner "$repo" "$index"
printf '%s\n' \
  '01-first-tests.sh' \
  '20 name-tests.sh' \
  '99-last-tests.sh' > "$sandbox/ordered.expected"
cmp -s "$sandbox/ordered.expected" "$log" || fail "runner should run only tracked executable tests once in Git index order"
! grep -F 'untracked-tests.sh' "$log" >/dev/null || fail "runner must ignore untracked shell tests"

repo="$sandbox/empty-repo"
index="$sandbox/empty.index"
make_repo "$repo"
: > "$index"
if SCRIPT_TEST_LOG="$sandbox/empty.log" run_runner "$repo" "$index" >"$sandbox/empty.out" 2>"$sandbox/empty.err"; then
  fail "runner should reject an empty test discovery"
fi
grep -Fx 'No executable script tests discovered' "$sandbox/empty.err" >/dev/null ||
  fail "empty discovery should use the fixed diagnostic"

repo="$sandbox/non-executable-repo"
index="$sandbox/non-executable.index"
make_repo "$repo"
write_test "$repo" 'Tests/ScriptTests/sentinel@example.com-tests.sh' "$passing_test" 644
make_index "$index" '100644:Tests/ScriptTests/sentinel@example.com-tests.sh'
if SCRIPT_TEST_LOG="$sandbox/non-executable.log" run_runner "$repo" "$index" >"$sandbox/non-executable.out" 2>"$sandbox/non-executable.err"; then
  fail "runner should reject a discovery with no executable tracked tests"
fi
grep -Fx 'No executable script tests discovered' "$sandbox/non-executable.err" >/dev/null ||
  fail "non-executable discovery should use the fixed diagnostic"
! grep -F 'sentinel@example.com' "$sandbox/non-executable.err" >/dev/null ||
  fail "non-executable discovery must not expose test paths"

repo="$sandbox/worktree-mode-repo"
index="$sandbox/worktree-mode.index"
make_repo "$repo"
write_test "$repo" 'Tests/ScriptTests/lost-mode-tests.sh' "$passing_test" 644
make_index "$index" '100755:Tests/ScriptTests/lost-mode-tests.sh'
if SCRIPT_TEST_LOG="$sandbox/worktree-mode.log" run_runner "$repo" "$index" >"$sandbox/worktree-mode.out" 2>"$sandbox/worktree-mode.err"; then
  fail "runner should reject a Git executable that is not executable in the working tree"
fi
grep -Fx 'No executable script tests discovered' "$sandbox/worktree-mode.err" >/dev/null ||
  fail "working-tree mode failure should use the fixed diagnostic"

repo="$sandbox/fail-fast-repo"
index="$sandbox/fail-fast.index"
log="$sandbox/fail-fast.log"
make_repo "$repo"
write_test "$repo" 'Tests/ScriptTests/01-fails-tests.sh' "$failing_test" 755
write_test "$repo" 'Tests/ScriptTests/02-must-not-run-tests.sh' "$passing_test" 755
make_index "$index" \
  '100755:Tests/ScriptTests/01-fails-tests.sh' \
  '100755:Tests/ScriptTests/02-must-not-run-tests.sh'
if SCRIPT_TEST_LOG="$log" run_runner "$repo" "$index" >"$sandbox/fail-fast.out" 2>"$sandbox/fail-fast.err"; then
  fail "runner should propagate a child test failure"
else
  status=$?
fi
[[ "$status" -eq 37 ]] || fail "runner should propagate the first failing test exit status"
grep -Fx '01-fails-tests.sh' "$log" >/dev/null || fail "runner should execute the first failing test"
! grep -F '02-must-not-run-tests.sh' "$log" >/dev/null || fail "runner must stop after the first failure"

printf 'script-test-runner tests passed\n'

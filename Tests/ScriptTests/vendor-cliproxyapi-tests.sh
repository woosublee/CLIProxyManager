#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vendor-cliproxyapi.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

help_output="$($SCRIPT --help)"
[[ "$help_output" == *"Usage: scripts/vendor-cliproxyapi.sh <version>"* ]] || fail "help should document version usage"
[[ "$help_output" == *"Downloads router-for-me/CLIProxyAPI"* ]] || fail "help should document upstream release download"
[[ "$help_output" == *"checksums.txt"* ]] || fail "help should document checksum verification"
[[ "$help_output" == *"cliproxyapi.manifest.json"* ]] || fail "help should document manifest output"

sandbox="$(mktemp -d /tmp/vendor-cliproxyapi-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
test_repo="$sandbox/repo"
mkdir -p "$test_repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi"
fake_binary="$sandbox/cliproxyapi"
cat > "$fake_binary" <<'FAKE'
#!/usr/bin/env bash
cat <<'VERSION'
CLIProxyAPI Version: 9.8.7, Commit: testcommit, BuiltAt: 2026-05-10T01:02:03Z
VERSION
exit 2
FAKE
chmod +x "$fake_binary"

CLIPROXY_MANAGER_REPO_ROOT="$test_repo" "$SCRIPT" --local "$fake_binary" --source-label test-fixture >/tmp/vendor-cliproxyapi-local.out

dest="$test_repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi"
manifest="$test_repo/Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json"
[[ -x "$dest" ]] || fail "vendored binary should be executable"
[[ -f "$manifest" ]] || fail "manifest should be written"
grep -q '"version": "9.8.7"' "$manifest" || fail "manifest should include parsed version"
grep -q '"commit": "testcommit"' "$manifest" || fail "manifest should include parsed commit"
grep -q '"builtAt": "2026-05-10T01:02:03Z"' "$manifest" || fail "manifest should include parsed build time"
grep -q '"source": "test-fixture"' "$manifest" || fail "manifest should include source label"
grep -q '"vendoredBinarySha256"' "$manifest" || fail "manifest should include binary checksum"

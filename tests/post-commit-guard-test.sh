#!/usr/bin/env bash
set -euo pipefail

# Tests for hooks/post-commit-guard.sh, the PostToolUse hook that validates a
# commit after `git commit` runs. Drives it with synthetic hook payloads and
# asserts the exit contract: 2 blocks, 0 allows.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/post-commit-guard.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-post-commit-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME"

pass=0
fail=0

repo="$TMP_DIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email "dex@example.test"
git -C "$repo" config user.name "Dex Test"

commit_with_message() {
  printf '%s\n' "$RANDOM$RANDOM" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "$1"
}

# Build a PostToolUse payload for a Bash tool call.
mkpayload() {
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"exit_code":int(sys.argv[2])}}))' "$1" "$2"
}

run_hook() {
  set +e
  HOOK_OUT="$(printf '%s' "$1" | (cd "$repo" && bash "$HOOK") 2>&1)"
  HOOK_RC=$?
  set -e
}

check() {
  local label="$1" expected_rc="$2" needle="${3:-}"
  if [[ "$HOOK_RC" != "$expected_rc" ]]; then
    printf 'FAIL %s: expected rc %s, got %s\n%s\n' "$label" "$expected_rc" "$HOOK_RC" "$HOOK_OUT" >&2
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$needle" && "$HOOK_OUT" != *"$needle"* ]]; then
    printf 'FAIL %s: missing %s\n%s\n' "$label" "$needle" "$HOOK_OUT" >&2
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
}

# A conventional commit passes.
commit_with_message "feat(guards): add a thing"
run_hook "$(mkpayload 'git commit -m "feat(guards): add a thing"' 0)"
check "conventional commit allowed" 0

# Every documented type is accepted, with and without scope/breaking marker.
for message in \
  "fix: correct a bug" \
  "refactor(lib): extract helper" \
  "perf: speed up parsing" \
  "docs: update readme" \
  "test: add coverage" \
  "chore: bump deps" \
  "build: adjust packaging" \
  "ci: add workflow" \
  "style: reformat" \
  "revert: undo change" \
  "feat!: breaking change" \
  "feat(api)!: breaking scoped change"; do
  commit_with_message "$message"
  run_hook "$(mkpayload 'git commit -m x' 0)"
  check "accepted: $message" 0
done

# A non-conventional message is rejected with actionable output.
commit_with_message "updated some stuff"
run_hook "$(mkpayload 'git commit -m "updated some stuff"' 0)"
check "non-conventional commit blocked" 2 "does not follow conventional format"
run_hook "$(mkpayload 'git commit -m "updated some stuff"' 0)"
check "block names the offending message" 2 "updated some stuff"

# Near-misses that must still be rejected.
for message in \
  "feat add a thing" \
  "feat:" \
  "nope(scope): description" \
  "Feat: capitalized type"; do
  commit_with_message "$message"
  run_hook "$(mkpayload 'git commit -m x' 0)"
  check "rejected: $message" 2 "does not follow conventional format"
done

# A failed git commit must not be validated: nothing was created.
commit_with_message "broken message that would fail"
run_hook "$(mkpayload 'git commit -m "broken message that would fail"' 1)"
check "failed commit is not validated" 0

# Commands that are not a git commit are ignored, including lookalikes.
for command in \
  'git commit-tree abc123' \
  'echo "git commit -m fake"' \
  'git status --short' \
  'git log --oneline'; do
  run_hook "$(mkpayload "$command" 0)"
  check "ignored: $command" 0
done

# Empty and malformed payloads must not crash the hook.
run_hook ""
check "empty payload ignored" 0
run_hook "not json at all"
check "non-json payload ignored" 0
run_hook '{"tool_input":{"command":12345}}'
check "non-string command ignored" 0

# Reading a command has to be bounded. This hook runs on every Bash call, and
# for a while nothing stopped it: two of these were found at 100% CPU having
# burned 4.7 hours each, still spinning long after the bug that started them
# was fixed, slowing everything and flaking the tests that measure elapsed time.
#
# The parse is stubbed out rather than fed a pathological command, so the test
# proves the deadline without depending on one staying pathological.
alarm_out="$TMP_DIR/alarm.out"
alarm_status=0
python3 - "$ROOT" > "$alarm_out" 2>&1 <<'PY' || alarm_status=$?
import importlib.util
import os
import sys
import time

root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "hooks"))
spec = importlib.util.spec_from_file_location(
    "commit_target", os.path.join(root, "hooks/git-commit-target.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)  # the __main__ guard keeps main() from running

module.COMMIT_PARSE_TIMEOUT_SECONDS = 1
module.has_git_commit = lambda text, cwd, depth=0: time.sleep(30)
os.environ["DX_HOOK_COMMAND"] = "git commit -m x"

started = time.time()
status = module.main()
elapsed = time.time() - started

if status != 1:
    raise SystemExit(f"expected status 1 after the deadline, got {status}")
if elapsed > 5:
    raise SystemExit(f"the deadline did not stop the parse: {elapsed:.1f}s")
PY
if [[ "$alarm_status" -eq 0 ]] && grep -q 'gave up reading this command' "$alarm_out"; then
  pass=$((pass + 1))
else
  printf 'FAIL: the parse deadline did not stop and report (status %s)\n' "$alarm_status" >&2
  cat "$alarm_out" >&2
  fail=$((fail + 1))
fi

# A real command still fits comfortably inside the budget.
budget_status=0
DX_HOOK_COMMAND='git commit -m x' DEX_COMMIT_PARSE_TIMEOUT=1 \
  python3 "$ROOT/hooks/git-commit-target.py" >/dev/null 2>&1 || budget_status=$?
if [[ "$budget_status" -eq 0 ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL: a 1s budget was not enough to read `git commit -m x`\n' >&2
  fail=$((fail + 1))
fi

printf 'post-commit-guard-test: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0

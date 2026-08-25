#!/usr/bin/env bash
set -euo pipefail
umask 077

# Tests for bin/status-line.sh. It runs on every TUI render, so it loads only
# the lib modules it needs; these cases exercise each branch to catch a helper
# that is referenced but no longer sourced.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-status-line-test.XXXXXX")"

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
export DEX_SESSION_ID="repo-statusline-test-main"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

pass=0
fail=0

run_status_line() {
  set +e
  STATUS_OUT="$(bash "$ROOT/bin/status-line.sh" 2>&1)"
  STATUS_RC=$?
  set -e
}

check() {
  local label="$1" expected="$2"
  if [[ "$STATUS_RC" -ne 0 ]]; then
    printf 'FAIL %s: exited %s\n%s\n' "$label" "$STATUS_RC" "$STATUS_OUT" >&2
    fail=$((fail + 1))
    return
  fi
  if [[ "$STATUS_OUT" != *"$expected"* ]]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$STATUS_OUT" >&2
    fail=$((fail + 1))
    return
  fi
  # A helper from an unloaded module shows up here rather than in the exit code,
  # because the branches are guarded.
  if [[ "${STATUS_OUT}" == *'command not found'* ]]; then
    printf 'FAIL %s: referenced an unloaded helper\n%s\n' "$label" "$STATUS_OUT" >&2
    fail=$((fail + 1))
    return
  fi
  pass=$((pass + 1))
}

# No state at all.
run_status_line
check "no state" "Phase ?/6"

# A phase with an audit iteration and an elapsed timer.
printf '3\n' > "$(dx_state_file "$DEX_SESSION_ID")"
printf '7:1700000000\n' > "$(dx_loop_file "$DEX_SESSION_ID")"
printf 'total:%s\n' "$(( $(date +%s) - 125 ))" > "$(dx_times_file "$DEX_SESSION_ID")"
run_status_line
check "phase number" "Phase 3/6"
run_status_line
check "audit iteration" "Audit 7/30"
run_status_line
check "elapsed minutes" "2m"

# Past the last phase.
printf '7\n' > "$(dx_state_file "$DEX_SESSION_ID")"
run_status_line
check "unproven lifecycle terminal" "terminal commit incomplete"
printf '3\n' > "$(dx_state_file "$DEX_SESSION_ID")"

# Paused by the pause marker, with a reason.
dx_lifecycle_atomic_write "$(dx_paused_file "$DEX_SESSION_ID")" paused
dx_write_pause_state "$DEX_SESSION_ID" unresolved_findings review
run_status_line
check "paused marker" "Dex paused"
rm -f "$(dx_paused_file "$DEX_SESSION_ID")"

# Pause metadata on its own is a durable brake. An unsafe inode is surfaced as
# blocked instead of being mistaken for an active phase.
run_status_line
check "metadata-only pause" "Dex paused"
rm -f "$(dx_pause_state_file "$DEX_SESSION_ID")"
mkdir "$(dx_pause_state_file "$DEX_SESSION_ID")"
run_status_line
check "unsafe pause" "Dex blocked | unsafe pause state"
rmdir "$(dx_pause_state_file "$DEX_SESSION_ID")"

# Paused by a human control action.
dx_write_lifecycle_control "$DEX_SESSION_ID" pause "operator" 2>/dev/null || \
  printf 'action=pause\n' > "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
run_status_line
check "human pause" "Dex paused by human"

# A times file is data, and this script renders it on every prompt — long
# after whatever wrote it has gone. Both shells evaluate an array subscript
# inside $(( )) as an arithmetic expression, so a start time of `HOME[$(…)]`
# used to run that command from the prompt. `set -u` does not stop it: naming
# a variable that is already set keeps nounset quiet, so only checking the
# value is digits does.
CANARY="$TMP_DIR/times-file-canary"
rm -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" "$(dx_paused_file "$DEX_SESSION_ID")"
printf '3\n' > "$(dx_state_file "$DEX_SESSION_ID")"
printf 'total:HOME[$(touch %s)]\n' "$CANARY" > "$(dx_times_file "$DEX_SESSION_ID")"
run_status_line
check "hostile times file still renders" "Phase 3/6"
if [[ -e "$CANARY" ]]; then
  printf 'FAIL hostile times file: the status line executed a command from it\n' >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi
if [[ "${STATUS_OUT}" == *'HOME['* ]]; then
  printf 'FAIL hostile times file: raw file contents reached the status line\n%s\n' "$STATUS_OUT" >&2
  fail=$((fail + 1))
else
  pass=$((pass + 1))
fi

printf 'status-line-test: %d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail

# `dx ps` is the visible half of session process ownership: a human must be
# able to see what every session on the host owns, and what is left over from
# one that is gone, before anything is stopped.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-ps-test.XXXXXX")"

cleanup() {
  local stray
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r stray; do
      [[ "$stray" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$stray" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null || true)
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$file" ]] || fail "$label: $file was never written"
}

assert_gone() {
  local pid="$1" label="$2" attempt=0
  while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "$label: process $pid was not stopped"
  fi
}

run_ps() {
  local output_file="$1"
  shift
  set +e
  bash "$ROOT/bin/ps.sh" "$@" > "$output_file" 2>&1
  DX_PS_STATUS=$?
  set -e
}

# ── Argument handling, the way every user-facing bin/ script does it ────────
run_ps "$TMP_DIR/help.out" --help
assert_eq "0" "$DX_PS_STATUS" "dx ps --help status"
assert_contains "Usage: dx ps" "$TMP_DIR/help.out"

run_ps "$TMP_DIR/unknown.out" --not-an-option
[[ "$DX_PS_STATUS" -ne 0 ]] || assert_at $LINENO
assert_contains "Unknown ps option: --not-an-option" "$TMP_DIR/unknown.out"

# ── Nothing owned yet ───────────────────────────────────────────────────────
run_ps "$TMP_DIR/empty.out"
assert_eq "0" "$DX_PS_STATUS" "dx ps status with no sessions"
assert_contains "No live Dex session owns a process" "$TMP_DIR/empty.out"

# ── A live session, and the processes it owns ────────────────────────────────
PROVIDER="$TMP_DIR/provider.sh"
cat > "$PROVIDER" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
provider_session="$1"
report_dir="$2"
(
  dx_session_process_token_attach "$provider_session"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$report_dir/detached.pid"
  disown 2>/dev/null || true
  /bin/sleep 300
) &
printf '%s\n' "$!" > "$report_dir/holder.pid"
PROVIDER
chmod +x "$PROVIDER"

SESSION_ID="ps-listing-test"
bash "$PROVIDER" "$SESSION_ID" "$TMP_DIR"
wait_for_file "$TMP_DIR/holder.pid" "fake provider"
wait_for_file "$TMP_DIR/detached.pid" "detached process"
HOLDER_PID="$(cat "$TMP_DIR/holder.pid")"
DETACHED_PID="$(cat "$TMP_DIR/detached.pid")"

run_ps "$TMP_DIR/live.out"
assert_eq "0" "$DX_PS_STATUS" "dx ps status with a live session"
assert_contains "Live sessions:" "$TMP_DIR/live.out"
assert_contains "$SESSION_ID" "$TMP_DIR/live.out"
assert_contains "$HOLDER_PID" "$TMP_DIR/live.out"
assert_contains "$DETACHED_PID" "$TMP_DIR/live.out"
assert_contains "PID" "$TMP_DIR/live.out"
assert_contains "CWD" "$TMP_DIR/live.out"
assert_contains "2 owned process(es)" "$TMP_DIR/live.out"
assert_contains "0 orphaned session(s), 0 orphaned process(es)" "$TMP_DIR/live.out"
assert_not_contains "Orphans (" "$TMP_DIR/live.out"
# A listing stops nothing.
kill -0 "$HOLDER_PID" 2>/dev/null || assert_at $LINENO
kill -0 "$DETACHED_PID" 2>/dev/null || assert_at $LINENO

# ── The same processes, once the session behind them is gone ─────────────────
# Killing the holder is what a crashed or killed session looks like: the token
# file is still there, but nothing carrying it is the session any more.
kill -KILL "$HOLDER_PID" 2>/dev/null || true
assert_gone "$HOLDER_PID" "fake provider holder"

run_ps "$TMP_DIR/orphan.out"
assert_eq "0" "$DX_PS_STATUS" "dx ps status with orphans"
assert_contains "Orphans (the session that started these is gone)" "$TMP_DIR/orphan.out"
assert_contains "$DETACHED_PID" "$TMP_DIR/orphan.out"
assert_contains "1 orphaned session(s), 1 orphaned process(es)" "$TMP_DIR/orphan.out"
assert_contains "Read-only. Nothing was stopped." "$TMP_DIR/orphan.out"
assert_not_contains "Live sessions:" "$TMP_DIR/orphan.out"
kill -0 "$DETACHED_PID" 2>/dev/null || fail "the read-only listing stopped a process"

# A removed holder record reads the same way: the session cannot be proven live.
run_ps "$TMP_DIR/no-holder.out"
rm -f "$(dx_session_process_holder_file "$SESSION_ID")"
run_ps "$TMP_DIR/no-holder.out"
assert_contains "Orphans (the session that started these is gone)" "$TMP_DIR/no-holder.out"
assert_contains "$DETACHED_PID" "$TMP_DIR/no-holder.out"

# ── Acting takes an explicit flag, and names what it stopped ─────────────────
run_ps "$TMP_DIR/reaped.out" --reap-orphans
assert_eq "0" "$DX_PS_STATUS" "dx ps --reap-orphans status"
assert_contains "$SESSION_ID: reaped pid=$DETACHED_PID" "$TMP_DIR/reaped.out"
assert_contains "Stopped 1 orphaned process(es)" "$TMP_DIR/reaped.out"
assert_gone "$DETACHED_PID" "orphaned process"
[[ ! -d "$(dx_session_process_dir "$SESSION_ID")" ]] || assert_at $LINENO

run_ps "$TMP_DIR/after.out"
assert_contains "0 orphaned session(s), 0 orphaned process(es)" "$TMP_DIR/after.out"
assert_not_contains "$DETACHED_PID" "$TMP_DIR/after.out"

printf 'dx ps tests passed\n'

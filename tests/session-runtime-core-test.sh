#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-runtime-core.XXXXXX")"
TEST_CHILD_PIDS=""

cleanup() {
  local child_pid
  for child_pid in $TEST_CHILD_PIDS; do
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/proc"
export DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/no-ps"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" \
  "$DX_SESSION_RUNTIME_PROC_ROOT/$$" \
  "$DX_SESSION_RUNTIME_PROC_ROOT/sys/kernel/random"
printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' \
  > "$DX_SESSION_RUNTIME_PROC_ROOT/sys/kernel/random/boot_id"

# shellcheck source=lib/session.sh
source "$ROOT/lib/session.sh"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"

write_proc_identity() {
  local start_ticks="$1" process_state="${2:-S}"
  printf '%s\n' \
    "$$ (dex test worker) $process_state 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $start_ticks 20" \
    > "$DX_SESSION_RUNTIME_PROC_ROOT/$$/stat"
}

runtime_health() {
  dx_session_runtime_health "$1" "${2:-}"
}

run_start_rejected_promptly() {
  local test_sid="$1" expected_result="$2" label="$3"
  local result_file="$TMP_DIR/${label}.result" child_pid attempt=0
  (
    set +e
    DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS=100 \
      dx_session_runtime_start "$test_sid" codex "$WORKSPACE" "$$" >/dev/null 2>&1
    printf '%s\n' "$?" > "$result_file"
  ) &
  child_pid=$!
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${child_pid}"
  while [[ ! -s "$result_file" && "$attempt" -lt 30 ]]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if [[ ! -s "$result_file" ]]; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    fail "$label did not return within three seconds"
  fi
  wait "$child_pid"
  assert_eq "$expected_result" "$(<"$result_file")" "$label result"
}

hold_lock() {
  local lock_file="$1" ready_file="$2" hold_seconds="$3"
  python3 - "$lock_file" "$ready_file" "$hold_seconds" <<'PY' &
import fcntl
import os
import sys
import time

descriptor = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(descriptor, fcntl.LOCK_EX)
with open(sys.argv[2], "w", encoding="utf-8") as ready:
    ready.write("ready\n")
time.sleep(float(sys.argv[3]))
PY
  LOCK_HOLDER_PID=$!
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${LOCK_HOLDER_PID}"
  wait_for_process_files "$LOCK_HOLDER_PID" "$ready_file"
}

write_proc_identity 424242
WORKSPACE="$TMP_DIR/repo/.dex/worktrees/ticket-710"
mkdir -p "$WORKSPACE"
SID="$(dx_scoped_session_id worktree-ticket-710)"
TOKEN="$(dx_session_runtime_start "$SID" codex "$WORKSPACE" "$$")"
[[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || assert_at $LINENO
RUNTIME_FILE="$(dx_session_runtime_file "$SID")"
RUNTIME_LOCK_FILE="${RUNTIME_FILE}-lock"
assert_file "$RUNTIME_FILE"
assert_file "$RUNTIME_LOCK_FILE"
assert_eq "600" "$(python3 - "$RUNTIME_FILE" <<'PY'
import os
import stat
import sys
print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))
PY
)" "runtime record mode"
assert_eq "600" "$(python3 - "$RUNTIME_LOCK_FILE" <<'PY'
import os
import stat
import sys
print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))
PY
)" "runtime lock mode"
assert_eq "live" "$(runtime_health "$SID" "$TOKEN")" "live runtime"
assert_eq "codex" "$(dx_session_runtime_field "$SID" provider)" "provider"
assert_eq "$WORKSPACE" "$(dx_session_runtime_field "$SID" workspace)" "workspace"
assert_eq "running" "$(dx_session_runtime_field "$SID" status)" "initial status"
RUNTIME_JSON="$(dx_session_runtime_read "$SID")"
assert_contains "\"session_id\":\"$SID\"" <(printf '%s\n' "$RUNTIME_JSON")
assert_not_contains "$TOKEN" <(printf '%s\n' "$RUNTIME_JSON")
dx_session_runtime_matches "$SID" "$TOKEN" || fail "live owner did not match its lease"
if dx_session_runtime_matches "$SID" ""; then
  fail "empty lease token matched a live owner"
fi
if dx_session_runtime_field "$SID" token >/dev/null 2>&1; then
  fail "runtime field reader exposed the private lease token"
else
  assert_eq "3" "$?" "private token field result"
fi
if dx_session_runtime_field "$SID" unknown >/dev/null 2>&1; then
  fail "runtime field reader accepted an unknown field"
else
  assert_eq "3" "$?" "unknown field result"
fi
if dx_session_runtime_start "$SID" codex "$WORKSPACE" "$$" >/dev/null 2>&1; then
  fail "runtime start replaced a live lease"
else
  assert_eq "2" "$?" "live replacement result"
fi

# Keep lease credentials out of process arguments, even while a call crosses a wrapper.
REAL_PYTHON="$(command -v python3)"
ARGV_BIN="$TMP_DIR/argv-bin"
ARGV_LOG="$TMP_DIR/python-argv"
mkdir -p "$ARGV_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$@" > "$DX_TEST_ARGV_LOG"' \
  'exec "$DX_TEST_REAL_PYTHON" "$@"' \
  > "$ARGV_BIN/python3"
chmod +x "$ARGV_BIN/python3"
DX_TEST_REAL_PYTHON="$REAL_PYTHON" DX_TEST_ARGV_LOG="$ARGV_LOG" \
  PATH="$ARGV_BIN:$PATH" dx_session_runtime_heartbeat "$SID" "$TOKEN" "$$"
assert_not_contains "$TOKEN" "$ARGV_LOG"

WRONG_TOKEN="0${TOKEN#?}"
[[ "$WRONG_TOKEN" != "$TOKEN" ]] || WRONG_TOKEN="1${TOKEN#?}"
if dx_session_runtime_heartbeat "$SID" "$WRONG_TOKEN" "$$" 2>/dev/null; then
  fail "heartbeat accepted the wrong lease token"
else
  assert_eq "2" "$?" "wrong-token heartbeat result"
fi
if dx_session_runtime_heartbeat "$SID" "$TOKEN" "$(( $$ + 1 ))" 2>/dev/null; then
  fail "heartbeat accepted the wrong process"
else
  assert_eq "2" "$?" "wrong-pid heartbeat result"
fi

write_proc_identity 525252
assert_eq "dead" "$(runtime_health "$SID" "$TOKEN")" "PID reuse health"
if dx_session_runtime_heartbeat "$SID" "$TOKEN" "$$" 2>/dev/null; then
  fail "heartbeat accepted a reused PID"
else
  assert_eq "2" "$?" "PID reuse heartbeat result"
fi

write_proc_identity 424242
mv "$DX_SESSION_RUNTIME_PROC_ROOT/$$/stat" "$TMP_DIR/saved-proc-stat"
assert_eq "unverifiable" "$(runtime_health "$SID" "$TOKEN")" "missing process evidence"
if dx_session_runtime_heartbeat "$SID" "$TOKEN" "$$" >/dev/null 2>&1; then
  fail "heartbeat treated an uninspectable process as an exact owner"
else
  assert_eq "2" "$?" "unverifiable heartbeat result"
fi
if dx_session_runtime_start "$SID" codex "$WORKSPACE" "$$" >/dev/null 2>&1; then
  fail "runtime start replaced an unverifiable lease"
fi
mv "$TMP_DIR/saved-proc-stat" "$DX_SESSION_RUNTIME_PROC_ROOT/$$/stat"

write_proc_identity 424242 Z
assert_eq "dead" "$(runtime_health "$SID" "$TOKEN")" "zombie runtime health"
if dx_session_runtime_heartbeat "$SID" "$TOKEN" "$$" >/dev/null 2>&1; then
  fail "heartbeat treated a zombie as live"
else
  assert_eq "2" "$?" "zombie heartbeat result"
fi
write_proc_identity 424242

# Readers should see complete snapshots while heartbeat replaces records atomically.
CHURN_SID="$(dx_scoped_session_id worktree-ticket-churn)"
CHURN_TOKEN="$(dx_session_runtime_start "$CHURN_SID" codex "$WORKSPACE" "$$")"
(
  churn_iteration=0
  while [[ "$churn_iteration" -lt 20 ]]; do
    dx_session_runtime_heartbeat "$CHURN_SID" "$CHURN_TOKEN" "$$"
    churn_iteration=$((churn_iteration + 1))
  done
) &
CHURN_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${CHURN_PID}"
churn_read=0
while [[ "$churn_read" -lt 30 ]]; do
  assert_eq "live" "$(runtime_health "$CHURN_SID" "$CHURN_TOKEN")" "runtime churn health"
  dx_session_runtime_read "$CHURN_SID" >/dev/null
  churn_read=$((churn_read + 1))
done
wait "$CHURN_PID"

# A normal finisher waits while heartbeat owns the lease lock.
WAIT_SID="$(dx_scoped_session_id worktree-ticket-wait)"
WAIT_TOKEN="$(dx_session_runtime_start "$WAIT_SID" codex "$WORKSPACE" "$$")"
WAIT_SITE_DIR="$TMP_DIR/wait-site"
WAIT_READY="$TMP_DIR/wait-heartbeat.ready"
WAIT_RESULT="$TMP_DIR/wait-finish.result"
WAIT_HEARTBEAT_RESULT="$TMP_DIR/wait-heartbeat.result"
mkdir -p "$WAIT_SITE_DIR"
printf '%s\n' \
  'import fcntl' \
  'import os' \
  'import sys' \
  'import time' \
  '_original_flock = fcntl.flock' \
  '_held_once = False' \
  'def _test_flock(descriptor, operation):' \
  '    global _held_once' \
  '    result = _original_flock(descriptor, operation)' \
  '    if not _held_once and len(sys.argv) > 1 and sys.argv[1] == "heartbeat" and operation & fcntl.LOCK_EX:' \
  '        _held_once = True' \
  '        with open(os.environ["DX_TEST_HEARTBEAT_LOCK_READY"], "w", encoding="utf-8") as ready:' \
  '            ready.write("ready\\n")' \
  '        time.sleep(0.5)' \
  '    return result' \
  'fcntl.flock = _test_flock' \
  > "$WAIT_SITE_DIR/sitecustomize.py"
(
  set +e
  PYTHONPATH="$WAIT_SITE_DIR" DX_TEST_HEARTBEAT_LOCK_READY="$WAIT_READY" \
    dx_session_runtime_heartbeat "$WAIT_SID" "$WAIT_TOKEN" "$$" >/dev/null 2>&1
  printf '%s\n' "$?" > "$WAIT_HEARTBEAT_RESULT"
) &
WAIT_HEARTBEAT_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${WAIT_HEARTBEAT_PID}"
wait_for_process_files "$WAIT_HEARTBEAT_PID" "$WAIT_READY"
set +e
dx_session_runtime_finish "$WAIT_SID" "$WAIT_TOKEN" paused "$$" >/dev/null 2>&1
WAIT_FINISH_RESULT=$?
set -e
printf '%s\n' "$WAIT_FINISH_RESULT" > "$WAIT_RESULT"
wait "$WAIT_HEARTBEAT_PID"
assert_eq "0" "$(<"$WAIT_HEARTBEAT_RESULT")" "contending heartbeat result"
assert_eq "0" "$(<"$WAIT_RESULT")" "finish after lock contention"
assert_eq "paused" "$(dx_session_runtime_field "$WAIT_SID" status)" "waited finish status"

# Exhausting the bounded wait has a distinct result.
TIMEOUT_SID="$(dx_scoped_session_id worktree-ticket-timeout)"
TIMEOUT_TOKEN="$(dx_session_runtime_start "$TIMEOUT_SID" codex "$WORKSPACE" "$$")"
TIMEOUT_LOCK="$(dx_session_runtime_file "$TIMEOUT_SID")-lock"
TIMEOUT_READY="$TMP_DIR/timeout-lock.ready"
hold_lock "$TIMEOUT_LOCK" "$TIMEOUT_READY" 30
set +e
DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS=100 \
  dx_session_runtime_heartbeat "$TIMEOUT_SID" "$TIMEOUT_TOKEN" "$$" >/dev/null 2>&1
TIMEOUT_RESULT=$?
set -e
assert_eq "75" "$TIMEOUT_RESULT" "runtime lock timeout result"
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true

# A second lock inode cannot authorize an overwrite while the original is still held.
SWAP_SID="$(dx_scoped_session_id worktree-ticket-lock-swap)"
SWAP_TOKEN="$(dx_session_runtime_start "$SWAP_SID" codex "$WORKSPACE" "$$")"
SWAP_FILE="$(dx_session_runtime_file "$SWAP_SID")"
SWAP_LOCK="${SWAP_FILE}-lock"
SWAP_READY="$TMP_DIR/swap-lock.ready"
SWAP_RECORD_BEFORE="$(<"$SWAP_FILE")"
hold_lock "$SWAP_LOCK" "$SWAP_READY" 30
mv "$SWAP_LOCK" "${SWAP_LOCK}.original"
cp "${SWAP_LOCK}.original" "$SWAP_LOCK"
chmod 600 "$SWAP_LOCK"
if DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS=500 \
  dx_session_runtime_heartbeat "$SWAP_SID" "$SWAP_TOKEN" "$$" >/dev/null 2>&1; then
  fail "replacement runtime lock authorized an update"
else
  assert_eq "3" "$?" "replacement lock mutation result"
fi
assert_eq "$SWAP_RECORD_BEFORE" "$(<"$SWAP_FILE")" "record after rejected lock replacement"
assert_eq "corrupt" "$(runtime_health "$SWAP_SID" "$SWAP_TOKEN")" "replacement lock health"
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true

if dx_session_runtime_finish "$SID" "$TOKEN" nonsense "$$" >/dev/null 2>&1; then
  fail "runtime finish accepted an unknown status"
else
  assert_eq "3" "$?" "invalid finish status result"
fi
dx_session_runtime_finish "$SID" "$TOKEN" paused "$$"
assert_eq "paused" "$(dx_session_runtime_field "$SID" status)" "finished status"
assert_file "$RUNTIME_LOCK_FILE"
[[ "$(dx_session_runtime_field "$SID" finished_at)" =~ ^[0-9]+$ ]] || assert_at $LINENO
assert_eq "dead" "$(runtime_health "$SID" "$TOKEN")" "finished lease health"
if dx_session_runtime_matches "$SID" "$TOKEN"; then
  fail "finished lease still matched its owner"
fi
if find "$DX_STATE_DIR" -maxdepth 1 -name ".${SID}.runtime.tmp.*" -print -quit | grep -q .; then
  fail "runtime writer left a temporary file"
fi

MISSING_SID="$(dx_scoped_session_id worktree-ticket-missing)"
assert_eq "legacy-unverifiable" "$(runtime_health "$MISSING_SID")" "missing runtime health"

CORRUPT_SID="$(dx_scoped_session_id worktree-ticket-corrupt)"
CORRUPT_FILE="$(dx_session_runtime_file "$CORRUPT_SID")"
printf '{not-json}\n' > "$CORRUPT_FILE"
chmod 600 "$CORRUPT_FILE"
assert_eq "corrupt" "$(runtime_health "$CORRUPT_SID")" "corrupt runtime health"
if dx_session_runtime_read "$CORRUPT_SID" >/dev/null 2>&1; then
  fail "runtime reader accepted corrupt JSON"
else
  assert_eq "3" "$?" "corrupt read result"
fi

for SCHEMA_VALUE in true 2.0; do
  SCHEMA_SID="$(dx_scoped_session_id "worktree-schema-${SCHEMA_VALUE//./-}")"
  SCHEMA_FILE="$(dx_session_runtime_file "$SCHEMA_SID")"
  SCHEMA_TOKEN="$(dx_session_runtime_start "$SCHEMA_SID" claude "$WORKSPACE" "$$")"
  [[ -n "$SCHEMA_TOKEN" ]] || assert_at $LINENO
  python3 - "$SCHEMA_FILE" "$SCHEMA_VALUE" <<'PY'
import json
import os
import sys
import tempfile

target, raw_value = sys.argv[1:]
with open(target, encoding="utf-8") as source:
    record = json.load(source)
record["schema_version"] = True if raw_value == "true" else 2.0
descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(target))
os.fchmod(descriptor, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as output:
    json.dump(record, output, separators=(",", ":"))
    output.write("\n")
os.replace(temporary, target)
PY
  assert_eq "corrupt" "$(runtime_health "$SCHEMA_SID")" "non-integer schema health"
done

MODE_SID="$(dx_scoped_session_id worktree-runtime-mode)"
MODE_FILE="$(dx_session_runtime_file "$MODE_SID")"
MODE_TOKEN="$(dx_session_runtime_start "$MODE_SID" claude "$WORKSPACE" "$$")"
[[ -n "$MODE_TOKEN" ]] || assert_at $LINENO
chmod 644 "$MODE_FILE"
assert_eq "corrupt" "$(runtime_health "$MODE_SID")" "wrong-mode runtime health"

LINK_SID="$(dx_scoped_session_id worktree-runtime-symlink)"
LINK_FILE="$(dx_session_runtime_file "$LINK_SID")"
LINK_TOKEN="$(dx_session_runtime_start "$LINK_SID" claude "$WORKSPACE" "$$")"
[[ -n "$LINK_TOKEN" ]] || assert_at $LINENO
LINK_TARGET="$TMP_DIR/runtime-symlink-target"
mv "$LINK_FILE" "$LINK_TARGET"
ln -s "$LINK_TARGET" "$LINK_FILE"
assert_eq "corrupt" "$(runtime_health "$LINK_SID")" "symlink runtime health"

HARDLINK_SID="$(dx_scoped_session_id worktree-runtime-hardlink)"
HARDLINK_FILE="$(dx_session_runtime_file "$HARDLINK_SID")"
HARDLINK_TOKEN="$(dx_session_runtime_start "$HARDLINK_SID" claude "$WORKSPACE" "$$")"
[[ -n "$HARDLINK_TOKEN" ]] || assert_at $LINENO
HARDLINK_TARGET="$TMP_DIR/runtime-hardlink-target"
mv "$HARDLINK_FILE" "$HARDLINK_TARGET"
ln "$HARDLINK_TARGET" "$HARDLINK_FILE"
assert_eq "corrupt" "$(runtime_health "$HARDLINK_SID")" "hard-linked runtime health"

LOCK_FIFO_SID="$(dx_scoped_session_id worktree-lock-fifo)"
mkfifo "$(dx_session_runtime_file "$LOCK_FIFO_SID")-lock"
run_start_rejected_promptly "$LOCK_FIFO_SID" 3 lock-fifo

LOCK_SYMLINK_SID="$(dx_scoped_session_id worktree-lock-symlink)"
LOCK_SYMLINK="$(dx_session_runtime_file "$LOCK_SYMLINK_SID")-lock"
LOCK_SYMLINK_TARGET="$TMP_DIR/runtime-lock-symlink-target"
printf 'lock\n' > "$LOCK_SYMLINK_TARGET"
chmod 600 "$LOCK_SYMLINK_TARGET"
ln -s "$LOCK_SYMLINK_TARGET" "$LOCK_SYMLINK"
run_start_rejected_promptly "$LOCK_SYMLINK_SID" 3 lock-symlink

LOCK_DIRECTORY_SID="$(dx_scoped_session_id worktree-lock-directory)"
mkdir "$(dx_session_runtime_file "$LOCK_DIRECTORY_SID")-lock"
run_start_rejected_promptly "$LOCK_DIRECTORY_SID" 3 lock-directory

LOCK_HARDLINK_SID="$(dx_scoped_session_id worktree-lock-hardlink)"
LOCK_HARDLINK="$(dx_session_runtime_file "$LOCK_HARDLINK_SID")-lock"
LOCK_HARDLINK_TARGET="$TMP_DIR/runtime-lock-hardlink-target"
printf 'lock\n' > "$LOCK_HARDLINK_TARGET"
chmod 600 "$LOCK_HARDLINK_TARGET"
ln "$LOCK_HARDLINK_TARGET" "$LOCK_HARDLINK"
run_start_rejected_promptly "$LOCK_HARDLINK_SID" 3 lock-hardlink

LOCK_MODE_SID="$(dx_scoped_session_id worktree-lock-mode)"
LOCK_MODE="$(dx_session_runtime_file "$LOCK_MODE_SID")-lock"
printf 'lock\n' > "$LOCK_MODE"
chmod 644 "$LOCK_MODE"
run_start_rejected_promptly "$LOCK_MODE_SID" 3 lock-wrong-mode

printf 'session runtime core tests passed\n'

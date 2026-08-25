#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-completion-receipt-test.XXXXXX")"
TEST_CHILD_PIDS=""
cleanup() {
  local child_pid
  for child_pid in $TEST_CHILD_PIDS; do
    kill -CONT "$child_pid" 2>/dev/null || true
  done
  for child_pid in $TEST_CHILD_PIDS; do
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

forget_test_child() {
  local completed_pid="$1" child_pid remaining=""
  for child_pid in $TEST_CHILD_PIDS; do
    [[ "$child_pid" == "$completed_pid" ]] && continue
    remaining="${remaining} ${child_pid}"
  done
  TEST_CHILD_PIDS="$remaining"
}

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

COMPLETION_WRAPPER="$ROOT/bin/complete-receipt.sh"

assert_wrapper_rejects() {
  local output_file="$1"
  shift
  if bash "$COMPLETION_WRAPPER" "$@" > "$output_file" 2>&1; then
    printf 'completion wrapper accepted invalid arguments: %s\n' "$*" >&2
    exit 1
  fi
}

assert_generation() {
  [[ "$1" =~ ^[0-9a-f]{32}$ ]] || assert_at "$2"
}

assert_mode_600() {
  assert_eq "600" "$(dx_path_mode "$1")" "$2"
}

write_delayed_receipt() {
  local session_id="$1" generation="$2" issued_at="$3" receipt_file
  receipt_file=$(dx_completion_receipt_file "$session_id" "$generation")
  {
    printf 'version=1\n'
    printf 'session_id=%s\n' "$session_id"
    printf 'mode=lifecycle\n'
    printf 'purpose=phase\n'
    printf 'phase=4\n'
    printf 'generation=%s\n' "$generation"
    printf 'issued_at=%s\n' "$issued_at"
    printf 'completed_at=%s\n' "$(date +%s)"
  } > "$receipt_file"
  chmod 600 "$receipt_file"
}

hold_completion_lock() {
  local lock_file="$1" ready_file="$2" release_file="$3" _attempt
  python3 - "$lock_file" "$ready_file" "$release_file" <<'PY' &
import fcntl
import os
import sys
import time
from pathlib import Path

lock_file, ready_file, release_file = sys.argv[1:]
descriptor = os.open(lock_file, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    Path(ready_file).write_text("ready\n", encoding="utf-8")
    while not Path(release_file).exists():
        time.sleep(0.01)
finally:
    os.close(descriptor)
PY
  LOCK_HOLDER_PID=$!
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${LOCK_HOLDER_PID}"
  for _attempt in {1..500}; do
    [[ -f "$ready_file" ]] && return 0
    kill -0 "$LOCK_HOLDER_PID" 2>/dev/null || break
    sleep 0.01
  done
  assert_file "$ready_file"
}

seed_completion_receipts() {
  local session_id="$1" count="$2"
  python3 - "$DX_LOOP_DIR" "$session_id" "$count" <<'PY'
import os
import sys
from pathlib import Path

loop_dir, session_id, count = sys.argv[1:]
base_dir = Path(loop_dir)
for value in range(int(count)):
    target = base_dir / f"{session_id}.completion-receipt.{value:032x}"
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
PY
}

# Pause the Python operation after it has removed the old expectation but while
# it still owns the completion flock. The stale receipts make that window long
# enough to observe on both CI platforms.
start_stalled_completion_issue() {
  local session_id="$1" phase="$2" output_prefix="$3"
  local _gap_attempt _state_attempt child_state=""
  (
    set +e
    dx_completion_issue "$session_id" lifecycle phase "$phase" \
      > "${output_prefix}.generation"
    printf '%s\n' "$?" > "${output_prefix}.rc"
  ) &
  STALLED_ISSUE_SHELL_PID=$!
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${STALLED_ISSUE_SHELL_PID}"

  for _gap_attempt in {1..5000}; do
    if [[ ! -e "$(dx_completion_expectation_file "$session_id")" ]]; then
      STALLED_ISSUE_PYTHON_PID=$(pgrep -P "$STALLED_ISSUE_SHELL_PID" | head -n 1 || true)
      if [[ -n "$STALLED_ISSUE_PYTHON_PID" ]] && \
        kill -STOP "$STALLED_ISSUE_PYTHON_PID" 2>/dev/null; then
        TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${STALLED_ISSUE_PYTHON_PID}"
        for _state_attempt in {1..500}; do
          child_state=$(ps -o stat= -p "$STALLED_ISSUE_PYTHON_PID" 2>/dev/null | tr -d '[:space:]')
          case "$child_state" in
            T*)
              assert_no_file "$(dx_completion_expectation_file "$session_id")"
              return 0
              ;;
          esac
          sleep 0.01
        done
      fi
      break
    fi
    kill -0 "$STALLED_ISSUE_SHELL_PID" 2>/dev/null || break
    sleep 0.001
  done
  printf 'could not pause completion issue while it held the module lock\n' >&2
  return 1
}

resume_stalled_completion_issue() {
  kill -CONT "$STALLED_ISSUE_PYTHON_PID"
  wait "$STALLED_ISSUE_SHELL_PID"
  forget_test_child "$STALLED_ISSUE_SHELL_PID"
  forget_test_child "$STALLED_ISSUE_PYTHON_PID"
}

SID="completion-core"

# The command placed in provider prompts runs in a clean shell. It carries the
# launch-bound generation as an argument and does not inherit shell functions
# or discover whichever generation happens to be current later.
WRAPPER_SID="completion-wrapper"
WRAPPER_GENERATION=$(dx_completion_issue "$WRAPPER_SID" standalone dxcomplete 6)
env -i \
  HOME="$HOME" \
  DEX_DIR="$ROOT" \
  DX_STATE_DIR="$DX_STATE_DIR" \
  DX_LOOP_DIR="$DX_LOOP_DIR" \
  DX_ARTIFACT_DIR="$DX_ARTIFACT_DIR" \
  DX_TOOL_DIR="$DX_TOOL_DIR" \
  DX_RUN_ROOT="$DX_RUN_ROOT" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$COMPLETION_WRAPPER" "$WRAPPER_SID" "$WRAPPER_GENERATION"
dx_completion_receipt_valid "$WRAPPER_SID" standalone dxcomplete 6 \
  "$WRAPPER_GENERATION" || assert_at "$LINENO"
dx_completion_consume "$WRAPPER_SID" standalone dxcomplete 6 \
  "$WRAPPER_GENERATION"

assert_wrapper_rejects "$TMP_DIR/wrapper-no-args.out"
assert_wrapper_rejects "$TMP_DIR/wrapper-one-arg.out" "$WRAPPER_SID"
assert_wrapper_rejects "$TMP_DIR/wrapper-extra-arg.out" \
  "$WRAPPER_SID" "$WRAPPER_GENERATION" extra
assert_contains "Usage: complete-receipt.sh" "$TMP_DIR/wrapper-no-args.out"

WRAPPER_UNSAFE_GENERATION=$(dx_completion_issue \
  "$WRAPPER_SID" standalone dxcomplete 6)
WRAPPER_SENTINEL="$TMP_DIR/wrapper-argument-was-evaluated"
assert_wrapper_rejects "$TMP_DIR/wrapper-unsafe-session.out" \
  'completion-wrapper$(touch '$WRAPPER_SENTINEL')' "$WRAPPER_UNSAFE_GENERATION"
assert_no_file "$WRAPPER_SENTINEL"
assert_wrapper_rejects "$TMP_DIR/wrapper-unsafe-generation.out" \
  "$WRAPPER_SID" not-a-generation
assert_no_file "$(dx_completion_receipt_file \
  "$WRAPPER_SID" "$WRAPPER_UNSAFE_GENERATION")"
dx_completion_abandon "$WRAPPER_SID"

# A valid expectation and receipt round-trip through the strict schema.
GENERATION_ONE=$(dx_completion_issue "$SID" lifecycle phase 4)
assert_generation "$GENERATION_ONE" "$LINENO"
EXPECTATION_FILE=$(dx_completion_expectation_file "$SID")
RECEIPT_ONE=$(dx_completion_receipt_file "$SID" "$GENERATION_ONE")
LOCK_FILE=$(dx_completion_lock_file "$SID")
assert_file "$EXPECTATION_FILE"
assert_file "$LOCK_FILE"
assert_mode_600 "$EXPECTATION_FILE" "expectation permissions"
assert_mode_600 "$LOCK_FILE" "completion lock permissions"
assert_eq "$GENERATION_ONE" \
  "$(dx_completion_current_generation "$SID" lifecycle phase 4)" \
  "current generation"
EXPECTATION_FIELDS=$(dx_completion_expectation_read "$SID")
IFS=$'\t' read -r MODE PURPOSE PHASE READ_GENERATION ISSUED_AT <<< "$EXPECTATION_FIELDS"
assert_eq "lifecycle" "$MODE" "expectation mode"
assert_eq "phase" "$PURPOSE" "expectation purpose"
assert_eq "4" "$PHASE" "expectation phase"
assert_eq "$GENERATION_ONE" "$READ_GENERATION" "expectation generation"
[[ "$ISSUED_AT" =~ ^[0-9]+$ ]] || assert_at "$LINENO"

assert_rejected "wrong generation cannot write" \
  dx_completion_write_receipt "$SID" "00000000000000000000000000000000"
dx_completion_write_receipt "$SID" "$GENERATION_ONE"
assert_file "$RECEIPT_ONE"
assert_mode_600 "$RECEIPT_ONE" "receipt permissions"
dx_completion_receipt_present "$SID"
dx_completion_receipt_valid "$SID" lifecycle phase 4 "$GENERATION_ONE"
assert_rejected "wrong phase cannot validate" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_ONE"
assert_rejected "wrong purpose cannot validate" \
  dx_completion_receipt_valid "$SID" standalone dxcomplete 6 "$GENERATION_ONE"

# Consumption requires the full versioned contract. A session id by itself can
# neither authorize completion nor silently clean up a legacy marker.
touch "$(dx_complete_file "$SID")"
dx_consume_completion_receipt "$SID" lifecycle phase 4 "$GENERATION_ONE"
assert_no_file "$EXPECTATION_FILE"
assert_no_file "$RECEIPT_ONE"
assert_no_file "$(dx_complete_file "$SID")"
assert_rejected "consumed generation cannot be replayed" \
  dx_completion_write_receipt "$SID" "$GENERATION_ONE"
touch "$(dx_complete_file "$SID")"
assert_rejected "one-argument completion consumption" \
  dx_consume_completion_receipt "$SID"
assert_rejected "generation-omitting completion consumption" \
  dx_consume_completion_receipt "$SID" lifecycle phase 4
assert_file "$(dx_complete_file "$SID")"
dx_completion_abandon "$SID"
assert_no_file "$(dx_complete_file "$SID")"

# Authorization readers reject permissive records. ensure may replace a
# malformed current-user regular expectation, but an existing receipt is never
# repaired in place.
MODE_SID="completion-mode"
MODE_GENERATION=$(dx_completion_issue "$MODE_SID" lifecycle phase 2)
MODE_EXPECTATION=$(dx_completion_expectation_file "$MODE_SID")
chmod 666 "$MODE_EXPECTATION"
assert_rejected "permissive expectation read" \
  dx_completion_expectation_read "$MODE_SID"
MODE_ENSURE=$(dx_completion_ensure "$MODE_SID" lifecycle phase 2)
IFS=$'\t' read -r MODE_ROTATED MODE_KIND <<< "$MODE_ENSURE"
assert_generation "$MODE_ROTATED" "$LINENO"
[[ "$MODE_ROTATED" != "$MODE_GENERATION" ]] || assert_at "$LINENO"
assert_eq "issued" "$MODE_KIND" "permissive expectation rotation"
assert_mode_600 "$MODE_EXPECTATION" "rotated expectation permissions"
dx_completion_write_receipt "$MODE_SID" "$MODE_ROTATED"
MODE_RECEIPT=$(dx_completion_receipt_file "$MODE_SID" "$MODE_ROTATED")
chmod 666 "$MODE_RECEIPT"
assert_rejected "permissive receipt validation" \
  dx_completion_receipt_valid "$MODE_SID" lifecycle phase 2 "$MODE_ROTATED"
chmod 600 "$MODE_RECEIPT"
MODE_LOCK=$(dx_completion_lock_file "$MODE_SID")
chmod 666 "$MODE_LOCK"
assert_rejected "permissive completion lock" dx_completion_cleanup "$MODE_SID"
chmod 600 "$MODE_LOCK"
dx_completion_cleanup "$MODE_SID"

# ensure keeps a matching generation, but every issue, mismatch, or malformed
# regular expectation gets a new one.
ENSURE_FIRST=$(dx_completion_ensure "$SID" standalone dxloop-plan 1)
IFS=$'\t' read -r ENSURE_GENERATION ENSURE_KIND <<< "$ENSURE_FIRST"
assert_generation "$ENSURE_GENERATION" "$LINENO"
assert_eq "issued" "$ENSURE_KIND" "missing expectation issuance"
ENSURE_AGAIN=$(dx_completion_ensure "$SID" standalone dxloop-plan 1)
IFS=$'\t' read -r ENSURE_SAME ENSURE_KIND <<< "$ENSURE_AGAIN"
assert_eq "$ENSURE_GENERATION" "$ENSURE_SAME" "matching expectation generation"
assert_eq "existing" "$ENSURE_KIND" "matching expectation reuse"
ENSURE_CHANGED=$(dx_completion_ensure "$SID" standalone dxloop-prompt prompt-loop)
IFS=$'\t' read -r ENSURE_NEW ENSURE_KIND <<< "$ENSURE_CHANGED"
assert_generation "$ENSURE_NEW" "$LINENO"
[[ "$ENSURE_NEW" != "$ENSURE_GENERATION" ]] || assert_at "$LINENO"
assert_eq "issued" "$ENSURE_KIND" "context change rotates generation"
printf 'version=1\nversion=1\n' > "$EXPECTATION_FILE"
ENSURE_REPAIRED=$(dx_completion_ensure "$SID" standalone dxloop-prompt prompt-loop)
IFS=$'\t' read -r ENSURE_REPAIRED_GENERATION ENSURE_KIND <<< "$ENSURE_REPAIRED"
assert_generation "$ENSURE_REPAIRED_GENERATION" "$LINENO"
[[ "$ENSURE_REPAIRED_GENERATION" != "$ENSURE_NEW" ]] || assert_at "$LINENO"
assert_eq "issued" "$ENSURE_KIND" "malformed regular expectation rotates generation"

# A receipt written after the old generation was consumed cannot satisfy the
# next phase, even if it is otherwise a valid version 1 record.
GENERATION_FOUR=$(dx_completion_issue "$SID" lifecycle phase 4)
EXPECTATION_FIELDS=$(dx_completion_expectation_read "$SID")
IFS=$'\t' read -r _ _ _ _ PHASE_FOUR_ISSUED_AT <<< "$EXPECTATION_FIELDS"
dx_completion_write_receipt "$SID" "$GENERATION_FOUR"
dx_completion_consume "$SID" lifecycle phase 4 "$GENERATION_FOUR"
GENERATION_FIVE=$(dx_completion_issue "$SID" lifecycle phase 5)
write_delayed_receipt "$SID" "$GENERATION_FOUR" "$PHASE_FOUR_ISSUED_AT"
assert_file "$(dx_completion_receipt_file "$SID" "$GENERATION_FOUR")"
assert_rejected "late Phase 4 receipt cannot complete Phase 5" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
dx_completion_write_receipt "$SID" "$GENERATION_FIVE"
dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"

# A tuple-only caller cannot silently bind itself to a newer generation for the
# same phase. Authorization always carries the generation it was issued.
ROTATE_SID="completion-same-tuple"
ROTATE_OLD=$(dx_completion_issue "$ROTATE_SID" lifecycle phase 4)
ROTATE_NEW=$(dx_completion_issue "$ROTATE_SID" lifecycle phase 4)
dx_completion_write_receipt "$ROTATE_SID" "$ROTATE_NEW"
assert_rejected "generation-less validation after same-tuple rotation" \
  dx_completion_receipt_valid "$ROTATE_SID" lifecycle phase 4
assert_rejected "generation-less consume after same-tuple rotation" \
  dx_completion_consume "$ROTATE_SID" lifecycle phase 4
assert_rejected "old generation after same-tuple rotation" \
  dx_completion_receipt_valid "$ROTATE_SID" lifecycle phase 4 "$ROTATE_OLD"
dx_completion_receipt_valid "$ROTATE_SID" lifecycle phase 4 "$ROTATE_NEW"
dx_completion_consume "$ROTATE_SID" lifecycle phase 4 "$ROTATE_NEW"

# Schema parsing rejects missing, duplicate, extra, and malformed fields.
RECEIPT_FIVE=$(dx_completion_receipt_file "$SID" "$GENERATION_FIVE")
cp "$RECEIPT_FIVE" "$TMP_DIR/valid-receipt"
sed '/^completed_at=/d' "$TMP_DIR/valid-receipt" > "$RECEIPT_FIVE"
assert_rejected "missing receipt field" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"
printf 'version=1\n' >> "$RECEIPT_FIVE"
assert_rejected "duplicate receipt field" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"
printf 'extra=value\n' >> "$RECEIPT_FIVE"
assert_rejected "extra receipt field" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"
python3 - "$RECEIPT_FIVE" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
target.write_bytes(target.read_bytes().replace(b"\n", b"\r\n"))
PY
assert_rejected "CRLF receipt schema" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"
python3 - "$RECEIPT_FIVE" <<'PY'
import sys
from pathlib import Path

target = Path(sys.argv[1])
target.write_bytes(target.read_bytes().replace(b"\n", b"\v", 1))
PY
assert_rejected "control-separator receipt schema" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"
python3 - "$RECEIPT_FIVE" <<'PY'
import sys

target = sys.argv[1]
with open(target, "a", encoding="utf-8") as handle:
    handle.write("x" * 5000)
PY
assert_rejected "oversized receipt" \
  dx_completion_receipt_valid "$SID" lifecycle phase 5 "$GENERATION_FIVE"
cp "$TMP_DIR/valid-receipt" "$RECEIPT_FIVE"

# Writers and readers never follow unsafe state entries. Cleanup unlinks
# non-directory entries but refuses to recurse through an unexpected directory.
OUTSIDE_FILE="$TMP_DIR/outside"
printf 'outside sentinel\n' > "$OUTSIDE_FILE"
dx_completion_abandon "$SID"
ln -s "$OUTSIDE_FILE" "$EXPECTATION_FILE"
assert_rejected "symlink expectation" dx_completion_issue "$SID" lifecycle phase 4
assert_eq "outside sentinel" "$(cat "$OUTSIDE_FILE")" "symlink target preservation"
dx_completion_cleanup "$SID"
assert_no_file "$EXPECTATION_FILE"

mkdir "$EXPECTATION_FILE"
assert_rejected "directory expectation" dx_completion_issue "$SID" lifecycle phase 4
assert_rejected "cleanup refuses expectation directory" dx_completion_cleanup "$SID"
assert_rejected "short-form consumption rejects expectation directory" \
  dx_consume_completion_receipt "$SID"
rmdir "$EXPECTATION_FILE"

LEGACY_FILE=$(dx_complete_file "$SID")
mkdir "$LEGACY_FILE"
assert_rejected "short-form consumption rejects legacy directory" \
  dx_consume_completion_receipt "$SID"
rmdir "$LEGACY_FILE"

mkfifo "$EXPECTATION_FILE"
assert_rejected "fifo expectation read returns without blocking" \
  dx_completion_expectation_read "$SID"
assert_rejected "fifo expectation" dx_completion_issue "$SID" lifecycle phase 4
dx_completion_cleanup "$SID"
assert_no_file "$EXPECTATION_FILE"

LOCK_SYMLINK_SID="completion-lock-symlink"
LOCK_SYMLINK_FILE="$DX_LOOP_DIR/${LOCK_SYMLINK_SID}.completion-lock"
ln -s "$OUTSIDE_FILE" "$LOCK_SYMLINK_FILE"
assert_rejected "symlink completion lock" \
  dx_completion_issue "$LOCK_SYMLINK_SID" lifecycle phase 4
assert_eq "outside sentinel" "$(cat "$OUTSIDE_FILE")" "lock symlink target preservation"
rm -f "$LOCK_SYMLINK_FILE"

UNSAFE_GENERATION=$(dx_completion_issue "$SID" lifecycle phase 4)
UNSAFE_RECEIPT=$(dx_completion_receipt_file "$SID" "$UNSAFE_GENERATION")
ln -s "$OUTSIDE_FILE" "$UNSAFE_RECEIPT"
assert_rejected "symlink receipt" \
  dx_completion_write_receipt "$SID" "$UNSAFE_GENERATION"
assert_rejected "symlink receipt is not present authorization" \
  dx_completion_receipt_present "$SID"
assert_eq "outside sentinel" "$(cat "$OUTSIDE_FILE")" "receipt symlink target preservation"
dx_completion_cleanup "$SID"
assert_no_file "$UNSAFE_RECEIPT"

FIFO_GENERATION=$(dx_completion_issue "$SID" lifecycle phase 4)
FIFO_RECEIPT=$(dx_completion_receipt_file "$SID" "$FIFO_GENERATION")
mkfifo "$FIFO_RECEIPT"
assert_rejected "fifo receipt is not present authorization" \
  dx_completion_receipt_present "$SID"
rm -f "$FIFO_RECEIPT"
dx_completion_cleanup "$SID"

DIRECTORY_GENERATION=$(dx_completion_issue "$SID" lifecycle phase 4)
DIRECTORY_RECEIPT=$(dx_completion_receipt_file "$SID" "$DIRECTORY_GENERATION")
mkdir "$DIRECTORY_RECEIPT"
touch "$(dx_complete_file "$SID")"
assert_rejected "directory receipt" \
  dx_completion_write_receipt "$SID" "$DIRECTORY_GENERATION"
assert_rejected "directory receipt is not present authorization" \
  dx_completion_receipt_present "$SID"
assert_rejected "abandon reports unsafe receipt directory" dx_completion_abandon "$SID"
assert_no_file "$(dx_completion_expectation_file "$SID")"
assert_no_file "$(dx_complete_file "$SID")"
[[ -d "$DIRECTORY_RECEIPT" ]] || assert_at "$LINENO"
rmdir "$DIRECTORY_RECEIPT"
dx_completion_cleanup "$SID"

# Receipt ownership is exact. Cleaning session `a` cannot consume the state of
# a longer session whose name happens to start with the receipt prefix.
SHORT_SID="a"
LONG_SID="a.completion-receipt.b"
SHORT_GENERATION=$(dx_completion_issue "$SHORT_SID" lifecycle phase 1)
LONG_GENERATION=$(dx_completion_issue "$LONG_SID" lifecycle phase 1)
dx_completion_write_receipt "$SHORT_SID" "$SHORT_GENERATION"
dx_completion_write_receipt "$LONG_SID" "$LONG_GENERATION"
dx_completion_cleanup "$SHORT_SID"
assert_no_file "$(dx_completion_expectation_file "$SHORT_SID")"
assert_file "$(dx_completion_expectation_file "$LONG_SID")"
assert_file "$(dx_completion_receipt_file "$LONG_SID" "$LONG_GENERATION")"
dx_completion_receipt_valid "$LONG_SID" lifecycle phase 1 "$LONG_GENERATION"

# A junk directory that merely shares the receipt prefix is not session state.
# Detach still revokes the old generation, so resume cannot reuse it.
DETACH_SID="completion-detach"
DETACH_OLD=$(dx_completion_issue "$DETACH_SID" lifecycle phase 4)
DETACH_FIELDS=$(dx_completion_expectation_read "$DETACH_SID")
IFS=$'\t' read -r _ _ _ _ DETACH_ISSUED_AT <<< "$DETACH_FIELDS"
DETACH_JUNK="$DX_LOOP_DIR/${DETACH_SID}.completion-receipt.not-a-generation"
mkdir "$DETACH_JUNK"
touch "$(dx_active_file "$DETACH_SID")" "$(dx_complete_file "$DETACH_SID")"
dx_lifecycle_detach "$DETACH_SID" manual-pause user-prompt
assert_no_file "$(dx_completion_expectation_file "$DETACH_SID")"
assert_no_file "$(dx_complete_file "$DETACH_SID")"
[[ -d "$DETACH_JUNK" ]] || assert_at "$LINENO"
DETACH_ENSURE=$(dx_completion_ensure "$DETACH_SID" lifecycle phase 4)
IFS=$'\t' read -r DETACH_NEW DETACH_KIND <<< "$DETACH_ENSURE"
assert_generation "$DETACH_NEW" "$LINENO"
[[ "$DETACH_NEW" != "$DETACH_OLD" ]] || assert_at "$LINENO"
assert_eq "issued" "$DETACH_KIND" "detach rotates completion generation"
write_delayed_receipt "$DETACH_SID" "$DETACH_OLD" "$DETACH_ISSUED_AT"
assert_rejected "detached generation cannot complete resumed phase" \
  dx_completion_receipt_valid "$DETACH_SID" lifecycle phase 4 "$DETACH_NEW"
dx_completion_write_receipt "$DETACH_SID" "$DETACH_NEW"
dx_completion_receipt_valid "$DETACH_SID" lifecycle phase 4 "$DETACH_NEW"
rmdir "$DETACH_JUNK"
dx_completion_cleanup "$DETACH_SID"

# A recoverable module lock cannot trap a human in the lifecycle. Detach repairs
# the owned lock, revokes under its flock, and starts a fresh generation.
DETACH_FAILURE_SID="completion-detach-failure"
DETACH_FAILURE_OLD=$(dx_completion_issue "$DETACH_FAILURE_SID" lifecycle phase 4)
DETACH_FAILURE_LOCK=$(dx_completion_lock_file "$DETACH_FAILURE_SID")
touch "$(dx_active_file "$DETACH_FAILURE_SID")" \
  "$(dx_complete_file "$DETACH_FAILURE_SID")"
chmod 666 "$DETACH_FAILURE_LOCK"
dx_lifecycle_detach "$DETACH_FAILURE_SID" manual-pause user-prompt
assert_no_file "$(dx_active_file "$DETACH_FAILURE_SID")"
assert_no_file "$(dx_completion_expectation_file "$DETACH_FAILURE_SID")"
assert_no_file "$(dx_complete_file "$DETACH_FAILURE_SID")"
chmod 600 "$DETACH_FAILURE_LOCK"
DETACH_FAILURE_ENSURE=$(dx_completion_ensure "$DETACH_FAILURE_SID" lifecycle phase 4)
IFS=$'\t' read -r DETACH_FAILURE_NEW DETACH_FAILURE_KIND <<< "$DETACH_FAILURE_ENSURE"
[[ "$DETACH_FAILURE_NEW" != "$DETACH_FAILURE_OLD" ]] || assert_at "$LINENO"
assert_eq "issued" "$DETACH_FAILURE_KIND" "bad-lock detach rotates generation"
dx_completion_cleanup "$DETACH_FAILURE_SID"

# Recovery must wait on the same inode when an operation already owns its
# flock. Otherwise detach could report success just before that operation
# publishes a fresh expectation.
DETACH_INFLIGHT_SID="completion-detach-inflight"
dx_completion_issue "$DETACH_INFLIGHT_SID" lifecycle phase 4 >/dev/null
DETACH_INFLIGHT_LOCK=$(dx_completion_lock_file "$DETACH_INFLIGHT_SID")
seed_completion_receipts "$DETACH_INFLIGHT_SID" 50000
start_stalled_completion_issue \
  "$DETACH_INFLIGHT_SID" 5 "$TMP_DIR/detach-inflight-issue"
touch "$(dx_active_file "$DETACH_INFLIGHT_SID")" \
  "$(dx_complete_file "$DETACH_INFLIGHT_SID")"
chmod 666 "$DETACH_INFLIGHT_LOCK"
(
  set +e
  dx_lifecycle_detach "$DETACH_INFLIGHT_SID" manual-pause user-prompt
  printf '%s\n' "$?" > "$TMP_DIR/detach-inflight.rc"
) &
DETACH_INFLIGHT_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${DETACH_INFLIGHT_PID}"
sleep 0.2
assert_no_file "$TMP_DIR/detach-inflight.rc"
resume_stalled_completion_issue
assert_eq "0" "$(cat "$TMP_DIR/detach-inflight-issue.rc")" \
  "in-flight issue status"
DETACH_INFLIGHT_WRITER=$(cat "$TMP_DIR/detach-inflight-issue.generation")
wait "$DETACH_INFLIGHT_PID"
forget_test_child "$DETACH_INFLIGHT_PID"
assert_eq "0" "$(cat "$TMP_DIR/detach-inflight.rc")" \
  "in-flight detach status"
assert_no_file "$(dx_completion_expectation_file "$DETACH_INFLIGHT_SID")"
assert_no_file "$(dx_complete_file "$DETACH_INFLIGHT_SID")"
assert_mode_600 "$DETACH_INFLIGHT_LOCK" "recovered detach lock permissions"
DETACH_INFLIGHT_ENSURE=$(
  dx_completion_ensure "$DETACH_INFLIGHT_SID" lifecycle phase 5
)
IFS=$'\t' read -r DETACH_INFLIGHT_NEW DETACH_INFLIGHT_KIND <<< \
  "$DETACH_INFLIGHT_ENSURE"
[[ "$DETACH_INFLIGHT_NEW" != "$DETACH_INFLIGHT_WRITER" ]] || \
  assert_at "$LINENO"
assert_eq "issued" "$DETACH_INFLIGHT_KIND" \
  "detach revokes in-flight generation"
dx_completion_cleanup "$DETACH_INFLIGHT_SID"

# If an unsafe entry makes absence impossible to prove, detach fails after
# stopping the loop and releases any lifecycle-control lock held by its caller.
DETACH_UNPROVEN_SID="completion-detach-unproven"
DETACH_UNPROVEN_EXPECTATION=$(dx_completion_expectation_file "$DETACH_UNPROVEN_SID")
mkdir "$DETACH_UNPROVEN_EXPECTATION"
touch "$(dx_active_file "$DETACH_UNPROVEN_SID")"
dx_lifecycle_control_lock_acquire "$DETACH_UNPROVEN_SID"
if dx_lifecycle_detach "$DETACH_UNPROVEN_SID" manual-pause user-prompt; then
  printf 'detach succeeded without proving completion revocation\n' >&2
  exit 1
fi
assert_no_file "$(dx_active_file "$DETACH_UNPROVEN_SID")"
[[ ! -d "$(dx_lifecycle_control_lock_dir "$DETACH_UNPROVEN_SID")" ]] || \
  assert_at "$LINENO"
rmdir "$DETACH_UNPROVEN_EXPECTATION"
dx_cleanup_session "$DETACH_UNPROVEN_SID"

# A lock that cannot be safely repaired is never bypassed. Detach still stops
# the loop, reports failure, and releases its caller's lifecycle-control lock.
DETACH_UNSAFE_LOCK_SID="completion-detach-unsafe-lock"
DETACH_UNSAFE_EXPECTATION=$(
  dx_completion_expectation_file "$DETACH_UNSAFE_LOCK_SID"
)
dx_completion_issue "$DETACH_UNSAFE_LOCK_SID" lifecycle phase 4 >/dev/null
DETACH_UNSAFE_LOCK=$(dx_completion_lock_file "$DETACH_UNSAFE_LOCK_SID")
rm -f "$DETACH_UNSAFE_LOCK"
ln -s "$OUTSIDE_FILE" "$DETACH_UNSAFE_LOCK"
touch "$(dx_active_file "$DETACH_UNSAFE_LOCK_SID")"
dx_lifecycle_control_lock_acquire "$DETACH_UNSAFE_LOCK_SID"
assert_rejected "detach rejects unsafe completion lock" \
  dx_lifecycle_detach "$DETACH_UNSAFE_LOCK_SID" manual-pause user-prompt
assert_file "$DETACH_UNSAFE_EXPECTATION"
assert_no_file "$(dx_active_file "$DETACH_UNSAFE_LOCK_SID")"
[[ ! -d "$(dx_lifecycle_control_lock_dir "$DETACH_UNSAFE_LOCK_SID")" ]] || \
  assert_at "$LINENO"
rm -f "$DETACH_UNSAFE_LOCK"
dx_cleanup_session "$DETACH_UNSAFE_LOCK_SID"

# Mutations share the persistent module lock. Whichever waiter runs first, a
# concurrent consume or delayed write cannot remove the newly issued context.
RACE_SID="completion-race"
RACE_OLD=$(dx_completion_issue "$RACE_SID" lifecycle phase 4)
dx_completion_write_receipt "$RACE_SID" "$RACE_OLD"
RACE_LOCK=$(dx_completion_lock_file "$RACE_SID")
RACE_READY="$TMP_DIR/race-consume.ready"
RACE_RELEASE="$TMP_DIR/race-consume.release"
hold_completion_lock "$RACE_LOCK" "$RACE_READY" "$RACE_RELEASE"
(
  set +e
  dx_completion_consume "$RACE_SID" lifecycle phase 4 "$RACE_OLD"
  printf '%s\n' "$?" > "$TMP_DIR/race-consume.rc"
) &
RACE_CONSUME_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${RACE_CONSUME_PID}"
(
  set +e
  dx_completion_issue "$RACE_SID" lifecycle phase 5 > "$TMP_DIR/race-issue.generation"
  printf '%s\n' "$?" > "$TMP_DIR/race-issue.rc"
) &
RACE_ISSUE_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${RACE_ISSUE_PID}"
sleep 0.2
kill -0 "$RACE_CONSUME_PID" 2>/dev/null || assert_at "$LINENO"
kill -0 "$RACE_ISSUE_PID" 2>/dev/null || assert_at "$LINENO"
assert_no_file "$TMP_DIR/race-consume.rc"
assert_no_file "$TMP_DIR/race-issue.rc"
touch "$RACE_RELEASE"
wait "$LOCK_HOLDER_PID"
forget_test_child "$LOCK_HOLDER_PID"
wait "$RACE_CONSUME_PID"
forget_test_child "$RACE_CONSUME_PID"
wait "$RACE_ISSUE_PID"
forget_test_child "$RACE_ISSUE_PID"
assert_eq "0" "$(cat "$TMP_DIR/race-issue.rc")" "concurrent issue status"
RACE_NEW=$(cat "$TMP_DIR/race-issue.generation")
assert_generation "$RACE_NEW" "$LINENO"
assert_eq "$RACE_NEW" \
  "$(dx_completion_current_generation "$RACE_SID" lifecycle phase 5)" \
  "concurrent consume preserves new expectation"

dx_completion_cleanup "$RACE_SID"
RACE_WRITE_OLD=$(dx_completion_issue "$RACE_SID" lifecycle phase 4)
RACE_READY="$TMP_DIR/race-write.ready"
RACE_RELEASE="$TMP_DIR/race-write.release"
hold_completion_lock "$RACE_LOCK" "$RACE_READY" "$RACE_RELEASE"
(
  set +e
  dx_completion_write_receipt "$RACE_SID" "$RACE_WRITE_OLD"
  printf '%s\n' "$?" > "$TMP_DIR/race-write.rc"
) &
RACE_WRITE_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${RACE_WRITE_PID}"
(
  set +e
  dx_completion_issue "$RACE_SID" lifecycle phase 5 > "$TMP_DIR/race-write-issue.generation"
  printf '%s\n' "$?" > "$TMP_DIR/race-write-issue.rc"
) &
RACE_ISSUE_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${RACE_ISSUE_PID}"
sleep 0.2
kill -0 "$RACE_WRITE_PID" 2>/dev/null || assert_at "$LINENO"
kill -0 "$RACE_ISSUE_PID" 2>/dev/null || assert_at "$LINENO"
assert_no_file "$TMP_DIR/race-write.rc"
assert_no_file "$TMP_DIR/race-write-issue.rc"
touch "$RACE_RELEASE"
wait "$LOCK_HOLDER_PID"
forget_test_child "$LOCK_HOLDER_PID"
wait "$RACE_WRITE_PID"
forget_test_child "$RACE_WRITE_PID"
wait "$RACE_ISSUE_PID"
forget_test_child "$RACE_ISSUE_PID"
assert_eq "0" "$(cat "$TMP_DIR/race-write-issue.rc")" "write race issue status"
RACE_WRITE_NEW=$(cat "$TMP_DIR/race-write-issue.generation")
assert_generation "$RACE_WRITE_NEW" "$LINENO"
assert_eq "$RACE_WRITE_NEW" \
  "$(dx_completion_current_generation "$RACE_SID" lifecycle phase 5)" \
  "concurrent write preserves new expectation"
assert_no_file "$(dx_completion_receipt_file "$RACE_SID" "$RACE_WRITE_OLD")"

# Whole-session cleanup uses the same locked recovery when its persistent
# completion lock has a recoverable mode.
CLEANUP_FAILURE_SID="completion-cleanup-failure"
CLEANUP_FAILURE_OLD=$(dx_completion_issue "$CLEANUP_FAILURE_SID" lifecycle phase 4)
CLEANUP_FAILURE_LOCK=$(dx_completion_lock_file "$CLEANUP_FAILURE_SID")
touch "$(dx_complete_file "$CLEANUP_FAILURE_SID")"
chmod 666 "$CLEANUP_FAILURE_LOCK"
dx_cleanup_session "$CLEANUP_FAILURE_SID"
assert_no_file "$(dx_completion_expectation_file "$CLEANUP_FAILURE_SID")"
assert_no_file "$(dx_complete_file "$CLEANUP_FAILURE_SID")"
chmod 600 "$CLEANUP_FAILURE_LOCK"
CLEANUP_FAILURE_ENSURE=$(dx_completion_ensure "$CLEANUP_FAILURE_SID" lifecycle phase 4)
IFS=$'\t' read -r CLEANUP_FAILURE_NEW CLEANUP_FAILURE_KIND <<< "$CLEANUP_FAILURE_ENSURE"
[[ "$CLEANUP_FAILURE_NEW" != "$CLEANUP_FAILURE_OLD" ]] || assert_at "$LINENO"
assert_eq "issued" "$CLEANUP_FAILURE_KIND" "bad-lock cleanup rotates generation"
dx_completion_cleanup "$CLEANUP_FAILURE_SID"

# Whole-session cleanup also waits out an operation that opened the lock before
# its mode changed, then revokes the expectation that operation published.
CLEANUP_INFLIGHT_SID="completion-cleanup-inflight"
dx_completion_issue "$CLEANUP_INFLIGHT_SID" lifecycle phase 4 >/dev/null
CLEANUP_INFLIGHT_LOCK=$(dx_completion_lock_file "$CLEANUP_INFLIGHT_SID")
seed_completion_receipts "$CLEANUP_INFLIGHT_SID" 50000
start_stalled_completion_issue \
  "$CLEANUP_INFLIGHT_SID" 5 "$TMP_DIR/cleanup-inflight-issue"
touch "$(dx_complete_file "$CLEANUP_INFLIGHT_SID")"
chmod 666 "$CLEANUP_INFLIGHT_LOCK"
(
  set +e
  dx_cleanup_session "$CLEANUP_INFLIGHT_SID"
  printf '%s\n' "$?" > "$TMP_DIR/cleanup-inflight.rc"
) &
CLEANUP_INFLIGHT_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${CLEANUP_INFLIGHT_PID}"
sleep 0.2
assert_no_file "$TMP_DIR/cleanup-inflight.rc"
resume_stalled_completion_issue
assert_eq "0" "$(cat "$TMP_DIR/cleanup-inflight-issue.rc")" \
  "in-flight cleanup issue status"
CLEANUP_INFLIGHT_WRITER=$(cat "$TMP_DIR/cleanup-inflight-issue.generation")
wait "$CLEANUP_INFLIGHT_PID"
forget_test_child "$CLEANUP_INFLIGHT_PID"
assert_eq "0" "$(cat "$TMP_DIR/cleanup-inflight.rc")" \
  "in-flight session cleanup status"
assert_no_file "$(dx_completion_expectation_file "$CLEANUP_INFLIGHT_SID")"
assert_no_file "$(dx_complete_file "$CLEANUP_INFLIGHT_SID")"
assert_mode_600 "$CLEANUP_INFLIGHT_LOCK" \
  "recovered session cleanup lock permissions"
CLEANUP_INFLIGHT_ENSURE=$(
  dx_completion_ensure "$CLEANUP_INFLIGHT_SID" lifecycle phase 5
)
IFS=$'\t' read -r CLEANUP_INFLIGHT_NEW CLEANUP_INFLIGHT_KIND <<< \
  "$CLEANUP_INFLIGHT_ENSURE"
[[ "$CLEANUP_INFLIGHT_NEW" != "$CLEANUP_INFLIGHT_WRITER" ]] || \
  assert_at "$LINENO"
assert_eq "issued" "$CLEANUP_INFLIGHT_KIND" \
  "session cleanup revokes in-flight generation"
dx_completion_cleanup "$CLEANUP_INFLIGHT_SID"

CLEANUP_UNPROVEN_SID="completion-cleanup-unproven"
CLEANUP_UNPROVEN_EXPECTATION=$(dx_completion_expectation_file "$CLEANUP_UNPROVEN_SID")
mkdir "$CLEANUP_UNPROVEN_EXPECTATION"
if dx_cleanup_session "$CLEANUP_UNPROVEN_SID"; then
  printf 'session cleanup succeeded without proving completion revocation\n' >&2
  exit 1
fi
rmdir "$CLEANUP_UNPROVEN_EXPECTATION"
dx_cleanup_session "$CLEANUP_UNPROVEN_SID"

# Session cleanup removes the expectation, every old receipt generation, and
# the deprecated marker without touching another session.
CLEAN_GENERATION=$(dx_completion_issue "$SID" child review-pass 3)
dx_completion_write_receipt "$SID" "$CLEAN_GENERATION"
printf 'orphan\n' > "$DX_LOOP_DIR/${SID}.completion-receipt.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
touch "$(dx_complete_file "$SID")"
OTHER_SID="completion-other"
OTHER_GENERATION=$(dx_completion_issue "$OTHER_SID" lifecycle phase 2)
dx_cleanup_session "$SID"
assert_no_file "$(dx_completion_expectation_file "$SID")"
assert_no_file "$(dx_completion_receipt_file "$SID" "$CLEAN_GENERATION")"
assert_no_file "$DX_LOOP_DIR/${SID}.completion-receipt.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_no_file "$(dx_complete_file "$SID")"
assert_file "$(dx_completion_lock_file "$SID")"
assert_file "$(dx_completion_expectation_file "$OTHER_SID")"
assert_eq "$OTHER_GENERATION" \
  "$(dx_completion_current_generation "$OTHER_SID" lifecycle phase 2)" \
  "other session survives cleanup"

# The shared activation wrapper publishes one canonical context and removes
# stale prompt/review residue before a new provider can see it.
ACTIVATE_SID="completion-activate-loop"
printf '%s\n' "stale task" > "$(dx_prompt_file "$ACTIVATE_SID")"
printf '%s\n' "stale findings" > "$(dx_findings_file "$ACTIVATE_SID")"
ACTIVATE_GENERATION=$(bash "$ROOT/bin/activate-loop.sh" \
  "$ACTIVATE_SID" standalone dxloop-prompt prompt-loop)
assert_generation "$ACTIVATE_GENERATION" "$LINENO"
assert_file "$(dx_active_file "$ACTIVATE_SID")"
assert_no_file "$(dx_prompt_file "$ACTIVATE_SID")"
assert_no_file "$(dx_findings_file "$ACTIVATE_SID")"
assert_eq \
  "$(dx_completion_context_config standalone dxloop-prompt prompt-loop \
    "$ACTIVATE_GENERATION")" \
  "$(cat "$(dx_loop_config_file "$ACTIVATE_SID")")" \
  "shared loop activation writes canonical config"
if bash "$ROOT/bin/activate-loop.sh" "$ACTIVATE_SID" standalone \
  dxloop-prompt prompt-loop > "$TMP_DIR/activate-collision.out" 2>&1; then
  fail "loop activation replaced a live context"
fi
if bash "$ROOT/bin/activate-loop.sh" > "$TMP_DIR/activate-args.out" 2>&1; then
  fail "loop activation wrapper accepted missing arguments"
fi
assert_contains "Usage: activate-loop.sh" "$TMP_DIR/activate-args.out"
dx_cleanup_session "$ACTIVATE_SID"

ACTIVATE_CONTROL_SID="completion-activate-control"
ln -s /dev/null "$(dx_lifecycle_control_file "$ACTIVATE_CONTROL_SID")"
if bash "$ROOT/bin/activate-loop.sh" "$ACTIVATE_CONTROL_SID" standalone \
  dxloop-plan 1 > "$TMP_DIR/activate-control.out" 2>&1; then
  fail "loop activation accepted an unsafe control path"
fi
assert_no_file "$(dx_completion_expectation_file "$ACTIVATE_CONTROL_SID")"
rm -f "$(dx_lifecycle_control_file "$ACTIVATE_CONTROL_SID")"

ACTIVATE_BUSY_SID="completion-activate-busy"
ACTIVATE_BUSY_TOKEN=$(dx_phase_busy_begin "$ACTIVATE_BUSY_SID" 3 "live child")
if bash "$ROOT/bin/activate-loop.sh" "$ACTIVATE_BUSY_SID" standalone \
  dxloop-plan 1 > "$TMP_DIR/activate-busy.out" 2>&1; then
  fail "loop activation erased a live review-child fence"
fi
assert_eq "$ACTIVATE_BUSY_TOKEN" \
  "$(dx_phase_busy_token "$ACTIVATE_BUSY_SID" 3)" \
  "live child fence survives activation collision"
dx_phase_busy_acknowledge "$ACTIVATE_BUSY_SID" 3 "$ACTIVATE_BUSY_TOKEN"
dx_phase_busy_finish "$ACTIVATE_BUSY_SID" 3 "$ACTIVATE_BUSY_TOKEN"
dx_cleanup_session "$ACTIVATE_BUSY_SID"

setup_escalation_context() { # <session> <phase>
  local escalation_session="$1" escalation_phase="$2" escalation_generation
  printf '%s\n' "$escalation_phase" > "$(dx_state_file "$escalation_session")"
  printf '%s\n' inline > "$(dx_handoff_mode_file "$escalation_session")"
  escalation_generation=$(dx_completion_issue "$escalation_session" \
    lifecycle phase "$escalation_phase")
  dx_lifecycle_atomic_write "$(dx_loop_config_file "$escalation_session")" \
    "$(dx_completion_context_config lifecycle phase "$escalation_phase" \
      "$escalation_generation")"
  dx_lifecycle_atomic_write "$(dx_active_file "$escalation_session")" active
  printf '%s\n' "$escalation_generation"
}

ESCALATE_SID="completion-agent-escalation"
ESCALATE_GENERATION=$(setup_escalation_context "$ESCALATE_SID" 2)
dx_completion_write_receipt "$ESCALATE_SID" "$ESCALATE_GENERATION"
touch "$(dx_complete_file "$ESCALATE_SID")"
bash "$ROOT/bin/escalate.sh" "$ESCALATE_SID" "$ESCALATE_GENERATION"
assert_file "$(dx_paused_file "$ESCALATE_SID")"
assert_eq "failure-escalation" \
  "$(dx_pause_state_read "$ESCALATE_SID" reason)" \
  "agent escalation reason"
assert_eq "agent-escalation" \
  "$(dx_pause_state_read "$ESCALATE_SID" source)" \
  "agent escalation source"
assert_no_file "$(dx_active_file "$ESCALATE_SID")"
assert_no_file "$(dx_completion_expectation_file "$ESCALATE_SID")"
assert_no_file "$(dx_completion_receipt_file "$ESCALATE_SID" \
  "$ESCALATE_GENERATION")"
assert_no_file "$(dx_complete_file "$ESCALATE_SID")"
assert_no_file "$(dx_lifecycle_control_file "$ESCALATE_SID")"

ESCALATE_RESUME_RECORD=$(dx_lifecycle_resume_completion_context "$ESCALATE_SID")
IFS=$'\t' read -r _ ESCALATE_RESUMED_GENERATION _ _ <<< \
  "$ESCALATE_RESUME_RECORD"
assert_generation "$ESCALATE_RESUMED_GENERATION" "$LINENO"
[[ "$ESCALATE_RESUMED_GENERATION" != "$ESCALATE_GENERATION" ]] || \
  assert_at "$LINENO"
assert_no_file "$(dx_paused_file "$ESCALATE_SID")"
dx_cleanup_session "$ESCALATE_SID"

ESCALATE_RELEASE_SID="completion-agent-escalation-release"
ESCALATE_RELEASE_GENERATION=$(setup_escalation_context \
  "$ESCALATE_RELEASE_SID" 2)
set +e
(
  eval "$(declare -f dx_lifecycle_control_lock_release | \
    sed '1s/^dx_lifecycle_control_lock_release /__test_release_original /')"
  escalation_release_calls=0
  dx_lifecycle_control_lock_release() {
    escalation_release_calls=$((escalation_release_calls + 1))
    [[ "$escalation_release_calls" -ne 1 ]] || return 1
    __test_release_original "$@"
  }
  dx_lifecycle_agent_escalate "$ESCALATE_RELEASE_SID" \
    "$ESCALATE_RELEASE_GENERATION"
)
ESCALATE_RELEASE_RC=$?
set -e
[[ "$ESCALATE_RELEASE_RC" -ne 0 ]] || assert_at "$LINENO"
assert_file "$(dx_paused_file "$ESCALATE_RELEASE_SID")"
assert_no_file "$(dx_active_file "$ESCALATE_RELEASE_SID")"
assert_no_file "$(dx_completion_expectation_file "$ESCALATE_RELEASE_SID")"
assert_no_file "$(dx_lifecycle_control_lock_dir "$ESCALATE_RELEASE_SID")"
dx_cleanup_session "$ESCALATE_RELEASE_SID"

ESCALATE_STALE_SID="completion-agent-escalation-stale"
ESCALATE_STALE_OLD=$(setup_escalation_context "$ESCALATE_STALE_SID" 4)
ESCALATE_STALE_NEW=$(dx_completion_issue "$ESCALATE_STALE_SID" \
  lifecycle phase 4)
dx_lifecycle_atomic_write "$(dx_loop_config_file "$ESCALATE_STALE_SID")" \
  "$(dx_completion_context_config lifecycle phase 4 "$ESCALATE_STALE_NEW")"
if bash "$ROOT/bin/escalate.sh" "$ESCALATE_STALE_SID" \
  "$ESCALATE_STALE_OLD" > "$TMP_DIR/escalate-stale.out" 2>&1; then
  fail "stale generation paused a fresh lifecycle"
fi
assert_file "$(dx_active_file "$ESCALATE_STALE_SID")"
assert_eq "$ESCALATE_STALE_NEW" \
  "$(dx_completion_current_generation "$ESCALATE_STALE_SID" \
    lifecycle phase 4)" \
  "stale escalation preserves fresh authorization"
dx_cleanup_session "$ESCALATE_STALE_SID"

ESCALATE_BUSY_SID="completion-agent-escalation-busy"
ESCALATE_BUSY_GENERATION=$(setup_escalation_context "$ESCALATE_BUSY_SID" 3)
ESCALATE_BUSY_TOKEN=$(dx_phase_busy_begin "$ESCALATE_BUSY_SID" 3 \
  "review child")
bash "$ROOT/bin/escalate.sh" "$ESCALATE_BUSY_SID" \
  "$ESCALATE_BUSY_GENERATION"
dx_phase_busy_cancel_requested "$ESCALATE_BUSY_SID" 3 || assert_at "$LINENO"
dx_phase_busy_acknowledge "$ESCALATE_BUSY_SID" 3 "$ESCALATE_BUSY_TOKEN"
dx_phase_busy_finish "$ESCALATE_BUSY_SID" 3 "$ESCALATE_BUSY_TOKEN"
dx_cleanup_session "$ESCALATE_BUSY_SID"

ESCALATE_PAUSE_DIR_SID="completion-agent-escalation-pause-dir"
ESCALATE_PAUSE_DIR_GENERATION=$(setup_escalation_context \
  "$ESCALATE_PAUSE_DIR_SID" 1)
mkdir "$(dx_paused_file "$ESCALATE_PAUSE_DIR_SID")"
if bash "$ROOT/bin/escalate.sh" "$ESCALATE_PAUSE_DIR_SID" \
  "$ESCALATE_PAUSE_DIR_GENERATION" > "$TMP_DIR/escalate-pause-dir.out" 2>&1; then
  fail "escalation reported success without publishing a pause marker"
fi
assert_no_file "$(dx_active_file "$ESCALATE_PAUSE_DIR_SID")"
assert_no_file "$(dx_completion_expectation_file "$ESCALATE_PAUSE_DIR_SID")"
rmdir "$(dx_paused_file "$ESCALATE_PAUSE_DIR_SID")"
dx_cleanup_session "$ESCALATE_PAUSE_DIR_SID"

ESCALATE_BUSY_DIR_SID="completion-agent-escalation-busy-dir"
ESCALATE_BUSY_DIR_GENERATION=$(setup_escalation_context \
  "$ESCALATE_BUSY_DIR_SID" 3)
mkdir "$(dx_phase_busy_file "$ESCALATE_BUSY_DIR_SID" 3)"
if bash "$ROOT/bin/escalate.sh" "$ESCALATE_BUSY_DIR_SID" \
  "$ESCALATE_BUSY_DIR_GENERATION" > "$TMP_DIR/escalate-busy-dir.out" 2>&1; then
  fail "escalation reported a clean detach with an unknown review-child fence"
fi
assert_no_file "$(dx_active_file "$ESCALATE_BUSY_DIR_SID")"
assert_no_file "$(dx_completion_expectation_file "$ESCALATE_BUSY_DIR_SID")"
assert_file "$(dx_paused_file "$ESCALATE_BUSY_DIR_SID")"
rmdir "$(dx_phase_busy_file "$ESCALATE_BUSY_DIR_SID" 3)"
dx_cleanup_session "$ESCALATE_BUSY_DIR_SID"

ESCALATE_BUSY_LINK_SID="completion-agent-escalation-busy-link"
ESCALATE_BUSY_LINK_GENERATION=$(setup_escalation_context \
  "$ESCALATE_BUSY_LINK_SID" 3)
ln -s /dev/null "$(dx_phase_busy_file "$ESCALATE_BUSY_LINK_SID" 3)"
if bash "$ROOT/bin/escalate.sh" "$ESCALATE_BUSY_LINK_SID" \
  "$ESCALATE_BUSY_LINK_GENERATION" > "$TMP_DIR/escalate-busy-link.out" 2>&1; then
  fail "escalation reported a clean detach with an unsafe review-child fence"
fi
assert_no_file "$(dx_active_file "$ESCALATE_BUSY_LINK_SID")"
assert_no_file "$(dx_completion_expectation_file "$ESCALATE_BUSY_LINK_SID")"
assert_file "$(dx_paused_file "$ESCALATE_BUSY_LINK_SID")"
rm -f "$(dx_phase_busy_file "$ESCALATE_BUSY_LINK_SID" 3)"
dx_cleanup_session "$ESCALATE_BUSY_LINK_SID"

CHILD_RESUME_SID="completion-child-resume"
CHILD_RESUME_GENERATION=$(dx_completion_loop_activate "$CHILD_RESUME_SID" \
  child review-pass 3)
if dx_lifecycle_resume_completion_context "$CHILD_RESUME_SID" \
  > "$TMP_DIR/child-resume.out" 2>&1; then
  fail "a review child was resumed as a generic loop"
fi
assert_eq "$CHILD_RESUME_GENERATION" \
  "$(dx_completion_current_generation "$CHILD_RESUME_SID" child \
    review-pass 3)" \
  "rejected child resume preserves its generation"
dx_cleanup_session "$CHILD_RESUME_SID"

# The module is sourced safely by both shells used by Dex.
bash -c 'source "$1/lib/common.sh"; dx_completion_current_generation "$2" lifecycle phase 2 >/dev/null' \
  _ "$ROOT" "$OTHER_SID"
zsh -fc 'source "$1/lib/common.sh"; dx_completion_current_generation "$2" lifecycle phase 2 >/dev/null' \
  _ "$ROOT" "$OTHER_SID"

printf 'completion receipt tests passed\n'

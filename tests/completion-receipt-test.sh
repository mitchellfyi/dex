#!/usr/bin/env bash
set -euo pipefail

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

# The strict form consumes only the matching versioned contract. Until every
# caller has migrated, the one-argument compatibility form reports successful
# cleanup while removing stale legacy and versioned state.
touch "$(dx_complete_file "$SID")"
dx_consume_completion_receipt "$SID" lifecycle phase 4 "$GENERATION_ONE"
assert_no_file "$EXPECTATION_FILE"
assert_no_file "$RECEIPT_ONE"
assert_no_file "$(dx_complete_file "$SID")"
assert_rejected "consumed generation cannot be replayed" \
  dx_completion_write_receipt "$SID" "$GENERATION_ONE"
touch "$(dx_complete_file "$SID")"
dx_consume_completion_receipt "$SID"
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
assert_rejected "compatibility cleanup refuses expectation directory" \
  dx_consume_completion_receipt "$SID"
rmdir "$EXPECTATION_FILE"

LEGACY_FILE=$(dx_complete_file "$SID")
mkdir "$LEGACY_FILE"
assert_rejected "compatibility cleanup refuses legacy directory" \
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

# The module is sourced safely by both shells used by Dex.
bash -c 'source "$1/lib/common.sh"; dx_completion_current_generation "$2" lifecycle phase 2 >/dev/null' \
  _ "$ROOT" "$OTHER_SID"
zsh -fc 'source "$1/lib/common.sh"; dx_completion_current_generation "$2" lifecycle phase 2 >/dev/null' \
  _ "$ROOT" "$OTHER_SID"

printf 'completion receipt tests passed\n'

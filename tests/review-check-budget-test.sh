#!/usr/bin/env bash
# The check runner's three budgets: queue time, the execution budget it reports
# rather than enforces, and the hard ceiling that is the only deadline.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-check-budget.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity" DEX_REVIEW_MAX_ACTIVE_CHECKS=1
export DEX_SESSION_ID=check-budget-session
export DEX_REVIEW_CHECK_CACHE_SESSION=check-budget-owner
export DEX_REVIEW_CRITERIA_BINDING=standalone
source "$ROOT/lib/common.sh"
export DEX_REVIEW_POLICY_BINDING
DEX_REVIEW_POLICY_BINDING=$(dx_review_policy_binding 1 2 3)
git init -q -b main "$TMP_DIR/repo"
cd "$TMP_DIR/repo"
git config user.email dex-test@example.com
git config user.name 'Dex Test'
printf '%s\n' original > app.txt
git add app.txt
git commit -qm 'test: initialize fixture'
python3 - "$TMP_DIR" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, script, mode in [
    ('slow-pass', 'sleep 3; echo ran >> "$1"', 'snapshot'),
    ('slow-fail', 'sleep 3; echo ran >> "$1"; exit 9', 'snapshot'),
    ('ceiling', 'sleep 30; echo ran >> "$1"', 'snapshot'),
    ('quick', 'echo ran >> "$1"', 'never'),
]:
    (root / (name + '.json')).write_text(json.dumps({
        'name': name, 'argv': ['bash', '-c', script, 'check', str(root / (name + '.runs'))],
        'cache': mode, 'inputs': [], 'tools': [],
    }))
PY
CHECK_POOL="$TMP_DIR/capacity/checks"
runs_in() {
  if [[ -f "$1" ]]; then
    wc -l < "$1" | tr -d ' '
  else
    printf '0\n'
  fi
}
# Has a runner joined the check queue? Its waiter record carries its own token,
# so the glob is the only name the test can know. An unmatched glob is the
# literal pattern here, which is not a file, so the answer is simply no.
queued_record() {
  local record
  for record in "$CHECK_POOL"/wait-check-*; do
    if [[ -f "$record" ]]; then
      return 0
    fi
  done
  return 1
}

# A command that outruns its execution budget is reported, not discarded: the
# runner says so while it is still running, and records the real result.
#
# The ceiling is pinned well clear of the command. Left at its 4× default it
# would be 4 seconds here, which a loaded host reaches: the runner's own
# supervisor fork, PPID probe, python3 start and token sweep cost about a
# second around a 3-second sleep. The ceiling has its own case below; these two
# are about the budget. Both slow-pass runs must pass the same environment, or
# the second one is a different cache key and never reuses the first.
check_exit=0
DEX_REVIEW_CHECK_TIMEOUT=1 DEX_REVIEW_CHECK_HARD_TIMEOUT=60 \
  bash "$ROOT/bin/review-check.sh" \
  "$TMP_DIR/slow-pass.json" > "$TMP_DIR/slow-pass.log" 2>&1 || check_exit=$?
assert_eq 0 "$check_exit" 'a late command keeps its real exit code'
assert_contains 'over-budget' "$TMP_DIR/slow-pass.log"
assert_contains 'still running' "$TMP_DIR/slow-pass.log"
assert_contains ', over-budget; reusable for these inputs' "$TMP_DIR/slow-pass.log"
over_seconds=$(sed -n 's/.*passed (\([0-9][0-9]*\) seconds, over-budget.*/\1/p' \
  "$TMP_DIR/slow-pass.log")
[[ "$over_seconds" =~ ^[0-9]+$ && "$over_seconds" -ge 3 ]] || assert_at $LINENO
assert_eq 1 "$(runs_in "$TMP_DIR/slow-pass.runs")" 'the command ran once'

# It is cached like any other receipt, so the next wave reuses it.
DEX_REVIEW_CHECK_TIMEOUT=1 DEX_REVIEW_CHECK_HARD_TIMEOUT=60 \
  bash "$ROOT/bin/review-check.sh" \
  "$TMP_DIR/slow-pass.json" > "$TMP_DIR/slow-pass-reuse.log" 2>&1
assert_contains 'reused passing check' "$TMP_DIR/slow-pass-reuse.log"
assert_eq 1 "$(runs_in "$TMP_DIR/slow-pass.runs")" 'an over-budget pass is reusable'

# A late failure is still that command's failure, with its own exit code.
check_exit=0
DEX_REVIEW_CHECK_TIMEOUT=1 DEX_REVIEW_CHECK_HARD_TIMEOUT=60 \
  bash "$ROOT/bin/review-check.sh" \
  "$TMP_DIR/slow-fail.json" > "$TMP_DIR/slow-fail.log" 2>&1 || check_exit=$?
assert_eq 9 "$check_exit" 'a late failure keeps its own exit code'
assert_contains 'failed (9) after' "$TMP_DIR/slow-fail.log"
assert_contains 'over-budget' "$TMP_DIR/slow-fail.log"

# The hard ceiling is the only deadline that stops a command.
check_exit=0
DEX_REVIEW_CHECK_TIMEOUT=1 DEX_REVIEW_CHECK_HARD_TIMEOUT=2 \
  bash "$ROOT/bin/review-check.sh" "$TMP_DIR/ceiling.json" \
  > "$TMP_DIR/ceiling.log" 2>&1 || check_exit=$?
assert_eq 124 "$check_exit" 'the hard ceiling stops the command'
assert_contains 'hard ceiling' "$TMP_DIR/ceiling.log"
assert_eq 0 "$(runs_in "$TMP_DIR/ceiling.runs")" 'a stopped command publishes nothing'
assert_eq 0 "$(DX_REVIEW_CAPACITY_DIR="$CHECK_POOL" dx_review_capacity_active_count)" \
  'the lease is released after the ceiling'

# Queue waiting is a different answer from a failed command. With a cap set and
# spent, nothing ran, and the runner says so with `queued` and exit 75.
DX_REVIEW_CAPACITY_DIR="$CHECK_POOL" dx_review_capacity_enqueue queue-holder queue-holder
DX_REVIEW_CAPACITY_DIR="$CHECK_POOL" dx_review_capacity_try_acquire queue-holder queue-holder 1
check_exit=0
DEX_REVIEW_CHECK_QUEUE_TIMEOUT=1 bash "$ROOT/bin/review-check.sh" \
  "$TMP_DIR/quick.json" > "$TMP_DIR/queued.log" 2>&1 || check_exit=$?
assert_eq 75 "$check_exit" 'a spent queue budget is queued, not a verdict'
assert_contains 'queued — the check pool did not admit it within 1s' "$TMP_DIR/queued.log"
assert_contains 'nothing ran' "$TMP_DIR/queued.log"
assert_eq 0 "$(runs_in "$TMP_DIR/quick.runs")" 'a queued check runs nothing'

# Every heartbeat says where the queue stands and how old the running work is.
check_exit=0
DEX_REVIEW_CHECK_QUEUE_TIMEOUT=6 DEX_REVIEW_CHECK_HEARTBEAT_SECONDS=1 \
  bash "$ROOT/bin/review-check.sh" "$TMP_DIR/quick.json" \
  > "$TMP_DIR/heartbeat.log" 2>&1 || check_exit=$?
assert_eq 75 "$check_exit" 'the cap still applies while heartbeats print'
assert_contains 'queued behind 1, oldest started ' "$TMP_DIR/heartbeat.log"
heartbeats=$(grep -c 'queued behind' "$TMP_DIR/heartbeat.log" | tr -d ' ' || true)
[[ "$heartbeats" -ge 2 ]] || assert_at $LINENO

# Without a cap the runner waits for the pool. The execution budget used to end
# the wait; an agent that cannot wait is an agent that runs the gate itself.
DEX_REVIEW_CHECK_TIMEOUT=1 DEX_REVIEW_CHECK_HEARTBEAT_SECONDS=1 \
  bash "$ROOT/bin/review-check.sh" "$TMP_DIR/quick.json" \
  > "$TMP_DIR/waited.log" 2>&1 &
waited_pid=$!
# Release only once the runner is demonstrably in the queue and has said so. A
# fixed sleep races its startup: admitted before the first heartbeat, there is
# nothing left to assert about waiting.
attempt=0
while ! { queued_record \
  && grep -Fq 'queued behind' "$TMP_DIR/waited.log" 2>/dev/null; } \
  && [[ "$attempt" -lt 600 ]]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
grep -Fq 'queued behind' "$TMP_DIR/waited.log" 2>/dev/null || assert_at $LINENO
DX_REVIEW_CAPACITY_DIR="$CHECK_POOL" dx_review_capacity_release queue-holder
check_exit=0
wait "$waited_pid" || check_exit=$?
assert_eq 0 "$check_exit" 'the execution budget no longer ends a queue wait'
assert_contains 'queued behind 1' "$TMP_DIR/waited.log"
assert_eq 1 "$(runs_in "$TMP_DIR/quick.runs")" 'the check runs once the pool admits it'
assert_eq 0 "$(DX_REVIEW_CAPACITY_DIR="$CHECK_POOL" dx_review_capacity_active_count)" \
  'no lease outlives the runner'
dx_cleanup_session check-budget-owner
printf '%s\n' 'review check budget tests passed'

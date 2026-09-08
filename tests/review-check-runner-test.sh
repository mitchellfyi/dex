#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-check.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity" DEX_REVIEW_MAX_ACTIVE_CHECKS=1
export DEX_SESSION_ID=review-check-pass-one DEX_REVIEW_CHECK_CACHE_SESSION=review-check-owner
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
    ('passing', 'echo ran >> "$1"', 'snapshot'),
    ('failed', 'echo ran >> "$1"; exit 7', 'snapshot'),
    ('mutating', 'echo ran >> "$1"; echo change >> app.txt', 'snapshot'),
    ('never', 'echo ran >> "$1"', 'never'),
    ('timeout', 'sleep 30; echo ran >> "$1"', 'snapshot'),
]:
    (root / (name + '.json')).write_text(json.dumps({
        'name': name, 'argv': ['bash', '-c', script, 'check', str(root / (name + '.runs'))],
        'cache': mode, 'inputs': [], 'tools': [],
    }))
PY
run_check() { bash "$ROOT/bin/review-check.sh" "$TMP_DIR/$1.json"; }
run_check passing > "$TMP_DIR/first.log"
DEX_SESSION_ID=review-check-pass-two run_check passing > "$TMP_DIR/second.log"
assert_eq 1 "$(wc -l < "$TMP_DIR/passing.runs" | tr -d ' ')" 'same check reused across independent waves'
rg -q 'reused passing check' "$TMP_DIR/second.log" || assert_at $LINENO
printf '%s\n' changed >> app.txt
run_check passing >/dev/null
assert_eq 2 "$(wc -l < "$TMP_DIR/passing.runs" | tr -d ' ')" 'changed checkout invalidates'
CHECK_FIXTURE_MODE=strict run_check passing >/dev/null
assert_eq 3 "$(wc -l < "$TMP_DIR/passing.runs" | tr -d ' ')" 'changed environment invalidates'
for check_kind in failed never mutating; do
  for iteration in 1 2; do
    check_exit=0
    run_check "$check_kind" >/dev/null || check_exit=$?
    if [[ "$check_kind" == failed ]]; then
      assert_eq 7 "$check_exit" 'failure preserved'
    else
      assert_eq 0 "$check_exit" 'successful command preserved'
    fi
  done
  assert_eq 2 "$(wc -l < "$TMP_DIR/$check_kind.runs" | tr -d ' ')" "$check_kind is never reused"
done
check_exit=0
DEX_REVIEW_CHECK_TIMEOUT=1 run_check timeout >/dev/null || check_exit=$?
assert_eq 124 "$check_exit" 'timeout preserved'
[[ ! -e "$TMP_DIR/timeout.runs" ]] || assert_at $LINENO
assert_eq 0 "$(DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity/checks" dx_review_capacity_active_count)" 'command lease released'

# A busy model pool does not prevent deterministic work in the check pool.
dx_review_capacity_enqueue model-session model-owner
dx_review_capacity_try_acquire model-session model-owner 1
run_check never >/dev/null
dx_review_capacity_release model-owner

# Two concurrent requests for the same inputs execute only once.
printf '%s\n' concurrent >> app.txt
run_check passing > "$TMP_DIR/concurrent-one.log" &
first_pid=$!
run_check passing > "$TMP_DIR/concurrent-two.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
assert_eq 4 "$(wc -l < "$TMP_DIR/passing.runs" | tr -d ' ')" 'queued request rechecks cache'
dx_cleanup_session review-check-owner
[[ ! -e "$(dx_review_check_cache_dir review-check-owner)" ]] || assert_at $LINENO
printf '%s\n' 'review check runner tests passed'

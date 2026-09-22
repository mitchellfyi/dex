#!/usr/bin/env bash
set -euo pipefail

# `dx review stats` over a synthetic run journal.
#
# The numbers this prints are what a default gets changed by, so they have to
# be right about the two questions that matter: how many passes and minutes a
# loop actually costs, and whether a pass that ran with clean credit already
# banked ever found anything.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-stats.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"

RUNS="$TMP_DIR/runs"
mkdir -p "$RUNS/run_a" "$RUNS/run_b" "$RUNS/run_c" "$RUNS/run_d"

event() {
  printf '{"run_id":"%s","type":"%s","data":%s}\n' "$1" "$2" "$3"
}

# Loop 1: a trivial tier that reached its gate on the first pass.
{
  event run_a review.tier.selected '{"tier":"trivial","profile":"light","required_clean":1}'
  event run_a review.pass.finished '{"result_kind":"clean","clean_before":0,"findings":0,"duration_seconds":120}'
  event run_a review.completed '{"tier":"trivial","reason":"clean_gate_reached"}'
} > "$RUNS/run_a/events.jsonl"

# Loop 2: complex, two fix passes, a clean pass, then a confirmation pass that
# found something — the case the consecutive-clean rule exists for — and a
# notes pass, which is clean and must not be counted as a finding. It never
# reached its gate.
{
  event run_b review.tier.selected '{"tier":"complex","profile":"thorough","required_clean":3}'
  event run_b review.pass.finished '{"result_kind":"findings_fixed","clean_before":0,"findings":3,"duration_seconds":600}'
  event run_b review.pass.finished '{"result_kind":"findings_fixed","clean_before":0,"findings":2,"duration_seconds":600}'
  event run_b review.pass.finished '{"result_kind":"clean","clean_before":0,"findings":0,"duration_seconds":300}'
  event run_b review.pass.finished '{"result_kind":"findings_fixed","clean_before":1,"findings":1,"duration_seconds":300}'
  event run_b review.pass.finished '{"result_kind":"notes","clean_before":1,"findings":2,"duration_seconds":180}'
  event run_b review.paused '{"reason":"wave_budget_exhausted"}'
} > "$RUNS/run_b/events.jsonl"

# Loop 3: one loop that was resumed, so its journal holds two tier selections
# and one escalation. Counting each selection as a loop is what turned this
# host's 66 real loops into 170 two-pass rows. Also a malformed line, which
# must not take the report down.
{
  event run_c review.tier.selected '{"tier":"small","profile":"light","required_clean":1}'
  printf 'not json at all\n'
  event run_c review.pass.finished '{"result_kind":"findings_fixed","clean_before":0,"findings":4,"duration_seconds":900}'
  event run_c review.tier.escalated '{"tier":"complex","profile":"thorough","required_clean":3}'
  event run_c review.pass.finished '{"result_kind":"findings","clean_before":0,"findings":2,"duration_seconds":600}'
  event run_c review.paused '{"reason":"unresolved_findings"}'
  event run_c review.tier.selected '{"tier":"complex","profile":"thorough","required_clean":3}'
  event run_c review.pass.finished '{"result_kind":"blocked","clean_before":0,"duration_seconds":60}'
} > "$RUNS/run_c/events.jsonl"

# Loop 4 and 5: one journal, two finished loops. The first reached its gate and
# the second stalled; merging them would hide the stall behind the first gate.
{
  event run_d review.tier.selected '{"tier":"small","profile":"light","required_clean":1}'
  event run_d review.pass.finished '{"result_kind":"clean","clean_before":0,"findings":0,"duration_seconds":300}'
  event run_d review.completed '{"tier":"small","reason":"clean_gate_reached"}'
  event run_d review.tier.selected '{"tier":"small","profile":"light","required_clean":1}'
  event run_d review.pass.finished '{"result_kind":"findings","clean_before":0,"findings":2,"duration_seconds":600}'
  event run_d review.paused '{"reason":"unresolved_findings"}'
} > "$RUNS/run_d/events.jsonl"

OUT="$TMP_DIR/out"
bash "$ROOT/bin/review.sh" stats --root "$RUNS" > "$OUT" 2>&1 || fail "dx review stats failed"
cat "$OUT"

assert_contains "trivial" "$OUT"
assert_contains "complex" "$OUT"
assert_contains "all" "$OUT"
assert_contains "1st clean" "$OUT"
assert_contains "One loop per run, ended by its completion event" "$OUT"

JSON="$TMP_DIR/out.json"
bash "$ROOT/bin/review.sh" stats --root "$RUNS" --json > "$JSON" 2>&1 \
  || fail "dx review stats --json failed"

field() {
  DX_STATS_TIER="$1" DX_STATS_FIELD="$2" python3 - "$JSON" <<'PY'
import json
import os
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
wanted = os.environ["DX_STATS_TIER"]
for row in rows:
    if row["tier"] == wanted:
        print(row[os.environ["DX_STATS_FIELD"]])
        break
else:
    raise SystemExit(f"no row for {wanted}")
PY
}

assert_eq "1" "$(field trivial loops)" "one trivial loop"
assert_eq "1" "$(field trivial passes_per_loop)" "its single pass"
assert_eq "2" "$(field trivial minutes_per_loop)" "its two minutes"
assert_eq "2" "$(field trivial minutes_to_first_clean)" "clean on that first pass"
assert_eq "1" "$(field trivial loops_reaching_clean)" "so it reached a clean pass"
assert_eq "1" "$(field trivial reached_gate)" "it reached the gate"
assert_eq "0" "$(field trivial passes_after_clean)" "it had no confirmation pass"

assert_eq "2" "$(field complex loops)" \
  "two complex loops — the resumed journal is one loop, not two"
assert_eq "0" "$(field complex reached_gate)" "neither reached its gate"
assert_eq "2" "$(field complex never_reached)" "both are counted as stalled"
assert_eq "4.0" "$(field complex passes_per_loop)" \
  "median passes per complex loop, across five and three"
assert_eq "25" "$(field complex minutes_to_first_clean)" \
  "the one loop that went clean took 25 minutes to get there"
assert_eq "1" "$(field complex loops_reaching_clean)" \
  "the resumed loop never went clean and contributes no time"
assert_eq "2" "$(field complex passes_after_clean)" \
  "two passes ran with clean credit banked"
assert_eq "1" "$(field complex found_after_clean)" \
  "one of those found something (a notes pass does not count as a finding)"
assert_eq "50" "$(field complex found_after_clean_share)" "which is half of them"
assert_eq "1" "$(field complex loops_reversing_clean)" \
  "one loop had an earlier clean reversed"

assert_eq "2" "$(field small loops)" \
  "one journal with two finished loops counts as two"
assert_eq "1" "$(field small reached_gate)" "the first one reached its gate"
assert_eq "1" "$(field small never_reached)" "the second one stalled"
assert_eq "1" "$(field small loops_reaching_clean)" "only the first went clean"
assert_eq "5" "$(field small minutes_to_first_clean)" "after five minutes"

assert_eq "5" "$(field all loops)" "five loops across four journals"
assert_eq "2" "$(field all reached_gate)" "two loops reached their gate"
assert_eq "3" "$(field all never_reached)" "the other three did not"

# An empty or absent journal directory is a reportable condition, not a crash.
mkdir -p "$TMP_DIR/empty"
if bash "$ROOT/bin/review.sh" stats --root "$TMP_DIR/empty" >"$OUT" 2>&1; then
  fail "an empty telemetry directory reported statistics"
fi
assert_contains "no review loops recorded" "$OUT"
if bash "$ROOT/bin/review.sh" stats --root "$TMP_DIR/missing" >"$OUT" 2>&1; then
  fail "a missing telemetry directory reported statistics"
fi
assert_contains "no run telemetry" "$OUT"

# The command tier rules: help works, an unknown subcommand is refused.
bash "$ROOT/bin/review.sh" --help > "$OUT" 2>&1 || fail "dx review --help failed"
assert_contains "Usage: dx review stats" "$OUT"
if bash "$ROOT/bin/review.sh" bogus >"$OUT" 2>&1; then
  fail "an unknown review command was accepted"
fi
assert_contains "Unknown review command" "$OUT"

printf 'review stats tests passed\n'

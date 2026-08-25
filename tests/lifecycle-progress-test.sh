#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-progress.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_FACTORY_SYNC=false
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

ATOMIC_FAILURE_ENV="$TMP_DIR/atomic-failure-env.sh"
cat > "$ATOMIC_FAILURE_ENV" <<'SH'
#!/usr/bin/env bash

__dx_test_fail_phase_publish() {
  if [[ -n "${DX_TEST_REPLACE_PHASE_BEFORE_SYNC:-}" \
    && "${PHASE_STATE_FILE:-}" == "$DX_TEST_REPLACE_PHASE_BEFORE_SYNC" \
    && "$BASH_COMMAND" == "dx_sync_inline_phase_from_state" ]]; then
    trap - DEBUG
    mv "$DX_TEST_REPLACE_PHASE_BEFORE_SYNC" \
      "${DX_TEST_REPLACE_PHASE_BEFORE_SYNC}.target"
    ln -s "${DX_TEST_REPLACE_PHASE_BEFORE_SYNC}.target" \
      "$DX_TEST_REPLACE_PHASE_BEFORE_SYNC"
    return 0
  fi
  if [[ -n "${DX_TEST_FAIL_ATOMIC_TARGET:-}" \
    && "${PHASE_STATE_FILE:-}" == "$DX_TEST_FAIL_ATOMIC_TARGET" \
    && "$BASH_COMMAND" == 'dx_lifecycle_atomic_write "$PHASE_STATE_FILE" "$NEXT_PHASE"' ]]; then
    trap - DEBUG
    rm -f "$DX_TEST_FAIL_ATOMIC_TARGET"
    mkdir "$DX_TEST_FAIL_ATOMIC_TARGET"
  fi
}
trap __dx_test_fail_phase_publish DEBUG
SH
chmod 600 "$ATOMIC_FAILURE_ENV"

TEST_REPO="$TMP_DIR/repo"
git init -q -b main "$TEST_REPO"
git -C "$TEST_REPO" config user.email test@example.com
git -C "$TEST_REPO" config user.name Test
git -C "$TEST_REPO" commit --allow-empty -qm init

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

run_paused_lifecycle() {
  local session_id="$1" pause_reason="$2" output_file="$3"

  set +e
  TEST_REPO="$TEST_REPO" TEST_SESSION_ID="$session_id" TEST_PAUSE_REASON="$pause_reason" \
    zsh -fc '
      source "$DEX_DIR/dx.sh"
      DX_PROVIDER_ENGINE=claude

      unalias __dx_claude 2>/dev/null
      unfunction __dx_claude 2>/dev/null
      __dx_claude() {
        local phase
        for phase in 0 1 2; do
          dx_phase_outcome_record "$TEST_SESSION_ID" "$phase" completed test-fixture \
            "fixture-${phase}-1" gates-passed
        done
        dx_lifecycle_atomic_write "$(dx_state_file "$TEST_SESSION_ID")" 3
        if [[ -n "$TEST_PAUSE_REASON" ]]; then
          dx_write_pause_state "$TEST_SESSION_ID" "$TEST_PAUSE_REASON" phase-loop
          [[ "$TEST_PAUSE_REASON" == "max-iterations" ]] \
            && printf "%s\n" "30:fixture" > "$(dx_loop_file "$TEST_SESSION_ID")"
          dx_lifecycle_atomic_write "$(dx_paused_file "$TEST_SESSION_ID")" paused
        else
          dx_lifecycle_atomic_write "$(dx_paused_file "$TEST_SESSION_ID")" paused
        fi
      }

      state_file=$(dx_state_file "$TEST_SESSION_ID")
      times_file=$(dx_times_file "$TEST_SESSION_ID")
      __dx_run_phases_inline \
        "ticket-progress" "$TEST_REPO" main 0 "$state_file" "$times_file" \
        "dx progress-test" worktree "$TEST_SESSION_ID" "progress test"
    ' > "$output_file" 2>&1
  local status=$?
  set -e

  # This was the last bare `[[ … ]]` in the suite. It happened to work — the
  # status is the function's return value, and both callers invoke it bare
  # under `set -e` — but only for as long as that stayed true. One caller
  # written `run_paused_lifecycle … || something` would have turned the
  # assertion off with nothing to say so. Saying what went wrong is also
  # strictly better than a silent non-zero return.
  [[ "$status" -eq 1 ]] \
    || fail "expected the paused lifecycle to exit 1, got ${status}"
}

MAX_ITER_SESSION="lifecycle-progress-max-iter"
MAX_ITER_OUTPUT="$TMP_DIR/max-iter.out"
run_paused_lifecycle "$MAX_ITER_SESSION" max-iterations "$MAX_ITER_OUTPUT"
[[ ! -e "$(dx_completion_expectation_file "$MAX_ITER_SESSION")" ]] || assert_at $LINENO

# The terminal header must reflect the persisted Phase 3 state, not the Phase 0
# value captured before the provider session started.
grep -Fq "✓ Setup  ✓ Plan  ✓ Implement  → Review" "$MAX_ITER_OUTPUT"
grep -Fq "Paused at Phase 3: Review (max audit iterations reached" "$MAX_ITER_OUTPUT"

MAX_ITER_RUN_ID=$(cat "$DX_STATE_DIR/${MAX_ITER_SESSION}.run-id")
python3 - "$DX_RUN_ROOT/$MAX_ITER_RUN_ID/summary.json" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert summary["status"] == "blocked", summary
assert "max audit iterations reached" in summary["message"].lower(), summary
PY

python3 - "$DX_RUN_ROOT/$MAX_ITER_RUN_ID/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

events = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
blocked = [event for event in events if event.get("type") == "run.blocked"]
assert blocked, events
assert blocked[-1]["data"]["reason"] == "max-iterations", blocked[-1]
PY

LEGACY_SESSION="lifecycle-progress-legacy-pause"
LEGACY_OUTPUT="$TMP_DIR/legacy-pause.out"
run_paused_lifecycle "$LEGACY_SESSION" "" "$LEGACY_OUTPUT"
[[ ! -e "$(dx_completion_expectation_file "$LEGACY_SESSION")" ]] || assert_at $LINENO
grep -Fq "Paused at Phase 3: Review (manual intervention requested)" "$LEGACY_OUTPUT"

# Explicit outcomes distinguish gated completion from human-authorized skips
# and waivers. A prior phase without durable provenance stays visibly unknown.
DISPLAY_SESSION="lifecycle-progress-outcomes"
dx_phase_outcome_record "$DISPLAY_SESSION" 0 completed test-fixture display-0 gates-passed
dx_phase_outcome_record "$DISPLAY_SESSION" 1 waived terminal display-1 human-complete
dx_phase_outcome_record "$DISPLAY_SESSION" 2 skipped terminal display-2 human-jump

DUPLICATE_STATUS=0
dx_phase_outcome_record "$DISPLAY_SESSION" 2 skipped terminal display-2 human-jump \
  || DUPLICATE_STATUS=$?
[[ "$DUPLICATE_STATUS" -eq 3 ]] || assert_at $LINENO
[[ "$(awk -F '\t' '$2 == 2 && $5 == "display-2" { count++ } END { print count + 0 }' \
  "$(dx_phase_outcomes_file "$DISPLAY_SESSION")")" -eq 1 ]]
CONFLICT_STATUS=0
dx_phase_outcome_record "$DISPLAY_SESSION" 2 waived user-prompt display-2 human-complete \
  || CONFLICT_STATUS=$?
[[ "$CONFLICT_STATUS" -eq 1 ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$DISPLAY_SESSION" 2)" == "skipped" ]] || assert_at $LINENO

DISPLAY_OUTPUT="$TMP_DIR/outcomes.out"
DISPLAY_SESSION="$DISPLAY_SESSION" TEST_REPO="$TEST_REPO" zsh -fc '
  source "$DEX_DIR/dx.sh"
  __dx_show_header ticket-progress 4 "$TEST_REPO" main "$DISPLAY_SESSION" worktree
' > "$DISPLAY_OUTPUT" 2>&1
grep -Fq "✓ Setup  ◇ Plan  ↷ Implement  ? Review  → Verify & Commit" "$DISPLAY_OUTPUT"
grep -Fq "↷ skipped by human" "$DISPLAY_OUTPUT"
grep -Fq "◇ marked done by human" "$DISPLAY_OUTPUT"
grep -Fq "? outcome not recorded" "$DISPLAY_OUTPUT"

# Historical sessions can outlive their compact phase TSV. Reconcile only a
# validated phase.completed run event; unrelated journal or PR evidence never
# earns a completion checkmark.
HISTORICAL_SESSION="lifecycle-progress-historical-journal"
HISTORICAL_RUN_ID="run_20260807T000000Z_1_deadbeef"
dx_run_write_for_session "$HISTORICAL_SESSION" "$HISTORICAL_RUN_ID"
mkdir -p "$(dx_run_dir "$HISTORICAL_RUN_ID")"
{
  printf '%s\n' '{"id":"evt_000001_deadbeef","run_id":"run_20260807T000000Z_1_deadbeef","sequence":1,"type":"phase.completed","phase":"0","severity":"info"}'
  printf '%s\n' '{"id":"evt_000002_deadbeef","run_id":"run_20260807T000000Z_1_deadbeef","sequence":2,"type":"phase.completed","phase":"1","severity":"info"}'
  printf '%s\n' '{"id":"evt_000003_deadbeef","run_id":"run_20260807T000000Z_1_deadbeef","sequence":3,"type":"phase.started","phase":"1","severity":"info"}'
  printf '%s\n' '{"id":"evt_000004_deadbeef","run_id":"run_20260807T000000Z_1_deadbeef","sequence":4,"type":"pr.ready","phase":"1","severity":"info"}'
} > "$(dx_run_events_file "$HISTORICAL_RUN_ID")"
HISTORICAL_OUTPUT="$TMP_DIR/historical.out"
HISTORICAL_SESSION="$HISTORICAL_SESSION" TEST_REPO="$TEST_REPO" zsh -fc '
  source "$DEX_DIR/dx.sh"
  __dx_show_header ticket-progress 2 "$TEST_REPO" main "$HISTORICAL_SESSION" worktree
' > "$HISTORICAL_OUTPUT" 2>&1
grep -Fq "✓ Setup  ? Plan  → Implement" "$HISTORICAL_OUTPUT"

HOOK="$ROOT/hooks/phase-loop.sh"

setup_inline() {
  local session_id="$1" phase="$2" generation promise audit_basename min_audits
  dx_lifecycle_atomic_write "$(dx_active_file "$session_id")" active
  dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$session_id")" inline
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" "$phase"
  generation=$(dx_completion_issue "$session_id" lifecycle phase "$phase")
  promise=$(dx_lifecycle_phase_promise "$phase")
  audit_basename=$(dx_lifecycle_phase_audit_basename "$phase")
  min_audits=$(dx_lifecycle_phase_min_audits "$phase")
  dx_lifecycle_atomic_write "$(dx_loop_config_file "$session_id")" \
    "${phase}:${promise}:${ROOT}/prompts/phase-audits/${audit_basename}.md:${min_audits}:lifecycle:phase:${generation}"
  INLINE_GENERATION="$generation"
}

run_hook() {
  local session_id="$1" phase="$2"
  set +e
  HOOK_OUTPUT=$(printf '{"session_id":"claude-progress-test"}' | env \
    DEX_SESSION_ID="$session_id" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase" \
    DEX_PHASE_HANDOFF=inline \
    DX_TEST_FAIL_ATOMIC_TARGET="${DX_TEST_FAIL_ATOMIC_TARGET:-}" \
    DX_TEST_REPLACE_PHASE_BEFORE_SYNC="${DX_TEST_REPLACE_PHASE_BEFORE_SYNC:-}" \
    BASH_ENV="$ATOMIC_FAILURE_ENV" bash "$HOOK" 2>&1)
  HOOK_STATUS=$?
  set -e
}

# A phase inode replaced after initial recovery but before the audit gate must
# close authorization. The hook may not trust the original snapshot or follow
# the replacement symlink into a phase transition.
UNSAFE_SYNC_SESSION="lifecycle-progress-unsafe-sync"
setup_inline "$UNSAFE_SYNC_SESSION" 4
UNSAFE_SYNC_STATE_FILE="$(dx_state_file "$UNSAFE_SYNC_SESSION")"
DX_TEST_REPLACE_PHASE_BEFORE_SYNC="$UNSAFE_SYNC_STATE_FILE"
run_hook "$UNSAFE_SYNC_SESSION" 4
DX_TEST_REPLACE_PHASE_BEFORE_SYNC=""
[[ "$HOOK_STATUS" -eq 2 ]] || assert_at $LINENO
[[ -L "$UNSAFE_SYNC_STATE_FILE" ]] || assert_at $LINENO
[[ ! -e "$(dx_completion_expectation_file "$UNSAFE_SYNC_SESSION")" ]] || assert_at $LINENO
[[ ! -e "$(dx_active_file "$UNSAFE_SYNC_SESSION")" ]] || assert_at $LINENO
grep -Fq "could not safely reconcile the authoritative lifecycle phase" \
  <<<"$HOOK_OUTPUT"

# A failed phase-state publish must consume the exact old receipt and rotate a
# retry generation. Otherwise a delayed writer could complete the next phase.
STALE_SESSION="lifecycle-progress-stale-complete"
setup_inline "$STALE_SESSION" 4
STALE_STATE_FILE="$(dx_state_file "$STALE_SESSION")"
dx_completion_write_receipt "$STALE_SESSION" "$INLINE_GENERATION"

DX_TEST_FAIL_ATOMIC_TARGET="$STALE_STATE_FILE"
run_hook "$STALE_SESSION" 4
DX_TEST_FAIL_ATOMIC_TARGET=""
[[ "$HOOK_STATUS" -eq 2 ]] \
  || fail "expected failed handoff to exit 2, got ${HOOK_STATUS}; hook output: ${HOOK_OUTPUT}"
[[ -d "$STALE_STATE_FILE" ]] || assert_at $LINENO
[[ ! -e "$(dx_completion_receipt_file "$STALE_SESSION" "$INLINE_GENERATION")" ]] || assert_at $LINENO
grep -Fq "consumed completion receipt cannot affect the next phase" <<<"$HOOK_OUTPUT" \
  || fail "expected failed-handoff diagnostic; hook output: ${HOOK_OUTPUT}"

rmdir "$STALE_STATE_FILE"
dx_lifecycle_atomic_write "$STALE_STATE_FILE" 4
run_hook "$STALE_SESSION" 4
[[ "$HOOK_STATUS" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$STALE_STATE_FILE")" == "4" ]] || assert_at $LINENO
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$STALE_SESSION")")" == "4" ]] || assert_at $LINENO
grep -Fq "Phase Audit" <<<"$HOOK_OUTPUT"

# If config/state committed before a crash, target==current completes the same
# human transition instead of discarding it as stale or reusing `.complete`.
RECOVERY_SESSION="lifecycle-progress-control-recovery"
setup_inline "$RECOVERY_SESSION" 4
dx_phase_outcome_record "$RECOVERY_SESSION" 2 completed test-fixture old-phase-2 gates-passed
dx_write_lifecycle_control "$RECOVERY_SESSION" jump 4 terminal "" 2 ""
run_hook "$RECOVERY_SESSION" 4
[[ "$HOOK_STATUS" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$RECOVERY_SESSION")")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_complete_file "$RECOVERY_SESSION")" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_control_file "$RECOVERY_SESSION")" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$RECOVERY_SESSION" 2)" == "skipped" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$RECOVERY_SESSION" 3)" == "skipped" ]] || assert_at $LINENO
[[ "$(awk -F '\t' '$2 == 2 && $5 == "old-phase-2" { count++ } END { print count + 0 }' \
  "$(dx_phase_outcomes_file "$RECOVERY_SESSION")")" -eq 1 ]]
[[ "$(awk -F '\t' '$2 == 2 && $3 == "skipped" { count++ } END { print count + 0 }' \
  "$(dx_phase_outcomes_file "$RECOVERY_SESSION")")" -eq 1 ]]
grep -Fq "Phase 4 (Verify & Commit)" <<<"$HOOK_OUTPUT"

run_hook "$RECOVERY_SESSION" 4
[[ "$HOOK_STATUS" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$RECOVERY_SESSION")")" == "4" ]] || assert_at $LINENO
grep -Fq "Phase Audit" <<<"$HOOK_OUTPUT"

# “Mark current phase done” is a waiver, not a successful gate completion.
WAIVER_SESSION="lifecycle-progress-human-waiver"
setup_inline "$WAIVER_SESSION" 2
dx_write_lifecycle_control "$WAIVER_SESSION" complete 3 terminal "" 2 ""
run_hook "$WAIVER_SESSION" 2
[[ "$HOOK_STATUS" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$WAIVER_SESSION")")" == "3" ]] || assert_at $LINENO
[[ "$(dx_phase_outcome_latest "$WAIVER_SESSION" 2)" == "waived" ]] || assert_at $LINENO

printf 'lifecycle progress tests passed\n'

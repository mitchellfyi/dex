#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HOOK="$ROOT/hooks/phase-loop.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-control-loop.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

run_hook() {
  local sid="$1" phase="$2"
  set +e
  OUT=$(printf '{"session_id":"claude-human-control"}' | env \
    DEX_SESSION_ID="$sid" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase" \
    DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)
  RC=$?
  set -e
}

run_standalone_hook() {
  local sid="$1" phase="$2"
  set +e
  OUT=$(printf '{"session_id":"claude-human-control"}' | env \
    DEX_SESSION_ID="$sid" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE="$phase" \
    bash "$HOOK" 2>&1)
  RC=$?
  set -e
}

setup_inline() {
  local sid="$1" phase="$2" generation promise audit_basename min_audits
  touch "$(dx_active_file "$sid")"
  printf '%s\n' inline > "$(dx_handoff_mode_file "$sid")"
  printf '%s\n' "$phase" > "$(dx_state_file "$sid")"
  generation=$(dx_completion_issue "$sid" lifecycle phase "$phase")
  promise=$(dx_lifecycle_phase_promise "$phase")
  audit_basename=$(dx_lifecycle_phase_audit_basename "$phase")
  min_audits=$(dx_lifecycle_phase_min_audits "$phase")
  printf '%s:%s:%s/prompts/phase-audits/%s.md:%s:lifecycle:phase:%s\n' \
    "$phase" "$promise" "$ROOT" "$audit_basename" "$min_audits" \
    "$generation" > "$(dx_loop_config_file "$sid")"
  INLINE_GENERATION="$generation"
}

setup_standalone() {
  local sid="$1" purpose="$2" phase="$3" generation promise audit_file
  local config
  generation=$(dx_completion_issue "$sid" standalone "$purpose" "$phase")
  case "${purpose}:${phase}" in
    dxcomplete:6)
      promise="DEX_TICKET_COMPLETE"
      audit_file="$ROOT/prompts/phase-audits/6-complete.md"
      ;;
    *) return 1 ;;
  esac
  config="${phase}:${promise}:${audit_file}:1:standalone:${purpose}:${generation}"
  printf '%s\n' "$config" > "$(dx_loop_config_file "$sid")"
  touch "$(dx_active_file "$sid")"
  dx_completion_write_receipt "$sid" "$generation"
  STANDALONE_GENERATION="$generation"
}

# Migrated lifecycle phases accept only the generation embedded in their
# launch config. A legacy marker is removed, rotates that generation, and
# receives one concrete replacement command instead of advancing the phase.
SID="strict-completion-legacy"
setup_inline "$SID" 4
STRICT_OLD=$(dx_completion_issue "$SID" lifecycle phase 4)
printf '%s:PHASE_%s_COMPLETE:%s/prompts/phase-audits/%s-review-loop.md:1:lifecycle:phase:%s\n' \
  4 4 "$ROOT" 4 "$STRICT_OLD" > "$(dx_loop_config_file "$SID")"
touch "$(dx_complete_file "$SID")"
run_hook "$SID" 4
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_complete_file "$SID")" ]] || assert_at $LINENO
STRICT_NEW=$(dx_completion_current_generation "$SID" lifecycle phase 4)
[[ "$STRICT_NEW" != "$STRICT_OLD" ]] || assert_at $LINENO
grep -Fq "Legacy completion marker ignored" <<<"$OUT"
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$SID\" \"$STRICT_NEW\"" <<<"$OUT"

# Invalid controls are not the same as no control. A standalone receipt stays
# unconsumed until the malformed path is repaired or removed.
SID="invalid-control-symlink"
setup_standalone "$SID" dxcomplete 6
ln -s /dev/null "$(dx_lifecycle_control_file "$SID")"
run_standalone_hook "$SID" 6
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ -L "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
dx_completion_receipt_valid \
  "$SID" standalone dxcomplete 6 "$STANDALONE_GENERATION" || assert_at $LINENO
grep -q "unreadable or invalid lifecycle control receipt" <<<"$OUT"
rm -f "$(dx_lifecycle_control_file "$SID")"
dx_completion_cleanup "$SID"
rm -f "$(dx_loop_config_file "$SID")" "$(dx_active_file "$SID")"

SID="invalid-control-directory"
setup_standalone "$SID" dxcomplete 6
mkdir "$(dx_lifecycle_control_file "$SID")"
run_standalone_hook "$SID" 6
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ -d "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
dx_completion_receipt_valid \
  "$SID" standalone dxcomplete 6 "$STANDALONE_GENERATION" || assert_at $LINENO
grep -q "unreadable or invalid lifecycle control receipt" <<<"$OUT"
rmdir "$(dx_lifecycle_control_file "$SID")"
dx_completion_cleanup "$SID"
rm -f "$(dx_loop_config_file "$SID")" "$(dx_active_file "$SID")"

SID="human-control-cancel"
setup_inline "$SID" 2
touch "$(dx_complete_file "$SID")" "$(dx_phase_ready_file "$SID" 2)"
dx_write_lifecycle_control "$SID" cancel "" user-prompt "$(printf cancel | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 2
[[ "$RC" -eq 0 ]] || assert_at $LINENO
grep -q "direct human instruction" <<<"$OUT"
[[ -f "$(dx_paused_file "$SID")" ]] || assert_at $LINENO
[[ ! -e "$(dx_complete_file "$SID")" ]] || assert_at $LINENO
if grep -q "Phase 2 Gate" <<<"$OUT"; then
  printf 'cancel reached a phase readiness gate\n' >&2
  exit 1
fi

SID="human-control-jump"
setup_inline "$SID" 2
BUSY_TOKEN=$(dx_phase_busy_begin "$SID" 3 "cross-phase review child")
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf jump | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 2
[[ "$RC" -eq 0 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "2" ]] || assert_at $LINENO
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "2" ]] || assert_at $LINENO
[[ -e "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
[[ -e "$(dx_phase_busy_file "$SID" 3)" ]] || assert_at $LINENO
grep -q "review child must finish" <<<"$OUT"

dx_phase_busy_acknowledge "$SID" 3 "$BUSY_TOKEN"
run_hook "$SID" 2
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]] || assert_at $LINENO
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "4" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
[[ ! -e "$(dx_phase_busy_file "$SID" 3)" ]] || assert_at $LINENO
grep -q "Phase 4 (Verify & Commit)" <<<"$OUT"

# Phase publication precedes activation. If the active path is unsafe, the
# target phase remains authoritative, its fresh generation is revoked, and
# the human control stays available for a retry after the path is repaired.
SID="human-control-activation-failure"
setup_inline "$SID" 2
rm -f "$(dx_active_file "$SID")"
mkdir "$(dx_active_file "$SID")"
dx_write_lifecycle_control "$SID" jump 4 terminal "" 2 ""
run_hook "$SID" 2
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]] || assert_at $LINENO
assert_file "$(dx_lifecycle_control_file "$SID")"
assert_no_file "$(dx_completion_expectation_file "$SID")"
[[ -d "$(dx_active_file "$SID")" ]] || assert_at $LINENO
[[ ! -d "$(dx_lifecycle_control_lock_dir "$SID")" ]] || assert_at $LINENO
grep -q "could not reactivate its loop" <<<"$OUT"
rmdir "$(dx_active_file "$SID")"
run_hook "$SID" 4
[[ "$RC" -eq 2 ]] || assert_at $LINENO
assert_no_file "$(dx_lifecycle_control_file "$SID")"
assert_file "$(dx_active_file "$SID")"
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "4" ]] || \
  assert_at $LINENO

SID="human-control-complete"
setup_inline "$SID" 6
dx_write_lifecycle_control "$SID" complete 7 user-prompt "$(printf '%s' 'done' | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 6
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "7" ]] || assert_at $LINENO
[[ ! -e "$(dx_active_file "$SID")" ]] || assert_at $LINENO
[[ ! -e "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
grep -q "marked complete by direct human instruction" <<<"$OUT"

SID="human-control-review-busy"
setup_inline "$SID" 3
BUSY_TOKEN=$(dx_phase_busy_begin "$SID" 3 "active review child")
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf busy | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 3
[[ "$RC" -eq 0 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]] || assert_at $LINENO
[[ -f "$(dx_paused_file "$SID")" ]] || assert_at $LINENO
[[ -f "$(dx_phase_busy_file "$SID" 3)" ]] || assert_at $LINENO
grep -q "review child must finish" <<<"$OUT"

# Wrapper cleanup may consume the pause receipt, but it does not own the busy
# marker. A later jump remains blocked until the review owner acknowledges its
# matching token.
dx_clear_lifecycle_control "$SID"
rm -f "$(dx_paused_file "$SID")" "$(dx_pause_state_file "$SID")"
dx_write_lifecycle_control "$SID" jump 4 terminal "" 3 ""
run_hook "$SID" 3
[[ "$RC" -eq 0 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]] || assert_at $LINENO
[[ -f "$(dx_phase_busy_file "$SID" 3)" ]] || assert_at $LINENO

dx_phase_busy_acknowledge "$SID" 3 "$BUSY_TOKEN"
run_hook "$SID" 3
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]] || assert_at $LINENO
[[ ! -f "$(dx_phase_busy_file "$SID" 3)" ]] || assert_at $LINENO

SID="human-control-stale"
setup_inline "$SID" 3
STALE_GENERATION="$INLINE_GENERATION"
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf stale | shasum -a 256 | awk '{print $1}')" 2 ""
run_hook "$SID" 3
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]] || assert_at $LINENO
[[ ! -f "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
REFRESHED_GENERATION=$(dx_completion_current_generation "$SID" lifecycle phase 3)
[[ "$REFRESHED_GENERATION" != "$STALE_GENERATION" ]] || assert_at $LINENO
grep -q "ignored a stale human transition" <<<"$OUT"
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$SID\" \"$REFRESHED_GENERATION\"" <<<"$OUT"

SID="human-control-resume-receipt"
setup_inline "$SID" 2
dx_lifecycle_atomic_write "$(dx_paused_file "$SID")" paused
dx_write_pause_state "$SID" "manual-pause" "terminal"
dx_write_lifecycle_control "$SID" resume "" terminal "" 2 ""
run_hook "$SID" 2
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ ! -f "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
[[ ! -d "$(dx_lifecycle_control_lock_dir "$SID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_paused_file "$SID")" ]] || assert_at $LINENO
grep -q "Phase Audit" <<<"$OUT"

SID="human-control-resume-prompt-loop"
PROMPT_RESUME_OLD=$(dx_completion_issue \
  "$SID" standalone dxloop-prompt prompt-loop)
printf 'prompt-loop:PROMPT_COMPLETE:%s/prompts/phase-audits/prompt-loop.md:1:standalone:dxloop-prompt:%s\n' \
  "$ROOT" "$PROMPT_RESUME_OLD" > "$(dx_loop_config_file "$SID")"
dx_lifecycle_atomic_write "$(dx_paused_file "$SID")" paused
dx_write_pause_state "$SID" "manual-pause" "terminal"
dx_write_lifecycle_control "$SID" resume "" terminal "" prompt-loop ""
run_standalone_hook "$SID" prompt-loop
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ ! -f "$(dx_lifecycle_control_file "$SID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_paused_file "$SID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_handoff_mode_file "$SID")" ]] || assert_at $LINENO
PROMPT_RESUME_NEW=$(dx_completion_current_generation \
  "$SID" standalone dxloop-prompt prompt-loop)
[[ "$PROMPT_RESUME_NEW" != "$PROMPT_RESUME_OLD" ]] || assert_at $LINENO
grep -q "Prompt Loop" <<<"$OUT"

SID="human-control-lock-grace"
mkdir "$(dx_lifecycle_control_lock_dir "$SID")"
if dx_lifecycle_control_lock_acquire "$SID" 1; then
  printf 'control lock stole a newly created ownerless lock\n' >&2
  exit 1
fi
[[ -d "$(dx_lifecycle_control_lock_dir "$SID")" ]] || assert_at $LINENO
touch -t 202001010000 "$(dx_lifecycle_control_lock_dir "$SID")"
dx_lifecycle_control_lock_acquire "$SID" 3
dx_lifecycle_control_lock_release "$SID"
[[ ! -e "$(dx_lifecycle_control_lock_dir "$SID")" ]] || assert_at $LINENO

SID="human-control-config-repair"
setup_inline "$SID" 2
printf '4:PHASE_4_COMPLETE:%s/prompts/phase-audits/4-verify.md:1\n' "$ROOT" \
  > "$(dx_loop_config_file "$SID")"
run_hook "$SID" 2
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$(cat "$(dx_state_file "$SID")")" == "2" ]] || assert_at $LINENO
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "2" ]] || assert_at $LINENO
grep -q "Phase Audit" <<<"$OUT"

SID="human-control-normal"
setup_inline "$SID" 2
run_hook "$SID" 2
[[ "$RC" -eq 2 ]] || assert_at $LINENO
grep -q "Phase Audit" <<<"$OUT"

# Completion and a human jump share the transition lock. Whichever commits
# first wins, and the phase/config pair must always describe the same state.
for RACE_INDEX in 1 2 3 4 5 6; do
  SID="human-control-race-${RACE_INDEX}"
  setup_inline "$SID" 0
  dx_completion_write_receipt "$SID" "$INLINE_GENERATION"
  touch "$(dx_phase_ready_file "$SID" 0)"

  (
    dx_write_lifecycle_control "$SID" jump 4 terminal "" "" ""
  ) &
  WRITER_PID=$!
  set +e
  printf '{"session_id":"claude-race-%s"}' "$RACE_INDEX" | env \
    DEX_SESSION_ID="$SID" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=0 \
    DEX_PHASE_HANDOFF=inline bash "$HOOK" > "$TMP_DIR/race-${RACE_INDEX}.out" 2>&1
  HOOK_RC=$?
  wait "$WRITER_PID"
  WRITER_RC=$?
  set -e

  [[ "$HOOK_RC" -eq 2 && "$WRITER_RC" -eq 0 ]] || assert_at $LINENO
  RACE_PHASE=$(cat "$(dx_state_file "$SID")")
  RACE_CONFIG_PHASE=$(cut -d: -f1 "$(dx_loop_config_file "$SID")")
  [[ "$RACE_PHASE" == "1" || "$RACE_PHASE" == "4" ]] || assert_at $LINENO
  [[ "$RACE_CONFIG_PHASE" == "$RACE_PHASE" ]] || assert_at $LINENO
done

printf 'lifecycle control loop tests passed\n'

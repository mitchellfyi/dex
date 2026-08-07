#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

setup_inline() {
  local sid="$1" phase="$2"
  touch "$(dx_active_file "$sid")"
  printf '%s\n' inline > "$(dx_handoff_mode_file "$sid")"
  printf '%s\n' "$phase" > "$(dx_state_file "$sid")"
  printf '%s:PHASE_%s_COMPLETE:%s/prompts/phase-audits/%s-review-loop.md:1\n' \
    "$phase" "$phase" "$ROOT" "$phase" > "$(dx_loop_config_file "$sid")"
}

SID="human-control-cancel"
setup_inline "$SID" 2
touch "$(dx_complete_file "$SID")" "$(dx_phase_ready_file "$SID" 2)"
dx_write_lifecycle_control "$SID" cancel "" user-prompt "$(printf cancel | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 2
[[ "$RC" -eq 0 ]]
grep -q "direct human instruction" <<<"$OUT"
[[ -f "$(dx_paused_file "$SID")" ]]
[[ ! -e "$(dx_complete_file "$SID")" ]]
if grep -q "Phase 2 Gate" <<<"$OUT"; then
  printf 'cancel reached a phase readiness gate\n' >&2
  exit 1
fi

SID="human-control-jump"
setup_inline "$SID" 2
BUSY_TOKEN=$(dx_phase_busy_begin "$SID" 3 "cross-phase review child")
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf jump | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 2
[[ "$RC" -eq 0 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "2" ]]
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "2" ]]
[[ -e "$(dx_lifecycle_control_file "$SID")" ]]
[[ -e "$(dx_phase_busy_file "$SID" 3)" ]]
grep -q "review child must finish" <<<"$OUT"

dx_phase_busy_acknowledge "$SID" 3 "$BUSY_TOKEN"
run_hook "$SID" 2
[[ "$RC" -eq 2 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]]
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "4" ]]
[[ ! -e "$(dx_lifecycle_control_file "$SID")" ]]
[[ ! -e "$(dx_phase_busy_file "$SID" 3)" ]]
grep -q "Phase 4 (Verify & Commit)" <<<"$OUT"

SID="human-control-complete"
setup_inline "$SID" 6
dx_write_lifecycle_control "$SID" complete 7 user-prompt "$(printf '%s' 'done' | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 6
[[ "$RC" -eq 2 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "7" ]]
[[ ! -e "$(dx_active_file "$SID")" ]]
[[ ! -e "$(dx_lifecycle_control_file "$SID")" ]]
grep -q "marked complete by direct human instruction" <<<"$OUT"

SID="human-control-review-busy"
setup_inline "$SID" 3
BUSY_TOKEN=$(dx_phase_busy_begin "$SID" 3 "active review child")
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf busy | shasum -a 256 | awk '{print $1}')"
run_hook "$SID" 3
[[ "$RC" -eq 0 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]]
[[ -f "$(dx_paused_file "$SID")" ]]
[[ -f "$(dx_phase_busy_file "$SID" 3)" ]]
grep -q "review child must finish" <<<"$OUT"

# Wrapper cleanup may consume the pause receipt, but it does not own the busy
# marker. A later jump remains blocked until the review owner acknowledges its
# matching token.
dx_clear_lifecycle_control "$SID"
rm -f "$(dx_paused_file "$SID")" "$(dx_pause_state_file "$SID")"
dx_write_lifecycle_control "$SID" jump 4 terminal "" 3 ""
run_hook "$SID" 3
[[ "$RC" -eq 0 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]]
[[ -f "$(dx_phase_busy_file "$SID" 3)" ]]

dx_phase_busy_acknowledge "$SID" 3 "$BUSY_TOKEN"
run_hook "$SID" 3
[[ "$RC" -eq 2 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "4" ]]
[[ ! -f "$(dx_phase_busy_file "$SID" 3)" ]]

SID="human-control-stale"
setup_inline "$SID" 3
dx_write_lifecycle_control "$SID" jump 4 user-prompt "$(printf stale | shasum -a 256 | awk '{print $1}')" 2 ""
run_hook "$SID" 3
[[ "$RC" -eq 2 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "3" ]]
[[ ! -f "$(dx_lifecycle_control_file "$SID")" ]]
grep -q "Phase Audit" <<<"$OUT"

SID="human-control-resume-receipt"
setup_inline "$SID" 2
touch "$(dx_paused_file "$SID")"
dx_write_pause_state "$SID" "manual-pause" "terminal"
dx_write_lifecycle_control "$SID" resume "" terminal "" 2 ""
run_hook "$SID" 2
[[ "$RC" -eq 2 ]]
[[ ! -f "$(dx_lifecycle_control_file "$SID")" ]]
[[ ! -d "$(dx_lifecycle_control_lock_dir "$SID")" ]]
[[ ! -f "$(dx_paused_file "$SID")" ]]
grep -q "Phase Audit" <<<"$OUT"

SID="human-control-lock-grace"
mkdir "$(dx_lifecycle_control_lock_dir "$SID")"
if dx_lifecycle_control_lock_acquire "$SID" 1; then
  printf 'control lock stole a newly created ownerless lock\n' >&2
  exit 1
fi
[[ -d "$(dx_lifecycle_control_lock_dir "$SID")" ]]
touch -t 202001010000 "$(dx_lifecycle_control_lock_dir "$SID")"
dx_lifecycle_control_lock_acquire "$SID" 3
dx_lifecycle_control_lock_release "$SID"
[[ ! -e "$(dx_lifecycle_control_lock_dir "$SID")" ]]

SID="human-control-config-repair"
setup_inline "$SID" 2
printf '4:PHASE_4_COMPLETE:%s/prompts/phase-audits/4-verify.md:1\n' "$ROOT" \
  > "$(dx_loop_config_file "$SID")"
run_hook "$SID" 2
[[ "$RC" -eq 2 ]]
[[ "$(cat "$(dx_state_file "$SID")")" == "2" ]]
[[ "$(cut -d: -f1 "$(dx_loop_config_file "$SID")")" == "2" ]]
grep -q "Phase Audit" <<<"$OUT"

SID="human-control-normal"
setup_inline "$SID" 2
run_hook "$SID" 2
[[ "$RC" -eq 2 ]]
grep -q "Phase Audit" <<<"$OUT"

# Completion and a human jump share the transition lock. Whichever commits
# first wins, and the phase/config pair must always describe the same state.
for RACE_INDEX in 1 2 3 4 5 6; do
  SID="human-control-race-${RACE_INDEX}"
  setup_inline "$SID" 0
  touch "$(dx_complete_file "$SID")" "$(dx_phase_ready_file "$SID" 0)"

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

  [[ "$HOOK_RC" -eq 2 && "$WRITER_RC" -eq 0 ]]
  RACE_PHASE=$(cat "$(dx_state_file "$SID")")
  RACE_CONFIG_PHASE=$(cut -d: -f1 "$(dx_loop_config_file "$SID")")
  [[ "$RACE_PHASE" == "1" || "$RACE_PHASE" == "4" ]]
  [[ "$RACE_CONFIG_PHASE" == "$RACE_PHASE" ]]
done

printf 'lifecycle control loop tests passed\n'

#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
CONTROL="$ROOT/bin/control.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-control-cli.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit --allow-empty -qm init
cd "$REPO"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
export DEX_SESSION_ID
DEX_SESSION_ID=$(dx_session_id)
printf '%s\n' 2 > "$(dx_state_file "$DEX_SESSION_ID")"
printf '%s\n' inline > "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
INITIAL_GENERATION=$(dx_completion_issue "$DEX_SESSION_ID" lifecycle phase 2)
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$INITIAL_GENERATION" > "$(dx_loop_config_file "$DEX_SESSION_ID")"
touch "$(dx_active_file "$DEX_SESSION_ID")"
printf '%s\n' "claude-owner" > "$(dx_owner_file "$DEX_SESSION_ID")"

bash "$CONTROL" status > "$TMP_DIR/status.out"
grep -q "Phase: 2 (Implement)" "$TMP_DIR/status.out"

for unsafe_control_kind in symlink fifo directory wrong-mode; do
  case "$unsafe_control_kind" in
    symlink) ln -s /dev/null "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    fifo) mkfifo "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    directory) mkdir "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    wrong-mode)
      printf 'version=1\n' > "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
      chmod 0644 "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
      ;;
  esac
  assert_rejected "$LINENO" bash "$CONTROL" status \
    > "$TMP_DIR/unsafe-control-${unsafe_control_kind}.out" 2>&1
  assert_contains "unsafe or unreadable human-control receipt" \
    "$TMP_DIR/unsafe-control-${unsafe_control_kind}.out"
  if [[ -d "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]]; then
    rmdir "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
  else
    rm -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
  fi
done

set +e
bash "$CONTROL" pause unexpected > "$TMP_DIR/extra-arg.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "does not accept arguments" "$TMP_DIR/extra-arg.out"
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO

bash "$CONTROL" pause > "$TMP_DIR/pause.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "pause" ]] || assert_at $LINENO
[[ -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_owner_file "$DEX_SESSION_ID")")" == "claude-owner" ]] || assert_at $LINENO

# An unsafe activation target cannot turn resume into a false success. The
# pause/control remain retryable, while the fresh authorization is revoked.
mkdir "$(dx_active_file "$DEX_SESSION_ID")"
set +e
bash "$CONTROL" resume > "$TMP_DIR/resume-activation-failure.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
assert_contains "Could not create fresh completion authorization" \
  "$TMP_DIR/resume-activation-failure.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "resume" ]] || \
  assert_at $LINENO
assert_file "$(dx_paused_file "$DEX_SESSION_ID")"
assert_no_file "$(dx_completion_expectation_file "$DEX_SESSION_ID")"
assert_file "$(dx_loop_config_file "$DEX_SESSION_ID")"
assert_file "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
rmdir "$(dx_active_file "$DEX_SESSION_ID")"

bash "$CONTROL" resume > "$TMP_DIR/resume.out"
[[ ! -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
RESUME_GENERATION=$(dx_completion_current_generation "$DEX_SESSION_ID" lifecycle phase 2)
[[ "$RESUME_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ "$RESUME_GENERATION" != "$INITIAL_GENERATION" ]] || assert_at $LINENO
[[ "$(cut -d: -f5-7 "$(dx_loop_config_file "$DEX_SESSION_ID")")" == "lifecycle:phase:${RESUME_GENERATION}" ]] || assert_at $LINENO
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$DEX_SESSION_ID\" \"$RESUME_GENERATION\"" "$TMP_DIR/resume.out"

# A wrapper-processed pause keeps a durable pause marker even after its live
# receipt and activation files are gone. Terminal controls can resume or move
# that recorded phase without relaunching the old provider process first.
bash "$CONTROL" pause > "$TMP_DIR/durable-pause.out"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_owner_file "$DEX_SESSION_ID")" \
  "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
bash "$CONTROL" status > "$TMP_DIR/durable-status.out"
grep -q "Lifecycle: paused (manual-pause)" "$TMP_DIR/durable-status.out"
bash "$CONTROL" "done" > "$TMP_DIR/durable-done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
dx_lifecycle_atomic_write "$(dx_paused_file "$DEX_SESSION_ID")" paused
bash "$CONTROL" resume > "$TMP_DIR/durable-resume.out"
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO
DURABLE_GENERATION=$(dx_completion_current_generation "$DEX_SESSION_ID" lifecycle phase 2)
[[ "$DURABLE_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ "$DURABLE_GENERATION" != "$RESUME_GENERATION" ]] || assert_at $LINENO
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$DEX_SESSION_ID\" \"$DURABLE_GENERATION\"" "$TMP_DIR/durable-resume.out"

# A durable metadata record is independently sufficient to hold the pause.
# Status must surface it and resume must consume it under the transition lock.
bash "$CONTROL" pause > "$TMP_DIR/metadata-pause.out"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_paused_file "$DEX_SESSION_ID")"
bash "$CONTROL" status > "$TMP_DIR/metadata-status.out"
assert_contains "Lifecycle: paused (manual-pause)" "$TMP_DIR/metadata-status.out"
bash "$CONTROL" resume > "$TMP_DIR/metadata-resume.out"
assert_no_file "$(dx_paused_file "$DEX_SESSION_ID")"
assert_no_file "$(dx_pause_state_file "$DEX_SESSION_ID")"

# An unsafe metadata inode is an error, not an absent pause that automation may
# overwrite. Both the diagnostic and mutating surfaces stay closed.
printf 'reason=manual-pause\nsource=terminal\n' \
  > "$(dx_pause_state_file "$DEX_SESSION_ID")"
chmod 0644 "$(dx_pause_state_file "$DEX_SESSION_ID")"
assert_rejected "$LINENO" bash "$CONTROL" status \
  > "$TMP_DIR/unsafe-pause-status.out" 2>&1
assert_contains "unsafe or malformed pause state" \
  "$TMP_DIR/unsafe-pause-status.out"
assert_rejected "$LINENO" bash "$CONTROL" resume \
  > "$TMP_DIR/unsafe-pause-resume.out" 2>&1
assert_contains "unsafe or malformed pause state" \
  "$TMP_DIR/unsafe-pause-resume.out"
rm -f "$(dx_pause_state_file "$DEX_SESSION_ID")"

# If a review selection could not be invalidated, ordinary resume cannot
# clear the brake and silently reuse that selection.
SELECTION_BRAKE_SESSION="$(dx_session_repo_key)-selection-brake"
dx_lifecycle_atomic_write "$(dx_state_file "$SELECTION_BRAKE_SESSION")" 3
SELECTION_BRAKE_GENERATION=$(dx_completion_issue \
  "$SELECTION_BRAKE_SESSION" lifecycle phase 3)
printf '3:PHASE_3_COMPLETE:%s/prompts/phase-audits/3-review-loop.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$SELECTION_BRAKE_GENERATION" \
  > "$(dx_loop_config_file "$SELECTION_BRAKE_SESSION")"
dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$SELECTION_BRAKE_SESSION")" inline
dx_lifecycle_pause "$SELECTION_BRAKE_SESSION" \
  assessment-selection-revocation-failed review-loop
assert_rejected "$LINENO" env DEX_SESSION_ID="$SELECTION_BRAKE_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/selection-brake-resume.out" 2>&1
assert_file "$(dx_paused_file "$SELECTION_BRAKE_SESSION")"
assert_eq "assessment-selection-revocation-failed" \
  "$(dx_pause_state_read "$SELECTION_BRAKE_SESSION" reason)" \
  "selection revocation failure stays non-resumable"
assert_no_file "$(dx_completion_expectation_file "$SELECTION_BRAKE_SESSION")"
dx_lifecycle_atomic_write "$(dx_state_file "$SELECTION_BRAKE_SESSION")" 7
assert_rejected "$LINENO" env DEX_SESSION_ID="$SELECTION_BRAKE_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/selection-brake-phase7-resume.out" 2>&1
assert_eq "7" "$(dx_lifecycle_current_phase "$SELECTION_BRAKE_SESSION")" \
  "selection revocation failure cannot use terminal-failure rollback"
assert_file "$(dx_paused_file "$SELECTION_BRAKE_SESSION")"
assert_no_file "$(dx_lifecycle_terminal_commit_file "$SELECTION_BRAKE_SESSION")"
assert_no_file "$(dx_completion_expectation_file "$SELECTION_BRAKE_SESSION")"

bash "$CONTROL" "done" > "$TMP_DIR/done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" expected_phase)" == "2" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "3" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
bash "$CONTROL" jump verify > "$TMP_DIR/jump.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "jump" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "4" ]] || assert_at $LINENO

# An irreparable coordination lock must not produce a false "pause accepted"
# result while the old completion expectation is still live.
dx_clear_lifecycle_control "$DEX_SESSION_ID"
touch "$(dx_active_file "$DEX_SESSION_ID")"
COMPLETION_LOCK=$(dx_completion_lock_file "$DEX_SESSION_ID")
rm -f "$COMPLETION_LOCK"
mkdir "$COMPLETION_LOCK"
set +e
bash "$CONTROL" pause > "$TMP_DIR/unsafe-lock-pause.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "could not prove that completion authorization was revoked" "$TMP_DIR/unsafe-lock-pause.out"
if grep -q "accepted for Phase" "$TMP_DIR/unsafe-lock-pause.out"; then
  printf 'unsafe completion lock produced a false pause success\n' >&2
  exit 1
fi
rmdir "$COMPLETION_LOCK"
dx_completion_abandon "$DEX_SESSION_ID"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_paused_file "$DEX_SESSION_ID")" "$(dx_pause_state_file "$DEX_SESSION_ID")"

# Numeric standalone phases must not be mistaken for lifecycle phases. Resume
# rotates their exact purpose without creating inline handoff state, while
# done/jump remain lifecycle-only controls.
STANDALONE_SESSION_ID="$(dx_session_repo_key)-standalone-control"
STANDALONE_CONFIG=$(dx_loop_config_file "$STANDALONE_SESSION_ID")
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxcomplete 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
printf '7\n' > "$(dx_state_file "$STANDALONE_SESSION_ID")"
touch "$(dx_active_file "$STANDALONE_SESSION_ID")"
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" pause \
  > "$TMP_DIR/standalone-complete-pause.out"
assert_contains "pause accepted for Phase 6" \
  "$TMP_DIR/standalone-complete-pause.out"
assert_file "$(dx_paused_file "$STANDALONE_SESSION_ID")"
assert_no_file "$(dx_completion_expectation_file "$STANDALONE_SESSION_ID")"
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" resume \
  > "$TMP_DIR/standalone-complete-resume.out"
STANDALONE_RESUMED=$(dx_completion_current_generation \
  "$STANDALONE_SESSION_ID" standalone dxcomplete 6)
[[ "$STANDALONE_RESUMED" =~ ^[0-9a-f]{32}$ \
  && "$STANDALONE_RESUMED" != "$STANDALONE_GENERATION" ]] || assert_at $LINENO
assert_eq "standalone:dxcomplete:${STANDALONE_RESUMED}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal preserves dxcomplete context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$STANDALONE_SESSION_ID" \
  bash "$CONTROL" "done" > "$TMP_DIR/standalone-done.out" 2>&1
assert_contains "only to an inline Dex lifecycle" "$TMP_DIR/standalone-done.out"

dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")" "$STANDALONE_CONFIG" \
  "$(dx_state_file "$STANDALONE_SESSION_ID")"
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxloop-plan 1)
printf '1:PHASE_1_COMPLETE:%s/prompts/phase-audits/1-plan.md:1:standalone:dxloop-plan:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
touch "$(dx_active_file "$STANDALONE_SESSION_ID")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$STANDALONE_SESSION_ID" \
  bash "$CONTROL" jump verify > "$TMP_DIR/standalone-jump.out" 2>&1
assert_contains "only to an inline Dex lifecycle" "$TMP_DIR/standalone-jump.out"
assert_eq "standalone:dxloop-plan:${STANDALONE_GENERATION}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal jump preserves dxloop plan context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"

dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")"
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxloop-prompt prompt-loop)
printf 'prompt-loop:PROMPT_COMPLETE:%s/prompts/phase-audits/prompt-loop.md:1:standalone:dxloop-prompt:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
dx_lifecycle_atomic_write "$(dx_paused_file "$STANDALONE_SESSION_ID")" paused
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" resume \
  > "$TMP_DIR/standalone-prompt-resume.out"
STANDALONE_RESUMED=$(dx_completion_current_generation \
  "$STANDALONE_SESSION_ID" standalone dxloop-prompt prompt-loop)
[[ "$STANDALONE_RESUMED" =~ ^[0-9a-f]{32}$ \
  && "$STANDALONE_RESUMED" != "$STANDALONE_GENERATION" ]] || assert_at $LINENO
assert_eq "standalone:dxloop-prompt:${STANDALONE_RESUMED}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal preserves prompt-loop context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"
dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")" "$STANDALONE_CONFIG"

RESUME_RELEASE_SESSION="$(dx_session_repo_key)-resume-release-failure"
RESUME_RELEASE_GENERATION=$(dx_completion_issue \
  "$RESUME_RELEASE_SESSION" standalone dxcomplete 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
  "$ROOT" "$RESUME_RELEASE_GENERATION" \
  > "$(dx_loop_config_file "$RESUME_RELEASE_SESSION")"
dx_lifecycle_atomic_write "$(dx_paused_file "$RESUME_RELEASE_SESSION")" paused
set +e
(
  dx_lifecycle_control_lock_release() { return 1; }
  dx_lifecycle_resume_completion_context "$RESUME_RELEASE_SESSION" >/dev/null
)
RESUME_RELEASE_RC=$?
set -e
[[ "$RESUME_RELEASE_RC" -ne 0 ]] || assert_at $LINENO
assert_no_file "$(dx_completion_expectation_file "$RESUME_RELEASE_SESSION")"
assert_no_file "$(dx_active_file "$RESUME_RELEASE_SESSION")"
assert_file "$(dx_paused_file "$RESUME_RELEASE_SESSION")"
rm -f "$(dx_lifecycle_control_lock_dir "$RESUME_RELEASE_SESSION")/owner"
rmdir "$(dx_lifecycle_control_lock_dir "$RESUME_RELEASE_SESSION")"
rm -f "$(dx_paused_file "$RESUME_RELEASE_SESSION")" \
  "$(dx_pause_state_file "$RESUME_RELEASE_SESSION")" \
  "$(dx_loop_config_file "$RESUME_RELEASE_SESSION")"

# Resume cannot cross a live Phase 3 child fence. The pause remains intact and
# no generation is minted until the exact child token acknowledges quiescence;
# that acknowledgement is then retired in the same resume transaction.
BUSY_RESUME_SESSION="$(dx_session_repo_key)-busy-resume"
dx_lifecycle_atomic_write "$(dx_state_file "$BUSY_RESUME_SESSION")" 3
dx_lifecycle_control_lock_acquire "$BUSY_RESUME_SESSION"
BUSY_RESUME_GENERATION=$(dx_lifecycle_completion_issue_unlocked \
  "$BUSY_RESUME_SESSION" lifecycle phase 3)
dx_lifecycle_atomic_write "$(dx_loop_config_file "$BUSY_RESUME_SESSION")" \
  "$(dx_completion_context_config lifecycle phase 3 "$BUSY_RESUME_GENERATION")"
dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$BUSY_RESUME_SESSION")" inline
dx_lifecycle_atomic_write "$(dx_active_file "$BUSY_RESUME_SESSION")" active
dx_lifecycle_control_lock_release "$BUSY_RESUME_SESSION"
BUSY_RESUME_TOKEN=$(dx_phase_busy_begin "$BUSY_RESUME_SESSION" 3 review-pass)
dx_lifecycle_pause "$BUSY_RESUME_SESSION" manual-pause lifecycle-control
assert_rejected "$LINENO" env DEX_SESSION_ID="$BUSY_RESUME_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/busy-resume-rejected.out" 2>&1
assert_file "$(dx_paused_file "$BUSY_RESUME_SESSION")"
assert_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_completion_expectation_file "$BUSY_RESUME_SESSION")"
dx_phase_busy_acknowledge "$BUSY_RESUME_SESSION" 3 "$BUSY_RESUME_TOKEN"
DEX_SESSION_ID="$BUSY_RESUME_SESSION" bash "$CONTROL" resume \
  > "$TMP_DIR/busy-resume-accepted.out"
BUSY_RESUMED_GENERATION=$(dx_completion_current_generation \
  "$BUSY_RESUME_SESSION" lifecycle phase 3)
[[ "$BUSY_RESUMED_GENERATION" =~ ^[0-9a-f]{32}$ \
  && "$BUSY_RESUMED_GENERATION" != "$BUSY_RESUME_GENERATION" ]] || assert_at $LINENO
assert_no_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_cancel_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_quiesced_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_paused_file "$BUSY_RESUME_SESSION")"

# If the Stop hook applies a terminal transition before the CLI can reactivate
# it, the activation helper reports the committed result without resurrecting
# the completed loop.
ACTIVATION_RACE_SESSION="$(dx_session_repo_key)-terminal-activation-race"
printf '6\n' > "$(dx_state_file "$ACTIVATION_RACE_SESSION")"
ACTIVATION_RACE_COMPLETION=$(dx_completion_issue \
  "$ACTIVATION_RACE_SESSION" lifecycle phase 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$ACTIVATION_RACE_COMPLETION" \
  > "$(dx_loop_config_file "$ACTIVATION_RACE_SESSION")"
printf 'inline\n' > "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")"
touch "$(dx_active_file "$ACTIVATION_RACE_SESSION")"
dx_write_lifecycle_control "$ACTIVATION_RACE_SESSION" complete 7 terminal "" 6 ""
ACTIVATION_RACE_CONTROL="$DX_LIFECYCLE_CONTROL_GENERATION"
dx_completion_abandon "$ACTIVATION_RACE_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$ACTIVATION_RACE_SESSION")" 7
dx_clear_lifecycle_control "$ACTIVATION_RACE_SESSION"
rm -f "$(dx_active_file "$ACTIVATION_RACE_SESSION")" \
  "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")" \
  "$(dx_loop_config_file "$ACTIVATION_RACE_SESSION")"
dx_lifecycle_control_lock_acquire "$ACTIVATION_RACE_SESSION"
dx_lifecycle_terminal_commit_publish_unlocked "$ACTIVATION_RACE_SESSION" \
  "$ACTIVATION_RACE_CONTROL"
dx_lifecycle_control_lock_release "$ACTIVATION_RACE_SESSION"
assert_eq "applied" \
  "$(dx_lifecycle_activate_pending_control "$ACTIVATION_RACE_SESSION" \
    complete 7 6 "$ACTIVATION_RACE_CONTROL")" \
  "already-applied terminal transition"
assert_no_file "$(dx_active_file "$ACTIVATION_RACE_SESSION")"
assert_no_file "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")"

# A terminal lifecycle cannot be complete while any Phase 3 child fence or
# sidecar remains, even when that path is an unsafe inode.
for terminal_busy_path in \
  "$(dx_phase_busy_file "$ACTIVATION_RACE_SESSION" 3)" \
  "$(dx_phase_busy_cancel_file "$ACTIVATION_RACE_SESSION" 3)" \
  "$(dx_phase_busy_quiesced_file "$ACTIVATION_RACE_SESSION" 3)"; do
  mkdir "$terminal_busy_path"
  if dx_lifecycle_terminal_commit_valid "$ACTIVATION_RACE_SESSION"; then
    printf 'terminal proof accepted Phase 3 child-fence residue: %s\n' \
      "$terminal_busy_path" >&2
    exit 1
  fi
  rmdir "$terminal_busy_path"
done
dx_lifecycle_terminal_commit_valid "$ACTIVATION_RACE_SESSION" || assert_at $LINENO

# A crash after Phase 7 publication but before its proof is recoverable only
# from Dex's trusted terminal-failure pause. Resume rolls back to Phase 6 and
# creates a fresh, exact authorization instead of accepting the partial 7.
TERMINAL_REPAIR_SESSION="$(dx_session_repo_key)-terminal-repair"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPAIR_SESSION")" 7
dx_write_pause_state "$TERMINAL_REPAIR_SESSION" terminal-proof-missing phase-loop
dx_lifecycle_atomic_write "$(dx_paused_file "$TERMINAL_REPAIR_SESSION")" paused
DEX_SESSION_ID="$TERMINAL_REPAIR_SESSION" bash "$CONTROL" resume \
  > "$TMP_DIR/terminal-repair.out"
assert_eq "6" "$(dx_lifecycle_phase_state "$TERMINAL_REPAIR_SESSION")" \
  "terminal repair returns to Phase 6"
TERMINAL_REPAIR_GENERATION=$(dx_completion_current_generation \
  "$TERMINAL_REPAIR_SESSION" lifecycle phase 6)
[[ "$TERMINAL_REPAIR_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
assert_no_file "$(dx_lifecycle_terminal_commit_file "$TERMINAL_REPAIR_SESSION")"
assert_no_file "$(dx_paused_file "$TERMINAL_REPAIR_SESSION")"
assert_contains "resumed at Phase 6" "$TMP_DIR/terminal-repair.out"

# A fresh lifecycle generation always erases an older terminal proof. Returning
# to Phase 7 without a new proof must therefore remain incomplete.
TERMINAL_REPLAY_SESSION="$(dx_session_repo_key)-terminal-replay"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 7
dx_lifecycle_control_lock_acquire "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_terminal_commit_publish_unlocked "$TERMINAL_REPLAY_SESSION" \
  0123456789abcdef0123456789abcdef
dx_lifecycle_control_lock_release "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_terminal_commit_valid "$TERMINAL_REPLAY_SESSION" || assert_at $LINENO
dx_lifecycle_control_lock_acquire "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 4
dx_lifecycle_completion_issue_unlocked \
  "$TERMINAL_REPLAY_SESSION" lifecycle phase 4 >/dev/null
assert_no_file "$(dx_lifecycle_terminal_commit_file "$TERMINAL_REPLAY_SESSION")"
dx_lifecycle_control_lock_release "$TERMINAL_REPLAY_SESSION"
dx_completion_abandon "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 7
if dx_lifecycle_terminal_commit_valid "$TERMINAL_REPLAY_SESSION"; then
  printf 'stale terminal proof authorized a later Phase 7\n' >&2
  exit 1
fi

set +e
DEX_SESSION_ID="foreign-session" bash "$CONTROL" status > "$TMP_DIR/foreign.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "does not belong to this repository" "$TMP_DIR/foreign.out"

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")" \
  "$(dx_loop_config_file "$DEX_SESSION_ID")"
set +e
bash "$CONTROL" stop > "$TMP_DIR/inactive.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "No active Dex lifecycle" "$TMP_DIR/inactive.out"

printf '%s\n' 7 > "$(dx_state_file "$DEX_SESSION_ID")"
set +e
DEX_LOOP_ACTIVE=1 bash "$CONTROL" stop > "$TMP_DIR/completed.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "No active Dex lifecycle" "$TMP_DIR/completed.out"
[[ ! -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO

# A checkout with no lifecycle state at all. Every case above wrote a phase
# file first, which hid the fact that dx_lifecycle_current_phase reported "no
# phase" by returning 1: control.sh reads it into CURRENT_PHASE on line 64
# under `set -e`, so the whole command died there without printing a word —
# `status` and `--help` included. The messages below were always written; they
# were simply unreachable.
rm -f "$(dx_state_file "$DEX_SESSION_ID")" "$(dx_paused_file "$DEX_SESSION_ID")" \
  "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")" \
  "$(dx_loop_config_file "$DEX_SESSION_ID")" "$(dx_owner_file "$DEX_SESSION_ID")"
dx_clear_lifecycle_control "$DEX_SESSION_ID"

bash "$CONTROL" status > "$TMP_DIR/bare-status.out" 2>&1
assert_contains "No Dex lifecycle state was found" "$TMP_DIR/bare-status.out"

bash "$CONTROL" --help > "$TMP_DIR/bare-help.out" 2>&1
assert_contains "Usage: dx control" "$TMP_DIR/bare-help.out"

assert_rejected "$LINENO" bash "$CONTROL" stop > "$TMP_DIR/bare-stop.out" 2>&1
assert_contains "No active Dex lifecycle" "$TMP_DIR/bare-stop.out"

printf 'lifecycle control CLI tests passed\n'

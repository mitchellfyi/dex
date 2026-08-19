#!/usr/bin/env bash
set -euo pipefail

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
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1\n' "$ROOT" > "$(dx_loop_config_file "$DEX_SESSION_ID")"
touch "$(dx_active_file "$DEX_SESSION_ID")"
printf '%s\n' "claude-owner" > "$(dx_owner_file "$DEX_SESSION_ID")"

bash "$CONTROL" status > "$TMP_DIR/status.out"
grep -q "Phase: 2 (Implement)" "$TMP_DIR/status.out"

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

bash "$CONTROL" resume > "$TMP_DIR/resume.out"
[[ ! -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO

# A wrapper-processed pause keeps a durable pause marker even after its live
# receipt and activation files are gone. Terminal controls can resume or move
# that recorded phase without relaunching the old provider process first.
bash "$CONTROL" pause > "$TMP_DIR/durable-pause.out"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_owner_file "$DEX_SESSION_ID")" \
  "$(dx_handoff_mode_file "$DEX_SESSION_ID")" "$(dx_loop_config_file "$DEX_SESSION_ID")"
bash "$CONTROL" status > "$TMP_DIR/durable-status.out"
grep -q "Lifecycle: paused (manual-pause)" "$TMP_DIR/durable-status.out"
bash "$CONTROL" "done" > "$TMP_DIR/durable-done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
touch "$(dx_paused_file "$DEX_SESSION_ID")"
bash "$CONTROL" resume > "$TMP_DIR/durable-resume.out"
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO

bash "$CONTROL" "done" > "$TMP_DIR/done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" expected_phase)" == "2" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "3" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
bash "$CONTROL" jump verify > "$TMP_DIR/jump.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "jump" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "4" ]] || assert_at $LINENO

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

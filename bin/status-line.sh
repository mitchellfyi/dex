#!/usr/bin/env bash
# Dex status line — displayed persistently in Claude Code TUI via statusLine setting.
# Reads phase state, audit loop iteration, and elapsed time from Dex state files.
# Must be fast (<50ms) since it runs on every TUI render cycle.
set -euo pipefail

# Only session and lifecycle-control helpers are used below, and none of them
# run at source time, so the rest of lib/ is not loaded. See lib/common.sh.
# shellcheck disable=SC2034 # read by lib/common.sh when it is sourced below
DX_COMMON_MODULES="output session lifecycle-control"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
unset DX_COMMON_MODULES

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

CONTROL_SNAPSHOT=$(dx_lifecycle_control_snapshot_unlocked "$SESSION_ID")
CONTROL_ACTION=$(dx_lifecycle_control_value "$CONTROL_SNAPSHOT" action)
if [[ "$CONTROL_ACTION" == "pause" || "$CONTROL_ACTION" == "cancel" ]]; then
  [[ "$CONTROL_ACTION" == "pause" ]] && CONTROL_LABEL="paused" || CONTROL_LABEL="stopped"
  echo "Dex ${CONTROL_LABEL} by human | phase sequencing detached"
  exit 0
fi
if [[ -f "$(dx_paused_file "$SESSION_ID")" && ! -L "$(dx_paused_file "$SESSION_ID")" ]]; then
  PAUSE_REASON=$(dx_pause_state_read "$SESSION_ID" reason)
  echo "Dex paused${PAUSE_REASON:+ | ${PAUSE_REASON}} | phase sequencing detached"
  exit 0
fi

# Phase info
PHASE="?"
PHASE_FILE=$(dx_state_file "$SESSION_ID")
if [[ -f "$PHASE_FILE" ]]; then
  PHASE=$(cat "$PHASE_FILE" 2>/dev/null || echo "?")
fi

# Audit loop iteration
ITER=""
LOOP_FILE=$(dx_loop_file "$SESSION_ID")
if [[ -f "$LOOP_FILE" ]]; then
  ITER=$(cut -d: -f1 "$LOOP_FILE" 2>/dev/null || echo "0")
  MAX="${DEX_LOOP_MAX_ITERATIONS:-30}"
  ITER=" | Audit ${ITER}/${MAX}"
fi

# Elapsed time from times file
ELAPSED=""
TIMES_FILE=$(dx_times_file "$SESSION_ID")
if [[ -f "$TIMES_FILE" ]]; then
  TOTAL_START=$(head -1 "$TIMES_FILE" 2>/dev/null | cut -d: -f2)
  # Digits, not merely non-empty. $(( )) evaluates an array subscript as an
  # arithmetic expression, so a times file holding `HOME[$(…)]` runs that
  # command — and this script runs on every prompt render, long after whatever
  # wrote the file is gone. `set -u` does not stop it: naming a variable that
  # is already set keeps nounset quiet. bin/log.sh reads the same file and
  # already checks this way.
  if [[ "${TOTAL_START:-}" =~ ^[0-9]+$ ]]; then
    NOW=$(date +%s)
    SECS=$((NOW - TOTAL_START))
    if [[ $SECS -lt 60 ]]; then
      ELAPSED=" | ${SECS}s"
    else
      ELAPSED=" | $((SECS / 60))m $((SECS % 60))s"
    fi
  fi
fi

if [[ "$PHASE" =~ ^[0-9]+$ ]] && [[ "$PHASE" -gt 6 ]]; then
  echo "Lifecycle complete${ELAPSED}"
else
  echo "Phase ${PHASE}/6${ITER}${ELAPSED}"
fi
